//! Browsers can't open a TCP connection, so the Hop also takes WebSockets on its own port. A connection
//! that starts `GET` is a WebSocket upgrade. Afterwards every binary message carries bytes of the same
//! stream a TCP client sends, and the rest of the Hop doesn't know the difference: the hello, the proof,
//! the status and the spliced link are the same bytes. A text message, or a message over `MAX_MESSAGE`,
//! closes the connection.
//!
//! Browsers on an https page can only use `wss://`, so the Hop is put behind a proxy that ends TLS
//! (Caddy, see server/README.md). `Config::forwarded_from` says which proxies may name the browser.

use std::io;
use std::net::IpAddr;
use std::sync::{Arc, Mutex, PoisonError};

use futures_util::{SinkExt, StreamExt};
use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt, duplex};
use tokio::net::TcpStream;
use tokio_tungstenite::tungstenite::Message;
use tokio_tungstenite::tungstenite::handshake::server::{ErrorResponse, Request, Response};
use tokio_tungstenite::tungstenite::protocol::WebSocketConfig;

/// A link's bytes are cut into Noise chunks of at most 64 KiB, so a bigger message is not a link.
const MAX_MESSAGE: usize = 256 * 1024;
/// How much the pipe between the WebSocket and the Hop holds each way.
const PIPE: usize = 64 * 1024;

/// A client's connection, whichever way it came.
pub trait Io: AsyncRead + AsyncWrite + Unpin + Send {}
impl<T: AsyncRead + AsyncWrite + Unpin + Send> Io for T {}
pub type Stream = Box<dyn Io>;

/// Whether the client opened with an HTTP request rather than the Hop's hello ("IMPHOP"). Waits for the
/// first byte without taking it.
pub async fn is_http(stream: &TcpStream) -> io::Result<bool> {
    let mut first = [0u8; 1];
    let n = stream.peek(&mut first).await?;
    Ok(n == 1 && first[0] == b'G')
}

/// Answers the upgrade. Gives the bytes of the WebSocket as a stream, and the browser's address when
/// a proxy named it (the last `X-Forwarded-For` entry, the one the proxy added).
// The header callback's type is tungstenite's: its error is an HTTP response, large by nature.
#[allow(clippy::result_large_err)]
pub async fn accept(stream: TcpStream) -> Option<(Stream, Option<IpAddr>)> {
    let forwarded = Arc::new(Mutex::new(None));
    let seen = Arc::clone(&forwarded);
    let read_headers =
        move |request: &Request, response: Response| -> Result<Response, ErrorResponse> {
            let ip = request
                .headers()
                .get_all("x-forwarded-for")
                .iter()
                .filter_map(|v| v.to_str().ok())
                .flat_map(|v| v.split(','))
                .next_back()
                .and_then(|v| v.trim().parse::<IpAddr>().ok());
            *seen.lock().unwrap_or_else(PoisonError::into_inner) = ip;
            Ok(response)
        };
    let mut config = WebSocketConfig::default();
    config.max_message_size = Some(MAX_MESSAGE);
    config.max_frame_size = Some(MAX_MESSAGE);
    let socket =
        tokio_tungstenite::accept_hdr_async_with_config(stream, read_headers, Some(config))
            .await
            .ok()?;
    let ip = *forwarded.lock().unwrap_or_else(PoisonError::into_inner);
    let (hop_side, pump_side) = duplex(PIPE);
    tokio::spawn(pump(socket, pump_side));
    Some((Box::new(hop_side), ip))
}

/// Moves bytes between the WebSocket and the Hop's side of the pipe until either ends.
async fn pump<S>(socket: tokio_tungstenite::WebSocketStream<S>, pipe: tokio::io::DuplexStream)
where
    S: AsyncRead + AsyncWrite + Unpin,
{
    let (mut sink, mut source) = socket.split();
    let (mut from_hop, mut to_hop) = tokio::io::split(pipe);
    let inbound = async {
        while let Some(Ok(message)) = source.next().await {
            match message {
                Message::Binary(bytes) => {
                    if to_hop.write_all(&bytes).await.is_err() {
                        break;
                    }
                }
                Message::Ping(_) | Message::Pong(_) | Message::Frame(_) => {}
                Message::Text(_) | Message::Close(_) => break,
            }
        }
        let _ = to_hop.shutdown().await;
    };
    let outbound = async {
        let mut buffer = vec![0u8; PIPE];
        loop {
            match from_hop.read(&mut buffer).await {
                Ok(n) if n > 0 => {
                    if sink
                        .send(Message::Binary(buffer[..n].to_vec().into()))
                        .await
                        .is_err()
                    {
                        return;
                    }
                }
                _ => break,
            }
        }
        let _ = sink.close().await;
    };
    // A WebSocket has no half-close: when one way ends, the connection is over.
    tokio::select! {
        () = inbound => {}
        () = outbound => {}
    }
}
