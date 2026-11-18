//! The MCP client: the transports around [`protocol`].
//!
//! The stdio transport starts the server as a child process and kills it when the client is dropped.
//! The HTTP transport posts every message to one address and reads either a JSON reply or an event
//! stream (see `http`).

use super::http;
use super::protocol::{self, Incoming, McpTool};
use crate::agent::{BoxFuture, HostTool, ToolHost};
use crate::chat::ToolSpec;
use crate::tools::ToolEntry;
use serde_json::Value;
use std::process::Stdio;
use std::rc::Rc;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::Duration;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::process::{Child, ChildStdin, ChildStdout, Command};
use tokio::sync::Mutex;

/// Why an MCP server could not be started or could not answer.
#[derive(Debug, thiserror::Error)]
pub enum McpError {
    #[error("could not start {command}: {reason}")]
    Spawn { command: String, reason: String },
    #[error("the MCP server did not answer in time")]
    Timeout,
    #[error("the MCP server closed the connection")]
    Closed,
    #[error("the MCP server reported an error: {0}")]
    Server(String),
    #[error("could not reach the MCP server: {0}")]
    Network(String),
    #[error("{}", protocol::status_text(*.0))]
    Status(u16),
    /// The server wants a signed-in person (401), or more permission (403 `insufficient_scope`).
    #[error("the MCP server needs you to sign in")]
    Unauthorized {
        resource_metadata: Option<String>,
        scope: Option<String>,
        insufficient_scope: bool,
    },
    /// The server speaks a revision Imp does not, or the sign-in did not work. The text is a sentence.
    #[error("{0}")]
    Protocol(String),
}

/// What the HTTP transport asks of whoever keeps the sign-ins (see `auth`). It sees the server by
/// its address.
pub trait McpSignIn {
    /// The access token to send to `server_url`, refreshed when it is about to run out or when
    /// `force_refresh` says the server refused it. Nothing when there is none.
    fn token<'a>(
        &'a self,
        server_url: &'a str,
        force_refresh: bool,
    ) -> BoxFuture<'a, Result<Option<String>, McpError>>;

    /// The server demanded a sign-in that a refresh did not fix. Do it (it may take minutes and
    /// may open a browser) and store the result, so that `token` has it. `Ok` means try again.
    fn sign_in<'a>(
        &'a self,
        server_name: &'a str,
        server_url: &'a str,
        challenge: &'a McpError,
    ) -> BoxFuture<'a, Result<(), McpError>>;
}

/// Pairs of names and secret values, such as environment variables or HTTP headers. `Debug` shows
/// the names only.
#[derive(Clone, PartialEq, Eq, Default)]
pub struct McpSecrets(pub Vec<(String, String)>);

impl std::fmt::Debug for McpSecrets {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_list()
            .entries(self.0.iter().map(|(name, _)| name))
            .finish()
    }
}

impl From<Vec<(String, String)>> for McpSecrets {
    fn from(pairs: Vec<(String, String)>) -> Self {
        Self(pairs)
    }
}

/// Where an MCP server is: a program to start, or an address to post to.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum McpEndpoint {
    /// `env` holds values already read from the environment.
    Command {
        command: String,
        args: Vec<String>,
        env: McpSecrets,
    },
    /// `headers` holds values already read from the environment or the key store.
    Http { url: String, headers: McpSecrets },
}

/// How to reach one MCP server.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct McpServerSpec {
    pub name: String,
    pub endpoint: McpEndpoint,
}

struct Pipes {
    stdin: ChildStdin,
    stdout: BufReader<ChildStdout>,
}

enum Link {
    Stdio { pipes: Mutex<Pipes>, _child: Child },
    Http(http::Http),
}

/// A connection to one MCP server, over a child process or over HTTP. Dropping a stdio client stops
/// its child process.
pub struct McpClient {
    name: String,
    link: Link,
    next_id: AtomicU64,
    timeout: Duration,
    /// Who signs in when the server demands it, and the server's address.
    sign_in: Option<(Rc<dyn McpSignIn>, String)>,
}

impl McpClient {
    /// Starts the server and does the `initialize` handshake. `timeout` limits every request.
    pub async fn connect_stdio(
        name: &str,
        command: &str,
        args: &[String],
        env: &McpSecrets,
        timeout: Duration,
    ) -> Result<Self, McpError> {
        let mut child = Command::new(command)
            .args(args)
            .envs(env.0.iter().map(|(k, v)| (k, v)))
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .kill_on_drop(true)
            .spawn()
            .map_err(|e| McpError::Spawn {
                command: command.to_string(),
                reason: e.to_string(),
            })?;
        let stdin = child.stdin.take().ok_or(McpError::Closed)?;
        let stdout = child.stdout.take().ok_or(McpError::Closed)?;
        Self::start(
            name,
            Link::Stdio {
                pipes: Mutex::new(Pipes {
                    stdin,
                    stdout: BufReader::new(stdout),
                }),
                _child: child,
            },
            timeout,
            None,
        )
        .await
    }

    /// Connects to a server over Streamable HTTP and does the `initialize` handshake. The values
    /// of `headers` are sent with every request and never shown.
    pub async fn connect_http(
        name: &str,
        url: &str,
        headers: &McpSecrets,
        timeout: Duration,
    ) -> Result<Self, McpError> {
        Self::connect_http_with(name, url, headers, timeout, None).await
    }

    /// Like [`Self::connect_http`], with `auth` keeping the server's sign-in: it supplies the
    /// bearer token, and when the server answers 401 it signs in (outside `timeout`) and tries once more.
    pub async fn connect_http_with(
        name: &str,
        url: &str,
        headers: &McpSecrets,
        timeout: Duration,
        auth: Option<Rc<dyn McpSignIn>>,
    ) -> Result<Self, McpError> {
        let link = Link::Http(http::Http::new(url, headers, auth.clone())?);
        let sign_in = auth.map(|a| (a, url.to_string()));
        Self::start(name, link, timeout, sign_in).await
    }

    /// Connects as the spec says.
    pub async fn connect(spec: &McpServerSpec, timeout: Duration) -> Result<Self, McpError> {
        Self::connect_with(spec, timeout, None).await
    }

    /// Like [`Self::connect`], with sign-in for HTTP servers.
    pub async fn connect_with(
        spec: &McpServerSpec,
        timeout: Duration,
        auth: Option<Rc<dyn McpSignIn>>,
    ) -> Result<Self, McpError> {
        match &spec.endpoint {
            McpEndpoint::Command { command, args, env } => {
                Self::connect_stdio(&spec.name, command, args, env, timeout).await
            }
            McpEndpoint::Http { url, headers } => {
                Self::connect_http_with(&spec.name, url, headers, timeout, auth).await
            }
        }
    }

    async fn start(
        name: &str,
        link: Link,
        timeout: Duration,
        sign_in: Option<(Rc<dyn McpSignIn>, String)>,
    ) -> Result<Self, McpError> {
        let client = Self {
            name: name.to_string(),
            link,
            next_id: AtomicU64::new(1),
            timeout,
            sign_in,
        };
        let id = client.next_id();
        let result = client
            .exchange(id, &protocol::initialize_request(id))
            .await?;
        let version = protocol::checked_version(&result).map_err(McpError::Protocol)?;
        if let Link::Http(http) = &client.link {
            http.set_protocol(&version);
        }
        client.notify(&protocol::initialized_notification()).await?;
        Ok(client)
    }

    pub fn name(&self) -> &str {
        &self.name
    }

    /// Ends the session of an HTTP server. A server started as a child process stops when the
    /// client is dropped.
    pub async fn close(&self) -> Result<(), McpError> {
        match &self.link {
            Link::Stdio { .. } => Ok(()),
            Link::Http(http) => tokio::time::timeout(self.timeout, http.end())
                .await
                .map_err(|_| McpError::Timeout)?,
        }
    }

    fn next_id(&self) -> u64 {
        self.next_id.fetch_add(1, Ordering::SeqCst)
    }

    async fn write(pipes: &mut Pipes, message: &Value) -> Result<(), McpError> {
        let mut line = message.to_string();
        line.push('\n');
        pipes
            .stdin
            .write_all(line.as_bytes())
            .await
            .map_err(|_| McpError::Closed)?;
        pipes.stdin.flush().await.map_err(|_| McpError::Closed)
    }

    async fn notify(&self, message: &Value) -> Result<(), McpError> {
        match &self.link {
            Link::Stdio { pipes, .. } => Self::write(&mut *pipes.lock().await, message).await,
            Link::Http(http) => tokio::time::timeout(self.timeout, http.post(message, None))
                .await
                .map_err(|_| McpError::Timeout)?
                .map(|_| ()),
        }
    }

    /// Sends the request with this id and waits for its answer. Lines that are not JSON,
    /// notifications and answers to other requests are skipped. A `ping` from the server is answered
    /// with an empty result, and any other request is answered with "Method not found".
    async fn exchange(&self, id: u64, message: &Value) -> Result<Value, McpError> {
        match self.exchange_once(id, message).await {
            // The server wants a sign-in that a refresh did not fix. Signing in may take minutes,
            // so it is outside the time limit. Then the request goes once more.
            Err(demand @ McpError::Unauthorized { .. }) if self.sign_in.is_some() => {
                if let Some((auth, url)) = &self.sign_in {
                    auth.sign_in(&self.name, url, &demand).await?;
                }
                self.exchange_once(id, message).await
            }
            other => other,
        }
    }

    async fn exchange_once(&self, id: u64, message: &Value) -> Result<Value, McpError> {
        match &self.link {
            Link::Stdio { pipes, .. } => self.exchange_stdio(pipes, id, message).await,
            Link::Http(http) => tokio::time::timeout(self.timeout, http.post(message, Some(id)))
                .await
                .map_err(|_| McpError::Timeout)?,
        }
    }

    async fn exchange_stdio(
        &self,
        pipes: &Mutex<Pipes>,
        id: u64,
        message: &Value,
    ) -> Result<Value, McpError> {
        let mut pipes = pipes.lock().await;
        let pipes = &mut *pipes;
        let exchange = async {
            Self::write(pipes, message).await?;
            loop {
                let mut line = String::new();
                let read = pipes
                    .stdout
                    .read_line(&mut line)
                    .await
                    .map_err(|_| McpError::Closed)?;
                if read == 0 {
                    return Err(McpError::Closed);
                }
                match protocol::parse_message(&line) {
                    Incoming::Request { reply } => Self::write(pipes, &reply).await?,
                    Incoming::Answer { id: got, result } if got == id => {
                        return result.map_err(|e| McpError::Server(e.message));
                    }
                    Incoming::Answer { .. } | Incoming::Skip => {}
                }
            }
        };
        tokio::time::timeout(self.timeout, exchange)
            .await
            .map_err(|_| McpError::Timeout)?
    }

    /// Every tool the server offers, following paging.
    pub async fn list_tools(&self) -> Result<Vec<McpTool>, McpError> {
        let mut tools = Vec::new();
        let mut seen: Vec<String> = Vec::new();
        let mut cursor: Option<String> = None;
        loop {
            let id = self.next_id();
            let message = protocol::tools_list_request(id, cursor.as_deref());
            let page = protocol::tools_page(&self.exchange(id, &message).await?, &seen);
            tools.extend(page.tools);
            let Some(next) = page.next_cursor else {
                return Ok(tools);
            };
            seen.push(next.clone());
            cursor = Some(next);
        }
    }

    /// Calls a tool and returns its text. An error the tool reports comes back as text starting
    /// with "Error:", so the model can read it. Failures of the server itself are errors.
    pub async fn call_tool(&self, name: &str, arguments: Value) -> Result<String, McpError> {
        let id = self.next_id();
        let message = protocol::tools_call_request(id, name, arguments);
        let result = self.exchange(id, &message).await?;
        Ok(protocol::tool_result_text(&result))
    }
}

/// The tools of several MCP servers, as one [`ToolHost`].
pub struct McpHost {
    clients: Vec<McpClient>,
    /// Client index, the server's own tool name, and the tool as offered.
    tools: Vec<(usize, String, HostTool)>,
}

impl McpHost {
    /// Connects to every server. Those that fail are skipped, each with a plain sentence in the
    /// second part of the result.
    pub async fn connect(specs: &[McpServerSpec], timeout: Duration) -> (Self, Vec<String>) {
        Self::connect_with(specs, timeout, None).await
    }

    /// Like [`Self::connect`], with sign-in for servers that ask for it.
    pub async fn connect_with(
        specs: &[McpServerSpec],
        timeout: Duration,
        auth: Option<Rc<dyn McpSignIn>>,
    ) -> (Self, Vec<String>) {
        let mut clients = Vec::new();
        let mut listed: Vec<(String, Vec<McpTool>)> = Vec::new();
        let mut problems = Vec::new();
        for spec in specs {
            let client = match McpClient::connect_with(spec, timeout, auth.clone()).await {
                Ok(c) => c,
                Err(e) => {
                    problems.push(format!(
                        "The MCP server {} is not available: {e}.",
                        spec.name
                    ));
                    continue;
                }
            };
            match client.list_tools().await {
                Ok(list) => {
                    clients.push(client);
                    listed.push((spec.name.clone(), list));
                }
                Err(e) => problems.push(format!(
                    "The MCP server {} gave no tool list: {e}.",
                    spec.name
                )),
            }
        }
        let names: Vec<(String, Vec<String>)> = listed
            .iter()
            .map(|(server, tools)| {
                (
                    server.clone(),
                    tools.iter().map(|t| t.name.clone()).collect(),
                )
            })
            .collect();
        let tools = protocol::expose(&names)
            .into_iter()
            .filter_map(|exposed| {
                let tool = listed[exposed.server]
                    .1
                    .iter()
                    .find(|t| t.name == exposed.tool)?;
                Some((
                    exposed.server,
                    exposed.tool.clone(),
                    HostTool {
                        entry: Some(ToolEntry::mcp(
                            &listed[exposed.server].0,
                            &exposed.tool,
                            &exposed.name,
                        )),
                        spec: ToolSpec {
                            name: exposed.name,
                            description: tool.description.clone(),
                            parameters: tool.input_schema.clone(),
                        },
                    },
                ))
            })
            .collect();
        (Self { clients, tools }, problems)
    }

    /// Ends the sessions of the servers that have one. A server that refuses is left to time the
    /// session out.
    pub async fn close(&self) {
        for client in &self.clients {
            let _ = client.close().await;
        }
    }
}

impl ToolHost for McpHost {
    fn tools(&self) -> Vec<HostTool> {
        self.tools.iter().map(|t| t.2.clone()).collect()
    }

    fn call<'a>(&'a self, name: &'a str, arguments: &'a str) -> BoxFuture<'a, Option<String>> {
        Box::pin(async move {
            let (index, tool, _) = self.tools.iter().find(|t| t.2.spec.name == name)?;
            let args = match protocol::parse_arguments(arguments) {
                Ok(v) => v,
                Err(e) => return Some(format!("Error: {e}")),
            };
            Some(match self.clients[*index].call_tool(tool, args).await {
                Ok(text) => text,
                Err(e) => format!("Error: {e}"),
            })
        })
    }
}
