//! Signing in to MCP servers that ask for it (MCP authorization, OAuth 2.1). The rules and the
//! requests are in `imp_engine::mcp::auth` and `auth_flow`. This is the terminal's part: the
//! browser, the loopback address the browser comes back to, and the private file with the tokens.
//!
//! The tokens live in `mcp-auth.json` in imp's data folder, readable by the owner only, keyed by the
//! address of the MCP server. There is no keychain, so no prompts.

use imp_engine::mcp::auth::{self, McpAuth};
use imp_engine::mcp::auth_flow::{self, RefreshFailure};
use imp_engine::{McpError, McpSignIn};
use serde::{Deserialize, Serialize};
use std::cell::RefCell;
use std::collections::BTreeMap;
use std::io::IsTerminal;
use std::path::{Path, PathBuf};
use std::time::Duration;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpListener;

/// How long the person has to finish in the browser.
pub const SIGN_IN_WAIT: Duration = Duration::from_secs(300);

/// The file's content: one sign-in per MCP server address, and the client id Imp got from each
/// authorization server (by issuer).
#[derive(Debug, Default, Serialize, Deserialize)]
pub struct AuthStore {
    #[serde(default)]
    pub servers: BTreeMap<String, McpAuth>,
    #[serde(default)]
    pub clients: BTreeMap<String, String>,
}

impl AuthStore {
    pub fn load(path: &Path) -> Self {
        std::fs::read_to_string(path)
            .ok()
            .and_then(|t| serde_json::from_str(&t).ok())
            .unwrap_or_default()
    }

    /// Writes the file with mode 0600 (on Unix), through a temporary file in the same folder.
    pub fn save(&self, path: &Path) -> std::io::Result<()> {
        use std::io::Write;
        if let Some(dir) = path.parent() {
            std::fs::create_dir_all(dir)?;
        }
        let tmp = path.with_extension("json.tmp");
        let mut options = std::fs::OpenOptions::new();
        options.write(true).create(true).truncate(true);
        #[cfg(unix)]
        std::os::unix::fs::OpenOptionsExt::mode(&mut options, 0o600);
        let mut file = options.open(&tmp)?;
        file.write_all(serde_json::to_string_pretty(self)?.as_bytes())?;
        file.sync_all()?;
        std::fs::rename(&tmp, path)
    }
}

/// The default place of the file.
pub fn default_path() -> Option<PathBuf> {
    crate::folders::data_dir().map(|d| d.join("mcp-auth.json"))
}

/// Signs in to MCP servers for the terminal.
pub struct ChatSignIn {
    path: PathBuf,
    store: RefCell<AuthStore>,
    /// Open this address for the person. The default starts the system's browser.
    open: Box<dyn Fn(&str)>,
    interactive: bool,
}

impl ChatSignIn {
    pub fn new(path: PathBuf) -> Self {
        Self::with(path, Box::new(open_browser), std::io::stdin().is_terminal())
    }

    /// `open` shows the address to the person, `interactive` says whether anyone is there.
    pub fn with(path: PathBuf, open: Box<dyn Fn(&str)>, interactive: bool) -> Self {
        Self {
            store: RefCell::new(AuthStore::load(&path)),
            path,
            open,
            interactive,
        }
    }

    fn save(&self) {
        if let Err(e) = self.store.borrow().save(&self.path) {
            eprintln!("Imp could not keep your sign-in ({e}); you will sign in again next time.");
        }
    }

    async fn sign_in_flow(&self, name: &str, url: &str, why: &McpError) -> Result<(), McpError> {
        let McpError::Unauthorized {
            resource_metadata,
            scope,
            ..
        } = why
        else {
            return Err(McpError::Protocol(why.to_string()));
        };
        if !self.interactive {
            return Err(McpError::Protocol(format!(
                "{name} needs you to sign in. Run `imp` in a terminal to sign in; it keeps the sign-in for later."
            )));
        }
        eprintln!("{name} needs you to sign in. Opening your browser…");
        let http = auth_flow::http_client()?;
        let found =
            auth_flow::discover(&http, url, resource_metadata.as_deref(), scope.as_deref()).await?;
        let listener = TcpListener::bind(("127.0.0.1", 0)).await.map_err(|e| {
            McpError::Protocol(format!("Imp could not listen for the sign-in: {e}"))
        })?;
        let port = listener.local_addr().map(|a| a.port()).unwrap_or(0);
        let redirect = format!("http://127.0.0.1:{port}/oauth");
        let cached = self
            .store
            .borrow()
            .clients
            .get(&found.server.issuer)
            .cloned();
        let client_id = match cached {
            Some(id) => id,
            None => {
                let id = auth_flow::register(&http, &found.server, &redirect).await?;
                self.store
                    .borrow_mut()
                    .clients
                    .insert(found.server.issuer.clone(), id.clone());
                self.save();
                id
            }
        };
        let pkce = auth::pkce_new();
        let state = auth::random_state();
        let address = auth::authorize_url(
            &found.server,
            &client_id,
            &redirect,
            &pkce.challenge,
            &state,
            found.scope.as_deref(),
            url,
        );
        eprintln!("If it does not open, go to:\n{address}");
        (self.open)(&address);
        let code = tokio::time::timeout(SIGN_IN_WAIT, wait_for_code(&listener, &state))
            .await
            .map_err(|_| {
                McpError::Protocol(format!(
                    "Signing in to {name} took longer than {} minutes, so Imp stopped waiting. Try again when you are ready to finish in the browser.",
                    SIGN_IN_WAIT.as_secs() / 60
                ))
            })?
            .map_err(|e| McpError::Protocol(format!("Signing in to {name} did not work: {e}.")))?;
        let signed = auth_flow::exchange_code(
            &http,
            &found.server,
            &client_id,
            &redirect,
            &code,
            &pkce.verifier,
            url,
        )
        .await?;
        self.store
            .borrow_mut()
            .servers
            .insert(url.to_string(), signed);
        self.save();
        eprintln!("Signed in to {name}.");
        Ok(())
    }
}

impl McpSignIn for ChatSignIn {
    fn token<'a>(
        &'a self,
        server_url: &'a str,
        force_refresh: bool,
    ) -> imp_engine::BoxFuture<'a, Result<Option<String>, McpError>> {
        Box::pin(async move {
            let Some(current) = self.store.borrow().servers.get(server_url).cloned() else {
                return Ok(None);
            };
            let now = auth_flow::now_secs();
            if !force_refresh && !current.needs_refresh(now) {
                return Ok(Some(current.access_token));
            }
            if current.refresh_token.is_none() {
                // Nothing to refresh with: use it until the server refuses it.
                return Ok((!force_refresh).then_some(current.access_token));
            }
            let http = auth_flow::http_client()?;
            match auth_flow::refresh(&http, &current, server_url).await {
                Ok(next) => {
                    let token = next.access_token.clone();
                    self.store
                        .borrow_mut()
                        .servers
                        .insert(server_url.to_string(), next);
                    self.save();
                    Ok(Some(token))
                }
                Err(RefreshFailure::Rejected) => {
                    self.store.borrow_mut().servers.remove(server_url);
                    self.save();
                    Ok(None)
                }
                Err(RefreshFailure::Other(e)) => {
                    if !force_refresh && current.expires_at.is_some_and(|at| at > now) {
                        Ok(Some(current.access_token))
                    } else {
                        Err(e)
                    }
                }
            }
        })
    }

    fn sign_in<'a>(
        &'a self,
        server_name: &'a str,
        server_url: &'a str,
        challenge: &'a McpError,
    ) -> imp_engine::BoxFuture<'a, Result<(), McpError>> {
        Box::pin(self.sign_in_flow(server_name, server_url, challenge))
    }
}

/// Starts the system's browser. Failing is fine: the address was printed.
fn open_browser(address: &str) {
    let program = if cfg!(target_os = "macos") {
        "open"
    } else {
        "xdg-open"
    };
    let _ = std::process::Command::new(program)
        .arg(address)
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .spawn();
}

/// Serves the loopback address until the browser comes back to `/oauth`, and returns the code.
async fn wait_for_code(listener: &TcpListener, state: &str) -> Result<String, String> {
    loop {
        let (mut stream, _) = listener.accept().await.map_err(|e| e.to_string())?;
        let mut buffer = vec![0u8; 8192];
        let read = tokio::time::timeout(Duration::from_secs(5), stream.read(&mut buffer))
            .await
            .ok()
            .and_then(Result::ok)
            .unwrap_or(0);
        let head = String::from_utf8_lossy(&buffer[..read]).into_owned();
        let target = head
            .lines()
            .next()
            .and_then(|l| l.strip_prefix("GET "))
            .and_then(|l| l.split(' ').next())
            .unwrap_or_default()
            .to_string();
        if target != "/oauth" && !target.starts_with("/oauth?") {
            let _ = stream
                .write_all(
                    b"HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
                )
                .await;
            continue;
        }
        let result = auth::parse_callback(&target, state);
        let text = match &result {
            Ok(_) => "You are signed in. You can close this tab and go back to Imp.",
            Err(_) => "The sign-in did not finish. Go back to Imp for what to do.",
        };
        let body = format!(
            "<!doctype html><meta charset=utf-8><title>Imp</title><body style=\"font-family:system-ui;margin:3em\"><p>{text}</p>"
        );
        let status = if result.is_ok() {
            "200 OK"
        } else {
            "400 Bad Request"
        };
        let _ = stream
            .write_all(
                format!(
                    "HTTP/1.1 {status}\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
                    body.len()
                )
                .as_bytes(),
            )
            .await;
        return result;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_store_is_private_and_round_trips() {
        let dir = std::env::temp_dir().join(format!("imp-auth-{}", uuid::Uuid::new_v4()));
        let path = dir.join("mcp-auth.json");
        let mut store = AuthStore::default();
        store
            .clients
            .insert("https://a.example".into(), "c1".into());
        store.save(&path).unwrap();
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let mode = std::fs::metadata(&path).unwrap().permissions().mode();
            assert_eq!(mode & 0o777, 0o600);
        }
        assert_eq!(AuthStore::load(&path).clients["https://a.example"], "c1");
        std::fs::remove_dir_all(&dir).unwrap();
    }

    #[tokio::test]
    async fn the_loopback_listener_returns_the_code_and_ignores_other_requests() {
        let listener = TcpListener::bind(("127.0.0.1", 0)).await.unwrap();
        let port = listener.local_addr().unwrap().port();
        let client = async move {
            for path in ["/favicon.ico", "/oauth?code=abc&state=st"] {
                let mut s = tokio::net::TcpStream::connect(("127.0.0.1", port))
                    .await
                    .unwrap();
                s.write_all(format!("GET {path} HTTP/1.1\r\nHost: x\r\n\r\n").as_bytes())
                    .await
                    .unwrap();
                let mut out = String::new();
                s.read_to_string(&mut out).await.unwrap();
            }
        };
        let (code, ()) = tokio::join!(wait_for_code(&listener, "st"), client);
        assert_eq!(code.unwrap(), "abc");
    }
}
