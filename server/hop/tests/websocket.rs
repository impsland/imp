//! A browser reaches the Hop over a WebSocket on the same port, and is spliced with TCP clients.

use std::net::SocketAddr;
use std::time::Duration;

use ed25519_dalek::{Signer, SigningKey};
use futures_util::{SinkExt, StreamExt};
use imp_hop::Config;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream};
use tokio::sync::oneshot;
use tokio::time::timeout;
use tokio_tungstenite::WebSocketStream;
use tokio_tungstenite::tungstenite::Message;
use tokio_tungstenite::tungstenite::client::IntoClientRequest;

const HOST: u8 = 1;
const GUEST: u8 = 2;
const WAIT: Duration = Duration::from_secs(5);

struct Running {
    addr: SocketAddr,
    _stop: oneshot::Sender<()>,
}

async fn start(mutate: impl FnOnce(&mut Config)) -> Running {
    let mut config = Config::default();
    mutate(&mut config);
    let listener = TcpListener::bind("127.0.0.1:0").await.expect("bind");
    let addr = listener.local_addr().expect("addr");
    let (stop, stopped) = oneshot::channel::<()>();
    tokio::spawn(imp_hop::run(listener, config, async move {
        let _ = stopped.await;
    }));
    Running { addr, _stop: stop }
}

fn key(n: u8) -> SigningKey {
    SigningKey::from_bytes(&[n; 32])
}

fn public(k: &SigningKey) -> [u8; 32] {
    k.verifying_key().to_bytes()
}

fn hello(role: u8, room: &[u8; 32], gate: &[u8; 32]) -> Vec<u8> {
    let mut hello = Vec::from(*b"IMPHOP");
    hello.push(role);
    hello.extend_from_slice(room);
    hello.extend_from_slice(gate);
    hello
}

fn proof(role: u8, nonce: &[u8], named: &[u8; 32], signer: &SigningKey) -> Vec<u8> {
    let mut msg = Vec::from(*b"imp-hop proof");
    msg.push(role);
    msg.extend_from_slice(nonce);
    msg.extend_from_slice(named);
    signer.sign(&msg).to_bytes().to_vec()
}

/// A browser: a WebSocket that reads the Hop's stream of bytes, however the messages cut it.
struct Browser {
    socket: WebSocketStream<TcpStream>,
    pending: Vec<u8>,
}

impl Browser {
    async fn open(addr: SocketAddr, forwarded_for: Option<&str>) -> Self {
        let mut request = format!("ws://{addr}/")
            .into_client_request()
            .expect("request");
        if let Some(ip) = forwarded_for {
            request
                .headers_mut()
                .insert("x-forwarded-for", ip.parse().expect("header"));
        }
        let tcp = TcpStream::connect(addr).await.expect("connect");
        let (socket, _) = tokio_tungstenite::client_async(request, tcp)
            .await
            .expect("upgrade");
        Self {
            socket,
            pending: Vec::new(),
        }
    }

    async fn send(&mut self, bytes: &[u8]) {
        self.socket
            .send(Message::Binary(bytes.to_vec().into()))
            .await
            .expect("send");
    }

    /// The next `n` bytes, or None when the connection closed first.
    async fn read(&mut self, n: usize) -> Option<Vec<u8>> {
        while self.pending.len() < n {
            match timeout(WAIT, self.socket.next()).await.expect("in time") {
                Some(Ok(Message::Binary(bytes))) => self.pending.extend_from_slice(&bytes),
                Some(Ok(Message::Close(_))) | None | Some(Err(_)) => return None,
                Some(Ok(_)) => {}
            }
        }
        Some(self.pending.drain(..n).collect())
    }

    async fn status(&mut self) -> u8 {
        self.read(1).await.expect("status byte")[0]
    }

    /// Steps 1 to 3 as a host of `room` naming `gate`, or a guest of it holding `gate`.
    async fn shake(&mut self, role: u8, room: &SigningKey, gate: &SigningKey) {
        let (r, g) = (public(room), public(gate));
        self.send(&hello(role, &r, &g)).await;
        let nonce = self.read(32).await.expect("nonce");
        let signed = if role == HOST {
            proof(HOST, &nonce, &g, room)
        } else {
            proof(GUEST, &nonce, &r, gate)
        };
        self.send(&signed).await;
    }
}

/// A TCP client through steps 1 to 3.
async fn tcp(addr: SocketAddr, role: u8, room: &SigningKey, gate: &SigningKey) -> TcpStream {
    let (r, g) = (public(room), public(gate));
    let mut s = TcpStream::connect(addr).await.expect("connect");
    s.write_all(&hello(role, &r, &g)).await.expect("hello");
    let mut nonce = [0u8; 32];
    s.read_exact(&mut nonce).await.expect("nonce");
    let signed = if role == HOST {
        proof(HOST, &nonce, &g, room)
    } else {
        proof(GUEST, &nonce, &r, gate)
    };
    s.write_all(&signed).await.expect("proof");
    s
}

async fn tcp_status(s: &mut TcpStream) -> u8 {
    let mut b = [0u8; 1];
    timeout(WAIT, s.read_exact(&mut b))
        .await
        .expect("in time")
        .expect("status");
    b[0]
}

#[tokio::test]
async fn a_browser_guest_is_spliced_with_a_tcp_host() {
    let hop = start(|_| {}).await;
    let (room, gate) = (key(1), key(101));
    let mut host = tcp(hop.addr, HOST, &room, &gate).await;
    let mut browser = Browser::open(hop.addr, None).await;
    browser.shake(GUEST, &room, &gate).await;
    assert_eq!(tcp_status(&mut host).await, 0);
    assert_eq!(browser.status().await, 0);

    browser.send(b"hello host").await;
    let mut got = [0u8; 10];
    host.read_exact(&mut got).await.expect("read");
    assert_eq!(&got, b"hello host");

    let big: Vec<u8> = (0..300_000u32).map(|i| (i % 251) as u8).collect();
    host.write_all(&big).await.expect("write big");
    assert_eq!(browser.read(big.len()).await.expect("big"), big);

    // Closing the browser ends the session for the host too.
    browser.socket.close(None).await.expect("close");
    let mut b = [0u8; 1];
    let end = timeout(WAIT, host.read(&mut b)).await.expect("in time");
    assert!(matches!(end, Ok(0) | Err(_)));
}

#[tokio::test]
async fn a_browser_may_wait_as_the_host_for_a_tcp_guest() {
    let hop = start(|_| {}).await;
    let (room, gate) = (key(2), key(102));
    let mut browser = Browser::open(hop.addr, None).await;
    browser.shake(HOST, &room, &gate).await;
    tokio::time::sleep(Duration::from_millis(100)).await;
    let mut guest = tcp(hop.addr, GUEST, &room, &gate).await;
    assert_eq!(browser.status().await, 0);
    assert_eq!(tcp_status(&mut guest).await, 0);
    guest.write_all(b"ping").await.expect("write");
    assert_eq!(browser.read(4).await.expect("ping"), b"ping");
}

#[tokio::test]
async fn a_browser_with_the_wrong_gate_is_rejected() {
    let hop = start(|_| {}).await;
    let room = key(3);
    let _host = tcp(hop.addr, HOST, &room, &key(103)).await;
    let mut browser = Browser::open(hop.addr, None).await;
    browser.shake(GUEST, &room, &key(99)).await;
    assert_eq!(browser.status().await, 1);
    assert!(browser.read(1).await.is_none());
}

#[tokio::test]
async fn a_text_message_closes_the_connection() {
    let hop = start(|_| {}).await;
    let mut browser = Browser::open(hop.addr, None).await;
    browser
        .socket
        .send(Message::Text("IMPHOP".into()))
        .await
        .expect("send");
    assert!(browser.read(1).await.is_none());
}

#[tokio::test]
async fn a_trusted_proxy_names_the_browser_for_the_limits() {
    let hop = start(|c| {
        c.per_ip_connections = 1;
        c.forwarded_from = vec!["127.0.0.0/8".parse().expect("prefix")];
    })
    .await;
    let (room, gate) = (key(4), key(104));
    // Two browsers behind the same proxy each have their own allowance.
    let mut first = Browser::open(hop.addr, Some("203.0.113.1")).await;
    first.shake(HOST, &room, &gate).await;
    let mut second = Browser::open(hop.addr, Some("10.1.1.1, 203.0.113.2")).await;
    second.shake(GUEST, &room, &gate).await;
    assert_eq!(second.status().await, 0);
    assert_eq!(first.status().await, 0);
    // A third from the first browser's address is over its limit.
    let mut third = Browser::open(hop.addr, Some("203.0.113.1")).await;
    assert_eq!(third.status().await, 2);
}

#[tokio::test]
async fn an_untrusted_forwarded_for_is_ignored() {
    let hop = start(|c| c.per_ip_connections = 1).await;
    let (room, gate) = (key(5), key(105));
    let mut first = Browser::open(hop.addr, Some("203.0.113.1")).await;
    first.shake(HOST, &room, &gate).await;
    // The header can't make a second address out of the same one.
    let mut second = Browser::open(hop.addr, Some("203.0.113.2")).await;
    assert_eq!(second.status().await, 2);
}
