use std::net::SocketAddr;
use std::time::Duration;

use ed25519_dalek::{Signer, SigningKey};
use hop::Config;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream};
use tokio::sync::oneshot;
use tokio::task::JoinHandle;
use tokio::time::timeout;

const MAC: u8 = 1;
const PHONE: u8 = 2;

struct Running {
    addr: SocketAddr,
    stop: oneshot::Sender<()>,
    task: JoinHandle<()>,
}

async fn start(mutate: impl FnOnce(&mut Config)) -> Running {
    let mut config = Config::default();
    mutate(&mut config);
    let listener = TcpListener::bind("127.0.0.1:0").await.expect("bind");
    let addr = listener.local_addr().expect("addr");
    let (stop, stopped) = oneshot::channel::<()>();
    let task = tokio::spawn(hop::run(listener, config, async move {
        let _ = stopped.await;
    }));
    Running { addr, stop, task }
}

fn room_key(n: u8) -> SigningKey {
    SigningKey::from_bytes(&[n; 32])
}

/// Does steps 1 to 3 and leaves the stream at the status byte.
async fn dial_as(
    addr: SocketAddr,
    hello_key: &SigningKey,
    signer: &SigningKey,
    role: u8,
) -> TcpStream {
    let mut s = TcpStream::connect(addr).await.expect("connect");
    let mut hello = Vec::from(*b"IMPHOP");
    hello.push(1);
    hello.push(role);
    hello.extend_from_slice(hello_key.verifying_key().as_bytes());
    s.write_all(&hello).await.expect("hello");
    let mut nonce = [0u8; 32];
    s.read_exact(&mut nonce).await.expect("nonce");
    let mut msg = Vec::from(*b"imp-hop/1");
    msg.push(role);
    msg.extend_from_slice(&nonce);
    s.write_all(&signer.sign(&msg).to_bytes())
        .await
        .expect("proof");
    s
}

async fn dial(addr: SocketAddr, key: &SigningKey, role: u8) -> TcpStream {
    dial_as(addr, key, key, role).await
}

async fn status(s: &mut TcpStream) -> u8 {
    let mut b = [0u8; 1];
    timeout(Duration::from_secs(5), s.read_exact(&mut b))
        .await
        .expect("status in time")
        .expect("status byte");
    b[0]
}

async fn closed(s: &mut TcpStream) -> bool {
    let mut b = [0u8; 1];
    matches!(
        timeout(Duration::from_secs(5), s.read(&mut b)).await,
        Ok(Ok(0) | Err(_))
    )
}

#[tokio::test]
async fn splices_bytes_both_ways() {
    let hop = start(|_| {}).await;
    let key = room_key(1);
    let mut mac = dial(hop.addr, &key, MAC).await;
    let mut phone = dial(hop.addr, &key, PHONE).await;
    assert_eq!(status(&mut mac).await, 0);
    assert_eq!(status(&mut phone).await, 0);

    phone.write_all(b"hello mac").await.expect("write");
    let mut got = [0u8; 9];
    mac.read_exact(&mut got).await.expect("read");
    assert_eq!(&got, b"hello mac");

    let big: Vec<u8> = (0..200_000u32).map(|i| (i % 251) as u8).collect();
    let sender = {
        let big = big.clone();
        tokio::spawn(async move {
            mac.write_all(&big).await.expect("write big");
            mac
        })
    };
    let mut received = vec![0u8; big.len()];
    phone.read_exact(&mut received).await.expect("read big");
    assert_eq!(received, big);
    let mut mac = sender.await.expect("sender");

    drop(phone);
    assert!(closed(&mut mac).await);
    hop.stop.send(()).expect("stop");
    hop.task.await.expect("stopped");
}

#[tokio::test]
async fn phone_may_arrive_first() {
    let hop = start(|_| {}).await;
    let key = room_key(2);
    let mut phone = dial(hop.addr, &key, PHONE).await;
    tokio::time::sleep(Duration::from_millis(100)).await;
    let mut mac = dial(hop.addr, &key, MAC).await;
    assert_eq!(status(&mut phone).await, 0);
    assert_eq!(status(&mut mac).await, 0);
    mac.write_all(b"x").await.expect("write");
    let mut b = [0u8; 1];
    phone.read_exact(&mut b).await.expect("read");
    assert_eq!(&b, b"x");
}

#[tokio::test]
async fn bad_proof_is_rejected() {
    let hop = start(|_| {}).await;
    let mut s = dial_as(hop.addr, &room_key(3), &room_key(4), PHONE).await;
    assert_eq!(status(&mut s).await, 1);
    assert!(closed(&mut s).await);
}

#[tokio::test]
async fn proof_for_the_other_role_is_rejected() {
    let hop = start(|_| {}).await;
    let key = room_key(3);
    let mut s = TcpStream::connect(hop.addr).await.expect("connect");
    let mut hello = Vec::from(*b"IMPHOP");
    hello.extend_from_slice(&[1, MAC]);
    hello.extend_from_slice(key.verifying_key().as_bytes());
    s.write_all(&hello).await.expect("hello");
    let mut nonce = [0u8; 32];
    s.read_exact(&mut nonce).await.expect("nonce");
    let mut msg = Vec::from(*b"imp-hop/1");
    msg.push(PHONE);
    msg.extend_from_slice(&nonce);
    s.write_all(&key.sign(&msg).to_bytes())
        .await
        .expect("proof");
    assert_eq!(status(&mut s).await, 1);
}

#[tokio::test]
async fn bad_hello_is_rejected() {
    let hop = start(|_| {}).await;
    let mut s = TcpStream::connect(hop.addr).await.expect("connect");
    s.write_all(&[b'X'; 40]).await.expect("hello");
    assert_eq!(status(&mut s).await, 1);
}

#[tokio::test]
async fn phone_without_a_mac_hears_nobody_came() {
    let hop = start(|c| c.phone_wait = Duration::from_millis(300)).await;
    let mut phone = dial(hop.addr, &room_key(5), PHONE).await;
    assert_eq!(status(&mut phone).await, 3);
    assert!(closed(&mut phone).await);
}

#[tokio::test]
async fn mac_wait_runs_out() {
    let hop = start(|c| c.mac_wait = Duration::from_millis(300)).await;
    let mut mac = dial(hop.addr, &room_key(6), MAC).await;
    assert_eq!(status(&mut mac).await, 3);
}

#[tokio::test]
async fn a_new_mac_replaces_the_waiting_one() {
    let hop = start(|_| {}).await;
    let key = room_key(7);
    let mut old = dial(hop.addr, &key, MAC).await;
    tokio::time::sleep(Duration::from_millis(100)).await;
    let mut new = dial(hop.addr, &key, MAC).await;
    assert_eq!(status(&mut old).await, 3);
    let mut phone = dial(hop.addr, &key, PHONE).await;
    assert_eq!(status(&mut new).await, 0);
    assert_eq!(status(&mut phone).await, 0);
}

#[tokio::test]
async fn a_room_has_a_session_limit() {
    let hop = start(|c| c.room_sessions = 1).await;
    let key = room_key(8);
    let mut mac = dial(hop.addr, &key, MAC).await;
    let mut phone = dial(hop.addr, &key, PHONE).await;
    assert_eq!(status(&mut mac).await, 0);
    assert_eq!(status(&mut phone).await, 0);
    let mut second = dial(hop.addr, &key, PHONE).await;
    assert_eq!(status(&mut second).await, 2);
}

#[tokio::test]
async fn too_many_connections_from_one_address_are_busy() {
    let hop = start(|c| c.per_ip_connections = 2).await;
    let _a = TcpStream::connect(hop.addr).await.expect("connect");
    let _b = TcpStream::connect(hop.addr).await.expect("connect");
    tokio::time::sleep(Duration::from_millis(100)).await;
    let mut c = TcpStream::connect(hop.addr).await.expect("connect");
    assert_eq!(status(&mut c).await, 2);
    assert!(closed(&mut c).await);
}

#[tokio::test]
async fn new_connections_per_minute_are_limited() {
    let hop = start(|c| c.per_ip_per_minute = 2).await;
    for _ in 0..2 {
        let mut s = TcpStream::connect(hop.addr).await.expect("connect");
        s.write_all(&[b'X'; 40]).await.expect("hello");
        assert_eq!(status(&mut s).await, 1);
    }
    let mut s = TcpStream::connect(hop.addr).await.expect("connect");
    assert_eq!(status(&mut s).await, 2);
}

#[tokio::test]
async fn a_silent_client_is_dropped_at_the_handshake_deadline() {
    let hop = start(|c| c.handshake = Duration::from_millis(200)).await;
    let mut s = TcpStream::connect(hop.addr).await.expect("connect");
    assert!(closed(&mut s).await);
}

#[tokio::test]
async fn an_idle_session_is_closed() {
    let hop = start(|c| c.idle = Duration::from_millis(300)).await;
    let key = room_key(9);
    let mut mac = dial(hop.addr, &key, MAC).await;
    let mut phone = dial(hop.addr, &key, PHONE).await;
    assert_eq!(status(&mut mac).await, 0);
    assert_eq!(status(&mut phone).await, 0);
    assert!(closed(&mut mac).await);
}

#[tokio::test]
async fn shutdown_tells_waiters_nobody_came() {
    let hop = start(|_| {}).await;
    let mut mac = dial(hop.addr, &room_key(10), MAC).await;
    tokio::time::sleep(Duration::from_millis(100)).await;
    hop.stop.send(()).expect("stop");
    assert_eq!(status(&mut mac).await, 3);
    hop.task.await.expect("stopped");
}
