use std::net::SocketAddr;
use std::sync::Arc;
use std::time::Duration;

use imp_shared::ip::IpKey;
use socket2::{SockRef, TcpKeepalive};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream};
use tokio::sync::watch;
use tokio::task::JoinSet;
use tokio::time::{interval, sleep, timeout};

use crate::config::Config;
use crate::handshake::{self, Failure, Role, Room};
use crate::limits::Limits;
use crate::relay;
use crate::rooms::{Arrival, Peer, Rooms, adopt};
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
    let (room, role) = match shaken {
        Ok(Ok(found)) => found,
        Ok(Err(Failure::Rejected)) => {
            tracing::debug!(ip = %ip.log_tag(), "rejected");
            let _ = stream.write_all(&[wire::REJECTED]).await;
            return;
        }
        Ok(Err(Failure::Closed)) | Err(_) => return,
    };
    let me = Peer { stream, conn };
    match shared.rooms.arrive(room, role, me) {
        Arrival::Paired => {}
        Arrival::Busy(mut me) => {
            let _ = me.stream.write_all(&[wire::BUSY]).await;
        }
        Arrival::Wait { id, mut rx, me } => wait(&shared, room, role, id, &mut rx, me).await,
    }
}

enum Outcome {
    Paired(Peer),
    Dropped,
    TimedOut,
    Gone,
}

async fn wait(
    shared: &Arc<Shared>,
    room: Room,
    role: Role,
    id: u64,
    rx: &mut tokio::sync::oneshot::Receiver<Peer>,
    mut me: Peer,
) {
    let limit = match role {
        Role::Mac => shared.config.mac_wait,
        Role::Phone => shared.config.phone_wait,
    };
    let mut stop = shared.stop.clone();
    let mut probe = [0u8; 1];
    let outcome = tokio::select! {
        arrived = &mut *rx => arrived.map_or(Outcome::Dropped, Outcome::Paired),
        () = sleep(limit) => Outcome::TimedOut,
        _ = me.stream.read(&mut probe) => Outcome::Gone,
        _ = stop.changed() => Outcome::Dropped,
    };
    let other = match outcome {
        Outcome::Paired(other) => other,
        Outcome::Gone => {
            shared.rooms.leave(&room, id);
            return;
        }
        Outcome::TimedOut => {
            shared.rooms.leave(&room, id);
            match rx.try_recv() {
                Ok(other) => other,
                Err(_) => return nobody_came(me).await,
            }
        }
        Outcome::Dropped => return nobody_came(me).await,
    };
    let session = adopt(&shared.rooms, room);
    let (mut mac, mut phone) = match role {
        Role::Mac => (me, other),
        Role::Phone => (other, me),
    };
    let go = async {
        tokio::try_join!(
            mac.stream.write_all(&[wire::GO]),
            phone.stream.write_all(&[wire::GO])
        )
    };
    if go.await.is_ok() {
        let mut stop = shared.stop.clone();
        let stopped = async move {
            let _ = stop.changed().await;
        };
        relay::splice(
            mac.stream,
            phone.stream,
            shared.config.bytes_per_second,
            shared.config.idle,
            stopped,
        )
        .await;
    }
    drop((session, mac.conn, phone.conn));
}

async fn nobody_came(mut me: Peer) {
    let _ = me.stream.write_all(&[wire::NOBODY_CAME]).await;
}
