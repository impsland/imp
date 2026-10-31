use std::net::SocketAddr;
use std::time::Duration;

use ed25519_dalek::{Signer, SigningKey};
use hop::Config;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream};
use tokio::sync::oneshot;
use tokio::task::JoinHandle;
use tokio::time::timeout;

const HOST: u8 = 1;
const GUEST: u8 = 2;

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

fn key(n: u8) -> SigningKey {
    SigningKey::from_bytes(&[n; 32])
}

fn public(k: &SigningKey) -> [u8; 32] {
    k.verifying_key().to_bytes()
}

/// Sends a hello and reads the nonce.
async fn hello(
    addr: SocketAddr,
    role: u8,
    room: &[u8; 32],
    gate: &[u8; 32],
) -> (TcpStream, [u8; 32]) {
    let mut s = TcpStream::connect(addr).await.expect("connect");
    let mut hello = Vec::from(*b"IMPHOP");
    hello.extend_from_slice(&[2, role]);
    hello.extend_from_slice(room);
    hello.extend_from_slice(gate);
    s.write_all(&hello).await.expect("hello");
    let mut nonce = [0u8; 32];
    s.read_exact(&mut nonce).await.expect("nonce");
    (s, nonce)
}

/// Does steps 1 to 3 with a proof for `role` over `named`, signed by `signer`, and leaves the
/// stream at the status byte.
async fn dial_raw(
    addr: SocketAddr,
    role: u8,
    room: &[u8; 32],
    gate: &[u8; 32],
    proof_role: u8,
    named: &[u8; 32],
    signer: &SigningKey,
) -> TcpStream {
    let (mut s, nonce) = hello(addr, role, room, gate).await;
    let mut msg = Vec::from(*b"imp-hop/2");
    msg.push(proof_role);
    msg.extend_from_slice(&nonce);
    msg.extend_from_slice(named);
    s.write_all(&signer.sign(&msg).to_bytes())
        .await
        .expect("proof");
    s
}

/// A host of `room` naming `gate`, signing with the room key.
async fn host(addr: SocketAddr, room: &SigningKey, gate: &SigningKey) -> TcpStream {
    let (r, g) = (public(room), public(gate));
    dial_raw(addr, HOST, &r, &g, HOST, &g, room).await
}

/// A guest of `room` holding `gate`.
async fn guest(addr: SocketAddr, room: &SigningKey, gate: &SigningKey) -> TcpStream {
    let (r, g) = (public(room), public(gate));
    dial_raw(addr, GUEST, &r, &g, GUEST, &r, gate).await
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

async fn pause() {
    tokio::time::sleep(Duration::from_millis(100)).await;
}

#[tokio::test]
async fn splices_bytes_both_ways() {
    let hop = start(|_| {}).await;
    let (room, gate) = (key(1), key(101));
    let mut host = host(hop.addr, &room, &gate).await;
    let mut guest = guest(hop.addr, &room, &gate).await;
    assert_eq!(status(&mut host).await, 0);
    assert_eq!(status(&mut guest).await, 0);

    guest.write_all(b"hello host").await.expect("write");
    let mut got = [0u8; 10];
    host.read_exact(&mut got).await.expect("read");
    assert_eq!(&got, b"hello host");

    let big: Vec<u8> = (0..200_000u32).map(|i| (i % 251) as u8).collect();
    let sender = {
        let big = big.clone();
        tokio::spawn(async move {
            host.write_all(&big).await.expect("write big");
            host
        })
    };
    let mut received = vec![0u8; big.len()];
    guest.read_exact(&mut received).await.expect("read big");
    assert_eq!(received, big);
    let mut host = sender.await.expect("sender");

    drop(guest);
    assert!(closed(&mut host).await);
    hop.stop.send(()).expect("stop");
    hop.task.await.expect("stopped");
}

#[tokio::test]
async fn a_guest_may_arrive_first() {
    let hop = start(|_| {}).await;
    let (room, gate) = (key(2), key(102));
    let mut guest = guest(hop.addr, &room, &gate).await;
    pause().await;
    let mut host = host(hop.addr, &room, &gate).await;
    assert_eq!(status(&mut guest).await, 0);
    assert_eq!(status(&mut host).await, 0);
    host.write_all(b"x").await.expect("write");
    let mut b = [0u8; 1];
    guest.read_exact(&mut b).await.expect("read");
    assert_eq!(&b, b"x");
}

#[tokio::test]
async fn a_host_takes_one_guest_and_the_next_host_the_next() {
    let hop = start(|_| {}).await;
    let (room, gate) = (key(11), key(111));
    let mut first = guest(hop.addr, &room, &gate).await;
    pause().await;
    let mut second = guest(hop.addr, &room, &gate).await;
    pause().await;
    let mut h1 = host(hop.addr, &room, &gate).await;
    assert_eq!(status(&mut first).await, 0);
    assert_eq!(status(&mut h1).await, 0);
    let mut h2 = host(hop.addr, &room, &gate).await;
    assert_eq!(status(&mut second).await, 0);
    assert_eq!(status(&mut h2).await, 0);
}

#[tokio::test]
async fn waiting_guests_with_another_gate_are_rejected_when_the_host_comes() {
    let hop = start(|_| {}).await;
    let room = key(12);
    let mut wrong = guest(hop.addr, &room, &key(113)).await;
    pause().await;
    let mut right = guest(hop.addr, &room, &key(112)).await;
    pause().await;
    let mut h = host(hop.addr, &room, &key(112)).await;
    assert_eq!(status(&mut wrong).await, 1);
    assert!(closed(&mut wrong).await);
    assert_eq!(status(&mut right).await, 0);
    assert_eq!(status(&mut h).await, 0);
}

#[tokio::test]
async fn a_guest_with_the_wrong_gate_is_rejected() {
    let hop = start(|_| {}).await;
    let room = key(13);
    let mut h = host(hop.addr, &room, &key(114)).await;
    pause().await;
    let mut wrong = guest(hop.addr, &room, &key(115)).await;
    assert_eq!(status(&mut wrong).await, 1);
    assert!(closed(&mut wrong).await);
    // The host keeps waiting and still takes the right guest.
    let mut right = guest(hop.addr, &room, &key(114)).await;
    assert_eq!(status(&mut right).await, 0);
    assert_eq!(status(&mut h).await, 0);
}

#[tokio::test]
async fn a_guest_cannot_wait_as_host() {
    let hop = start(|_| {}).await;
    let (room, gate) = (key(14), key(116));
    let (r, g) = (public(&room), public(&gate));
    // Signing as host with the gate key, which every guest can derive.
    let mut s = dial_raw(hop.addr, HOST, &r, &g, HOST, &g, &gate).await;
    assert_eq!(status(&mut s).await, 1);
    assert!(closed(&mut s).await);
}

#[tokio::test]
async fn a_host_proof_must_cover_the_gate() {
    let hop = start(|_| {}).await;
    let room = key(15);
    let (r, g, other) = (public(&room), public(&key(117)), public(&key(118)));
    let mut s = dial_raw(hop.addr, HOST, &r, &g, HOST, &other, &room).await;
    assert_eq!(status(&mut s).await, 1);
}

#[tokio::test]
async fn a_guest_proof_must_come_from_the_gate_key() {
    let hop = start(|_| {}).await;
    let (room, gate) = (key(16), key(119));
    let (r, g) = (public(&room), public(&gate));
    let mut s = dial_raw(hop.addr, GUEST, &r, &g, GUEST, &r, &key(120)).await;
    assert_eq!(status(&mut s).await, 1);
}

#[tokio::test]
async fn a_proof_for_the_other_role_is_rejected() {
    let hop = start(|_| {}).await;
    let room = key(17);
    let (r, g) = (public(&room), public(&key(121)));
    let mut s = dial_raw(hop.addr, HOST, &r, &g, GUEST, &g, &room).await;
    assert_eq!(status(&mut s).await, 1);
}

#[tokio::test]
async fn bad_hello_is_rejected() {
    let hop = start(|_| {}).await;
    let mut s = TcpStream::connect(hop.addr).await.expect("connect");
    s.write_all(&[b'X'; 72]).await.expect("hello");
    assert_eq!(status(&mut s).await, 1);
}

#[tokio::test]
async fn the_old_version_is_rejected() {
    let hop = start(|_| {}).await;
    let mut s = TcpStream::connect(hop.addr).await.expect("connect");
    let mut hello = Vec::from(*b"IMPHOP");
    hello.extend_from_slice(&[1, HOST]);
    hello.extend_from_slice(&[7u8; 64]);
    s.write_all(&hello).await.expect("hello");
    assert_eq!(status(&mut s).await, 1);
}

#[tokio::test]
async fn a_guest_without_a_host_hears_nobody_came() {
    let hop = start(|c| c.guest_wait = Duration::from_millis(300)).await;
    let mut guest = guest(hop.addr, &key(5), &key(105)).await;
    assert_eq!(status(&mut guest).await, 3);
    assert!(closed(&mut guest).await);
}

#[tokio::test]
async fn the_host_wait_runs_out() {
    let hop = start(|c| c.host_wait = Duration::from_millis(300)).await;
    let mut host = host(hop.addr, &key(6), &key(106)).await;
    assert_eq!(status(&mut host).await, 3);
}

#[tokio::test]
async fn a_new_host_replaces_the_waiting_one() {
    let hop = start(|_| {}).await;
    let (room, gate) = (key(7), key(107));
    let mut old = host(hop.addr, &room, &gate).await;
    pause().await;
    let mut new = host(hop.addr, &room, &gate).await;
    assert_eq!(status(&mut old).await, 3);
    let mut guest = guest(hop.addr, &room, &gate).await;
    assert_eq!(status(&mut new).await, 0);
    assert_eq!(status(&mut guest).await, 0);
}

#[tokio::test]
async fn a_room_has_a_session_limit() {
    let hop = start(|c| c.room_sessions = 1).await;
    let (room, gate) = (key(8), key(108));
    let mut h = host(hop.addr, &room, &gate).await;
    let mut g = guest(hop.addr, &room, &gate).await;
    assert_eq!(status(&mut h).await, 0);
    assert_eq!(status(&mut g).await, 0);
    let mut second = guest(hop.addr, &room, &gate).await;
    assert_eq!(status(&mut second).await, 2);
    // Another room is not affected.
    let (other, other_gate) = (key(18), key(122));
    let _h = host(hop.addr, &other, &other_gate).await;
    let mut g = guest(hop.addr, &other, &other_gate).await;
    assert_eq!(status(&mut g).await, 0);
}

#[tokio::test]
async fn several_guests_may_join_one_host_up_to_the_limit() {
    let hop = start(|c| c.room_sessions = 2).await;
    let (room, gate) = (key(19), key(123));
    let mut sessions = Vec::new();
    for _ in 0..2 {
        let mut h = host(hop.addr, &room, &gate).await;
        let mut g = guest(hop.addr, &room, &gate).await;
        assert_eq!(status(&mut h).await, 0);
        assert_eq!(status(&mut g).await, 0);
        sessions.push((h, g));
    }
    let mut third = guest(hop.addr, &room, &gate).await;
    assert_eq!(status(&mut third).await, 2);
}

#[tokio::test]
async fn too_many_connections_from_one_address_are_busy() {
    let hop = start(|c| c.per_ip_connections = 2).await;
    let _a = TcpStream::connect(hop.addr).await.expect("connect");
    let _b = TcpStream::connect(hop.addr).await.expect("connect");
    pause().await;
    let mut c = TcpStream::connect(hop.addr).await.expect("connect");
    assert_eq!(status(&mut c).await, 2);
    assert!(closed(&mut c).await);
}

#[tokio::test]
async fn new_connections_per_minute_are_limited() {
    let hop = start(|c| c.per_ip_per_minute = 2).await;
    for _ in 0..2 {
        let mut s = TcpStream::connect(hop.addr).await.expect("connect");
        s.write_all(&[b'X'; 72]).await.expect("hello");
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
    let (room, gate) = (key(9), key(109));
    let mut h = host(hop.addr, &room, &gate).await;
    let mut g = guest(hop.addr, &room, &gate).await;
    assert_eq!(status(&mut h).await, 0);
    assert_eq!(status(&mut g).await, 0);
    assert!(closed(&mut h).await);
}

#[tokio::test]
async fn bandwidth_is_capped_per_direction() {
    let hop = start(|c| c.bytes_per_second = 20_000).await;
    let (room, gate) = (key(20), key(124));
    let mut h = host(hop.addr, &room, &gate).await;
    let mut g = guest(hop.addr, &room, &gate).await;
    assert_eq!(status(&mut h).await, 0);
    assert_eq!(status(&mut g).await, 0);
    // The bucket starts with one second of bytes, so 60 000 bytes need about two more seconds.
    let started = std::time::Instant::now();
    let sender = tokio::spawn(async move {
        h.write_all(&[7u8; 60_000]).await.expect("write");
        h
    });
    let mut got = vec![0u8; 60_000];
    g.read_exact(&mut got).await.expect("read");
    assert!(started.elapsed() >= Duration::from_millis(1500));
    drop(sender.await.expect("sender"));
}

#[tokio::test]
async fn shutdown_tells_waiters_nobody_came() {
    let hop = start(|_| {}).await;
    let mut host = host(hop.addr, &key(10), &key(110)).await;
    pause().await;
    hop.stop.send(()).expect("stop");
    assert_eq!(status(&mut host).await, 3);
    hop.task.await.expect("stopped");
}
