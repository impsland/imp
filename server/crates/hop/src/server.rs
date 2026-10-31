use std::net::SocketAddr;
use std::sync::Arc;
use std::time::Duration;

use imp_shared::ip::IpKey;
use socket2::{SockRef, TcpKeepalive};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream};
use tokio::sync::{oneshot, watch};
use tokio::task::JoinSet;
use tokio::time::{interval, sleep, timeout};

use crate::config::Config;
use crate::handshake::{self, Failure, Key, Role};
use crate::limits::Limits;
use crate::relay;
use crate::rooms::{Arrival, Peer, Rooms, Wake, adopt};
use crate::wire;

struct Shared {
    config: Config,
    limits: Arc<Limits>,
    rooms: Arc<Rooms>,
    stop: watch::Receiver<bool>,
}

/// Serves `listener` until `shutdown` completes. Waiters are told nobody came, then live sessions close.
pub async fn run(listener: TcpListener, config: Config, shutdown: impl Future<Output = ()>) {
    let (stop_tx, stop) = watch::channel(false);
    let shared = Arc::new(Shared {
        limits: Limits::new(&config),
        rooms: Rooms::new(config.room_sessions),
        config,
        stop,
    });
    let mut tasks = JoinSet::new();
    let mut sweep = interval(Duration::from_secs(60));
    tokio::pin!(shutdown);
    loop {
        tokio::select! {
            () = &mut shutdown => break,
            _ = sweep.tick() => shared.limits.sweep(),
            Some(_) = tasks.join_next(), if !tasks.is_empty() => {}
            accepted = listener.accept() => match accepted {
                Ok((stream, peer)) => {
                    tasks.spawn(connection(Arc::clone(&shared), stream, peer));
                }
                Err(e) => {
                    tracing::warn!(error = %e, "accept failed");
                    sleep(Duration::from_millis(100)).await;
                }
            },
        }
    }
    shared.rooms.close_waiters();
    let _ = stop_tx.send(true);
    let drain = async { while tasks.join_next().await.is_some() {} };
    if timeout(Duration::from_secs(5), drain).await.is_err() {
        tasks.abort_all();
    }
}

fn tune(stream: &TcpStream) {
    let _ = stream.set_nodelay(true);
    let keepalive = TcpKeepalive::new()
        .with_time(Duration::from_secs(30))
        .with_interval(Duration::from_secs(10));
    let _ = SockRef::from(stream).set_tcp_keepalive(&keepalive);
}

async fn connection(shared: Arc<Shared>, mut stream: TcpStream, peer: SocketAddr) {
    tune(&stream);
    let ip = IpKey::from(peer.ip());
    let Some(conn) = shared.limits.admit(ip) else {
        tracing::debug!(ip = %ip.log_tag(), "limit hit");
        let _ = stream.write_all(&[wire::BUSY]).await;
        return;
    };
    let shaken = timeout(shared.config.handshake, handshake::run(&mut stream)).await;
    let who = match shaken {
        Ok(Ok(found)) => found,
        Ok(Err(Failure::Rejected)) => {
            tracing::debug!(ip = %ip.log_tag(), "rejected");
            let _ = stream.write_all(&[wire::REJECTED]).await;
            return;
        }
        Ok(Err(Failure::Closed)) | Err(_) => return,
    };
    let me = Peer { stream, conn };
    match shared.rooms.arrive(who, me) {
        Arrival::Paired => {}
        Arrival::Busy(me) => say(me, wire::BUSY).await,
        Arrival::Rejected(me) => say(me, wire::REJECTED).await,
        Arrival::Wait { id, mut rx, me } => {
            wait(&shared, who.room, who.role, id, &mut rx, me).await;
        }
    }
}

enum Outcome {
    Woke(Wake),
    Dropped,
    TimedOut,
    Gone,
}

async fn wait(
    shared: &Arc<Shared>,
    room: Key,
    role: Role,
    id: u64,
    rx: &mut oneshot::Receiver<Wake>,
    mut me: Peer,
) {
    let limit = match role {
        Role::Host => shared.config.host_wait,
        Role::Guest => shared.config.guest_wait,
    };
    let mut stop = shared.stop.clone();
    let mut probe = [0u8; 1];
    let outcome = tokio::select! {
        arrived = &mut *rx => arrived.map_or(Outcome::Dropped, Outcome::Woke),
        () = sleep(limit) => Outcome::TimedOut,
        _ = me.stream.read(&mut probe) => Outcome::Gone,
        _ = stop.changed() => Outcome::Dropped,
    };
    let other = match outcome {
        Outcome::Woke(Wake::Peer(other)) => other,
        Outcome::Woke(Wake::Rejected) => return say(me, wire::REJECTED).await,
        Outcome::Gone => {
            shared.rooms.leave(&room, id);
            return;
        }
        Outcome::TimedOut => {
            shared.rooms.leave(&room, id);
            match rx.try_recv() {
                Ok(Wake::Peer(other)) => other,
                Ok(Wake::Rejected) => return say(me, wire::REJECTED).await,
                Err(_) => return say(me, wire::NOBODY_CAME).await,
            }
        }
        Outcome::Dropped => return say(me, wire::NOBODY_CAME).await,
    };
    let session = adopt(&shared.rooms, room);
    let (mut host, mut guest) = match role {
        Role::Host => (me, other),
        Role::Guest => (other, me),
    };
    let go = async {
        tokio::try_join!(
            host.stream.write_all(&[wire::GO]),
            guest.stream.write_all(&[wire::GO])
        )
    };
    if go.await.is_ok() {
        let mut stop = shared.stop.clone();
        let stopped = async move {
            let _ = stop.changed().await;
        };
        relay::splice(
            host.stream,
            guest.stream,
            shared.config.bytes_per_second,
            shared.config.idle,
            stopped,
        )
        .await;
    }
    drop((session, host.conn, guest.conn));
}

/// Tells a client its status; the connection closes when `me` drops.
async fn say(mut me: Peer, status: u8) {
    let _ = me.stream.write_all(&[status]).await;
}
