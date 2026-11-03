//! `imp serve`: a Den and a Hop in one process, for a computer that wants to be its own server.
//!
//! The Den keeps its data in a SQLite file in the data folder. Its secret is made once, stored in
//! the same folder with permissions only the owner can use, and never printed.

use crate::{CliError, Result};
use std::future::Future;
use std::net::{IpAddr, Ipv4Addr, SocketAddr};
use std::path::{Path, PathBuf};
use tokio::net::TcpListener;
use tokio::sync::watch;

/// The usual Den port, as in `server/README.md`.
pub const DEFAULT_DEN_PORT: u16 = 8080;
/// The usual Hop port, as in `server/README.md`.
pub const DEFAULT_HOP_PORT: u16 = 4677;

const SECRET_FILE: &str = "den-secret";
const DATABASE_FILE: &str = "den.db";

/// What to run and where.
#[derive(Debug, Clone)]
pub struct ServeOptions {
    pub data_dir: PathBuf,
    pub host: IpAddr,
    pub den_port: u16,
    pub hop_port: u16,
    /// The address people use to reach the Den. Made from the host and port if left out.
    pub public_url: Option<String>,
}

impl ServeOptions {
    pub fn new(data_dir: PathBuf) -> Self {
        Self {
            data_dir,
            host: IpAddr::V4(Ipv4Addr::LOCALHOST),
            den_port: DEFAULT_DEN_PORT,
            hop_port: DEFAULT_HOP_PORT,
            public_url: None,
        }
    }
}

/// The usual data folder, such as `~/.local/share/imp` on Linux.
pub fn default_data_dir() -> Result<PathBuf> {
    directories::ProjectDirs::from("", "", "imp")
        .map(|d| d.data_dir().to_path_buf())
        .ok_or_else(|| {
            CliError("Could not find a data folder. Use --data-dir to say where it is.".into())
        })
}

/// Reads the Den secret from the data folder, or makes one the first time.
pub fn load_or_create_secret(dir: &Path) -> Result<String> {
    let path = dir.join(SECRET_FILE);
    if let Ok(text) = std::fs::read_to_string(&path) {
        let secret = text.trim().to_owned();
        if secret.len() >= imp_den::config::MIN_SECRET_BYTES {
            return Ok(secret);
        }
        return Err(CliError(format!(
            "The secret in {} is too short. Remove the file to make a new one.",
            path.display()
        )));
    }
    let secret = hex::encode(rand::random::<[u8; 32]>());
    write_private(&path, &secret)?;
    Ok(secret)
}

fn write_private(path: &Path, text: &str) -> Result<()> {
    use std::io::Write;
    let mut options = std::fs::OpenOptions::new();
    options.write(true).create_new(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600);
    }
    let mut file = options.open(path)?;
    file.write_all(text.as_bytes())?;
    Ok(())
}

/// Both listeners are open and the Den is configured, but nothing is served yet.
pub struct Bound {
    pub den_addr: SocketAddr,
    pub hop_addr: SocketAddr,
    /// The address the Den gives out as its own.
    pub public_url: String,
    den_listener: TcpListener,
    hop_listener: TcpListener,
    den_config: imp_den::config::Config,
}

/// Prepares the data folder and secret and opens both ports. A port of 0 picks a free one.
pub async fn bind(options: &ServeOptions) -> Result<Bound> {
    std::fs::create_dir_all(&options.data_dir)?;
    let secret = load_or_create_secret(&options.data_dir)?;
    let den_listener = listen(SocketAddr::new(options.host, options.den_port), "Den").await?;
    let hop_listener = listen(SocketAddr::new(options.host, options.hop_port), "Hop").await?;
    let den_addr = den_listener.local_addr()?;
    let hop_addr = hop_listener.local_addr()?;
    let public_url = options
        .public_url
        .clone()
        .unwrap_or_else(|| format!("http://{}", url_authority(options.host, den_addr.port())));
    let public = imp_den::config::PublicUrl::parse(&public_url)
        .map_err(|e| CliError(format!("That public address is not usable: {e}")))?;
    let database = options
        .data_dir
        .join(DATABASE_FILE)
        .to_string_lossy()
        .into_owned();
    let den_config = imp_den::config::Config {
        addr: den_addr,
        database,
        secret,
        public,
        trusted_proxies: Default::default(),
        altcha_cost: imp_den::config::DEFAULT_ALTCHA_COST,
        json_logs: false,
    };
    Ok(Bound {
        den_addr,
        hop_addr,
        public_url,
        den_listener,
        hop_listener,
        den_config,
    })
}

fn url_authority(host: IpAddr, port: u16) -> String {
    match host {
        IpAddr::V4(a) if a.is_loopback() || a.is_unspecified() => format!("localhost:{port}"),
        IpAddr::V4(a) => format!("{a}:{port}"),
        IpAddr::V6(a) => format!("[{a}]:{port}"),
    }
}

async fn listen(addr: SocketAddr, what: &str) -> Result<TcpListener> {
    TcpListener::bind(addr)
        .await
        .map_err(|e| CliError(format!("Cannot listen for the {what} on {addr}: {e}")))
}

impl Bound {
    /// Serves both until `shutdown` completes, then lets open work finish.
    pub async fn run(self, shutdown: impl Future<Output = ()> + Send + 'static) -> Result<()> {
        let (stop, stopped) = watch::channel(false);
        tokio::spawn(async move {
            shutdown.await;
            let _ = stop.send(true);
        });
        let wait = |mut rx: watch::Receiver<bool>| async move {
            let _ = rx.wait_for(|stopped| *stopped).await;
        };
        let hop = imp_hop::run(
            self.hop_listener,
            imp_hop::Config::default(),
            wait(stopped.clone()),
        );
        let den = imp_den::serve(self.den_config, self.den_listener, wait(stopped));
        let (den, ()) = tokio::join!(den, hop);
        den.map_err(CliError)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    use tokio::net::TcpStream;

    fn temp_dir(name: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("imp-serve-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        dir
    }

    #[test]
    fn the_secret_is_made_once_and_kept_private() {
        let dir = temp_dir("secret");
        std::fs::create_dir_all(&dir).unwrap();
        let first = load_or_create_secret(&dir).unwrap();
        assert_eq!(first.len(), 64);
        assert_eq!(load_or_create_secret(&dir).unwrap(), first);
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let mode = std::fs::metadata(dir.join(SECRET_FILE))
                .unwrap()
                .permissions()
                .mode();
            assert_eq!(mode & 0o777, 0o600);
        }
        std::fs::write(dir.join(SECRET_FILE), "short").unwrap();
        assert!(load_or_create_secret(&dir).is_err());
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn public_addresses() {
        assert_eq!(
            url_authority(IpAddr::V4(Ipv4Addr::LOCALHOST), 8080),
            "localhost:8080"
        );
        assert_eq!(
            url_authority(IpAddr::V4(Ipv4Addr::new(192, 168, 1, 5)), 9),
            "192.168.1.5:9"
        );
    }

    async fn get(addr: SocketAddr, path: &str) -> String {
        let mut s = TcpStream::connect(addr).await.unwrap();
        let request =
            format!("GET {path} HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n");
        s.write_all(request.as_bytes()).await.unwrap();
        let mut body = String::new();
        s.read_to_string(&mut body).await.unwrap();
        body
    }

    #[tokio::test]
    async fn serves_a_den_and_a_hop_and_stops() {
        let dir = temp_dir("run");
        let mut options = ServeOptions::new(dir.clone());
        options.den_port = 0;
        options.hop_port = 0;
        let bound = bind(&options).await.unwrap();
        let (den_addr, hop_addr) = (bound.den_addr, bound.hop_addr);
        let (stop, stopped) = tokio::sync::oneshot::channel::<()>();
        let task = tokio::spawn(bound.run(async move {
            let _ = stopped.await;
        }));

        let reply = get(den_addr, "/healthz").await;
        assert!(reply.starts_with("HTTP/1.1 200"), "{reply}");

        // The Hop answers a hello with its 32 byte nonce.
        let mut s = TcpStream::connect(hop_addr).await.unwrap();
        let mut hello = Vec::from(*imp_hop::wire::MAGIC);
        hello.extend_from_slice(&[imp_hop::wire::VERSION, imp_hop::wire::HOST]);
        hello.extend_from_slice(&[1u8; 32]);
        hello.extend_from_slice(&[2u8; 32]);
        s.write_all(&hello).await.unwrap();
        let mut nonce = [0u8; imp_hop::wire::NONCE_LEN];
        s.read_exact(&mut nonce).await.unwrap();
        drop(s);

        let _ = stop.send(());
        task.await.unwrap().unwrap();
        assert!(dir.join(DATABASE_FILE).exists());
        let _ = std::fs::remove_dir_all(&dir);
    }
}
