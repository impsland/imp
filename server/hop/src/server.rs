use std::net::{IpAddr, SocketAddr};
use std::sync::Arc;
use std::time::Duration;

use imp_shared::ip::IpKey;
use socket2::{SockRef, TcpKeepalive};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream};
use tokio::sync::{oneshot, watch};
use tokio::task::JoinSet;
use tokio::time::{Instant, interval, sleep, sleep_until, timeout, timeout_at};

use crate::config::Config;
use crate::handshake::{self, Arrived, Failure, Role};
use crate::limits::{ConnGuard, Limits};
use crate::relay;
use crate::rooms::{Arrival, Peer, Rooms, Wake, adopt};
use crate::ws::{self, Io, Stream};
use imp_engine::link::hop::HopStatus;

/// How long a client over a limit has to show it is a browser before it is told in plain bytes.
const REFUSAL_GRACE: Duration = Duration::from_millis(250);

struct Shared {
    config: Config,
    limits: Arc<Limits>,
    rooms: Arc<Rooms>,
    stop: watch::Receiver<bool>,
}

/// Serves `listener` until `shutdown` completes. Waiters are told nobody came, and live sessions
/// are stopped. Connection tasks get up to 5 seconds to finish before they are aborted.
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

/// A connection from a proxy named in `forwarded_from` is counted against the browser it names, once
/// its WebSocket upgrade says who that is. Every other connection counts against its own address at once.
async fn connection(shared: Arc<Shared>, stream: TcpStream, peer: SocketAddr) {
    tune(&stream);
    // One deadline for the upgrade and the Hop's own handshake together.
    let deadline = Instant::now() + shared.config.handshake;
    let proxied = shared
        .config
        .forwarded_from
        .iter()
        .any(|p| p.contains(peer.ip()));
    let early = if proxied {
        None
    } else {
        match admit(&shared, peer.ip()) {
            Some(conn) => Some(conn),
            None => {
                // A browser hears it over its WebSocket, as it would hear any other status. A browser
                // sends its request as soon as it connects, so a client that says nothing for a moment
                // is told in plain bytes, before its hello.
                let browser = timeout(REFUSAL_GRACE, ws::is_http(&stream)).await;
                if matches!(browser, Ok(Ok(true))) {
                    if let Ok(Some((stream, _))) = timeout_at(deadline, open(stream)).await {
                        refuse(stream).await;
                    }
                } else {
                    refuse(stream).await;
                }
                return;
            }
        }
    };
    let Ok(Some((mut stream, forwarded))) = timeout_at(deadline, open(stream)).await else {
        return;
    };
    let client = match forwarded {
        Some(browser) if proxied => browser,
        _ => peer.ip(),
    };
    let ip = IpKey::from(client);
    let conn = match early {
        Some(conn) => conn,
        None => match admit(&shared, client) {
            Some(conn) => conn,
            None => return refuse(stream).await,
        },
    };
    let shaken = timeout_at(deadline, handshake::run(&mut stream)).await;
    let who = match shaken {
        Ok(Ok(found)) => found,
        Ok(Err(Failure::Rejected)) => {
            tracing::debug!(ip = %ip.log_tag(), "rejected");
            let _ = stream.write_all(&[HopStatus::Rejected as u8]).await;
            return;
        }
        Ok(Err(Failure::Closed)) | Err(_) => return,
    };
    let limit = match who.role {
        Role::Host => shared.config.host_wait,
        Role::Guest => shared.config.guest_wait,
    };
    let deadline = Instant::now() + limit;
    let mut arrival = shared.rooms.arrive(who, Peer { stream, conn });
    loop {
        arrival = match arrival {
            Arrival::Paired => return,
            Arrival::Busy(me) => return say(me, HopStatus::Busy as u8).await,
            Arrival::Rejected(me) => return say(me, HopStatus::Rejected as u8).await,
            Arrival::Wait { id, mut rx, me } => {
                match wait(&shared, who, id, &mut rx, me, deadline).await {
                    Some(me) => shared.rooms.arrive(who, me),
                    None => return,
                }
            }
        };
    }
}

fn admit(shared: &Shared, ip: IpAddr) -> Option<ConnGuard> {
    let ip = IpKey::from(ip);
    let conn = shared.limits.admit(ip);
    if conn.is_none() {
        tracing::debug!(ip = %ip.log_tag(), "limit hit");
    }
    conn
}

async fn refuse(mut stream: impl Io) {
    let _ = stream.write_all(&[HopStatus::Busy as u8]).await;
}

/// The client's byte stream: the TCP connection itself, or the WebSocket it upgraded to, with the
/// browser's address when a proxy named it.
async fn open(stream: TcpStream) -> Option<(Stream, Option<IpAddr>)> {
    if ws::is_http(&stream).await.ok()? {
        ws::accept(stream).await
    } else {
        Some((Box::new(stream), None))
    }
}

/// How a wait ended.
enum Outcome {
    Woke(Wake),
    /// Nobody can wake this waiter any more: a newer host took its place, or the Hop is shutting down.
    Closed,
    TimedOut,
    /// The waiting client sent a byte or closed.
    Gone,
    /// The Hop is shutting down.
    Stopped,
}

/// Waits in the room until the other side comes or `deadline` passes, then runs the session. Returns
/// the connection when it should arrive again (`Wake::Again`).
async fn wait(
    shared: &Arc<Shared>,
    who: Arrived,
    id: u64,
    rx: &mut oneshot::Receiver<Wake>,
    mut me: Peer,
    deadline: Instant,
) -> Option<Peer> {
    let mut stop = shared.stop.clone();
    let mut probe = [0u8; 1];
    let outcome = tokio::select! {
        woke = &mut *rx => woke.map_or(Outcome::Closed, Outcome::Woke),
        () = sleep_until(deadline) => Outcome::TimedOut,
        _ = me.stream.read(&mut probe) => Outcome::Gone,
        _ = stop.changed() => Outcome::Stopped,
    };
    let wake = match outcome {
        Outcome::Woke(wake) => wake,
        Outcome::Closed => {
            say(me, HopStatus::Nobody as u8).await;
            return None;
        }
        ended => {
            let timed_out = matches!(ended, Outcome::TimedOut);
            let gone = matches!(ended, Outcome::Gone);
            // Once it has left, nobody hands this waiter anything. Whatever came just before is in `rx`.
            shared.rooms.leave(&who.room, id);
            match rx.try_recv().ok() {
                Some(wake) if timed_out => wake,
                Some(Wake::Peer(other)) => {
                    // The arriving side counted a session this side can't run: free it, and tell the
                    // other side nobody is here.
                    drop(adopt(&shared.rooms, who.room));
                    say(other, HopStatus::Nobody as u8).await;
                    if !gone {
                        say(me, HopStatus::Nobody as u8).await;
                    }
                    return None;
                }
                _ if gone => return None,
                _ => {
                    say(me, HopStatus::Nobody as u8).await;
                    return None;
                }
            }
        }
    };
    let other = match wake {
        Wake::Peer(other) => other,
        Wake::Rejected => {
            say(me, HopStatus::Rejected as u8).await;
            return None;
        }
        Wake::Again => return Some(me),
    };
    let session = adopt(&shared.rooms, who.room);
    let (mut host, mut guest) = match who.role {
        Role::Host => (me, other),
        Role::Guest => (other, me),
    };
    let go = async {
        tokio::try_join!(
            host.stream.write_all(&[HopStatus::Go as u8]),
            guest.stream.write_all(&[HopStatus::Go as u8])
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
    None
}

/// Tells a client its status. The connection closes when `me` drops.
async fn say(mut me: Peer, status: u8) {
    let _ = me.stream.write_all(&[status]).await;
}
