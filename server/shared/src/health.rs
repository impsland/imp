//! The `healthcheck` subcommand of both binaries: a tiny client that needs no tools in the image.

use std::net::SocketAddr;
use std::process::ExitCode;
use std::time::Duration;

use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpStream;
use tokio::time::timeout;

const DEADLINE: Duration = Duration::from_secs(4);

/// The port of a listen address such as `0.0.0.0:8080`, if it has one.
pub fn local_target(listen: &str) -> Option<SocketAddr> {
    let port = listen.rsplit_once(':')?.1.parse::<u16>().ok()?;
    Some(SocketAddr::from(([127, 0, 0, 1], port)))
}

/// Succeeds when `GET /healthz` answers 200.
pub async fn http(target: SocketAddr) -> ExitCode {
    let attempt = async {
        let mut stream = TcpStream::connect(target).await.ok()?;
        stream
            .write_all(b"GET /healthz HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n")
            .await
            .ok()?;
        let mut head = [0u8; 12];
        stream.read_exact(&mut head).await.ok()?;
        (&head == b"HTTP/1.1 200").then_some(())
    };
    exit(matches!(timeout(DEADLINE, attempt).await, Ok(Some(()))))
}

/// Succeeds when a TCP connection opens.
pub async fn tcp(target: SocketAddr) -> ExitCode {
    exit(matches!(
        timeout(DEADLINE, TcpStream::connect(target)).await,
        Ok(Ok(_))
    ))
}

fn exit(ok: bool) -> ExitCode {
    if ok {
        ExitCode::SUCCESS
    } else {
        ExitCode::FAILURE
    }
}
