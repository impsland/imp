//! `imp serve`: the Hop on this computer, for a computer that wants to be its own relay.
//!
//! The Hop keeps nothing on disk. The Den is a separate service (`den`, see `server/README.md`) and
//! is not part of `imp`.

use crate::{CliError, Result};
use std::future::Future;
use std::net::{IpAddr, Ipv4Addr, SocketAddr};
use std::path::PathBuf;
use tokio::net::TcpListener;

/// The usual Hop port, as in `server/README.md`.
pub const DEFAULT_HOP_PORT: u16 = 4677;

/// Where to listen.
#[derive(Debug, Clone)]
pub struct ServeOptions {
    pub host: IpAddr,
    pub hop_port: u16,
}

impl Default for ServeOptions {
    fn default() -> Self {
        Self {
            host: IpAddr::V4(Ipv4Addr::LOCALHOST),
            hop_port: DEFAULT_HOP_PORT,
        }
    }
}

/// The usual data folder, such as `~/.local/share/imp` on Linux (see `folders`).
pub fn default_data_dir() -> Result<PathBuf> {
    crate::folders::data_dir().ok_or_else(|| {
        CliError("Could not find a data folder. Use --data-dir to say where it is.".into())
    })
}

/// The Hop's listener is open, but nothing is served yet.
pub struct Bound {
    pub hop_addr: SocketAddr,
    hop: TcpListener,
}

/// Opens the Hop's port. A port of 0 picks a free one.
pub async fn bind(options: &ServeOptions) -> Result<Bound> {
    let addr = SocketAddr::new(options.host, options.hop_port);
    let hop = TcpListener::bind(addr)
        .await
        .map_err(|e| CliError(format!("Cannot listen for the Hop on {addr}: {e}")))?;
    Ok(Bound {
        hop_addr: hop.local_addr()?,
        hop,
    })
}

impl Bound {
    /// Serves the Hop until `shutdown` completes, then lets open work finish.
    pub async fn run(self, shutdown: impl Future<Output = ()> + Send + 'static) -> Result<()> {
        imp_hop::run(self.hop, imp_hop::Config::default(), shutdown).await;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    use tokio::net::TcpStream;

    /// The Hop answers a hello with its 32 byte nonce.
    async fn assert_hop_answers(addr: SocketAddr) {
        let mut s = TcpStream::connect(addr).await.unwrap();
        let hello = imp_engine::link::hop::HopCredentials::guest([1u8; 32], &[2u8; 32]).hello();
        s.write_all(&hello).await.unwrap();
        let mut nonce = [0u8; imp_engine::link::hop::NONCE_LEN];
        s.read_exact(&mut nonce).await.unwrap();
    }

    #[tokio::test]
    async fn serves_a_hop_and_stops() {
        let options = ServeOptions {
            hop_port: 0,
            ..ServeOptions::default()
        };
        let bound = bind(&options).await.unwrap();
        let addr = bound.hop_addr;
        assert!(addr.ip().is_loopback());
        let (tx, rx) = tokio::sync::oneshot::channel::<()>();
        let task = tokio::spawn(bound.run(async move {
            let _ = rx.await;
        }));
        assert_hop_answers(addr).await;
        let _ = tx.send(());
        task.await.unwrap().unwrap();
    }
}
