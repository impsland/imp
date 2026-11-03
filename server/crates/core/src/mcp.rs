//! A client for MCP servers over standard input and output (newline-delimited JSON-RPC 2.0).
//!
//! It follows the stdio transport of the Swift `Sources/ImpKit/MCP`. The server is started as a
//! child process and is killed when the client is dropped. The HTTP transport is not here yet.

use crate::agent::{BoxFuture, HostTool, ToolHost};
use crate::chat::ToolSpec;
use crate::tools::{ToolEntry, server_key};
use serde_json::{Value, json};
use std::process::Stdio;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::Duration;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::process::{Child, ChildStdin, ChildStdout, Command};
use tokio::sync::Mutex;

const PROTOCOL_VERSION: &str = "2025-03-26";

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
}

/// How to start one MCP server. `env` holds values already read from the environment.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct McpServerSpec {
    pub name: String,
    pub command: String,
    pub args: Vec<String>,
    pub env: Vec<(String, String)>,
}

#[derive(Debug, Clone, PartialEq)]
pub struct McpTool {
    pub name: String,
    pub description: String,
    pub input_schema: Value,
}

struct Pipes {
    stdin: ChildStdin,
    stdout: BufReader<ChildStdout>,
}

pub struct McpClient {
    name: String,
    pipes: Mutex<Pipes>,
    next_id: AtomicU64,
    timeout: Duration,
    _child: Child,
}

impl McpClient {
    /// Starts the server and does the `initialize` handshake. `timeout` limits every request.
    pub async fn connect_stdio(spec: &McpServerSpec, timeout: Duration) -> Result<Self, McpError> {
        let mut child = Command::new(&spec.command)
            .args(&spec.args)
            .envs(spec.env.iter().map(|(k, v)| (k, v)))
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .kill_on_drop(true)
            .spawn()
            .map_err(|e| McpError::Spawn {
                command: spec.command.clone(),
                reason: e.to_string(),
            })?;
        let stdin = child.stdin.take().ok_or(McpError::Closed)?;
        let stdout = child.stdout.take().ok_or(McpError::Closed)?;
        let client = Self {
            name: spec.name.clone(),
            pipes: Mutex::new(Pipes {
                stdin,
                stdout: BufReader::new(stdout),
            }),
            next_id: AtomicU64::new(1),
            timeout,
            _child: child,
        };
        client
            .request(
                "initialize",
                json!({
                    "protocolVersion": PROTOCOL_VERSION,
                    "capabilities": {},
                    "clientInfo": { "name": "imp", "version": env!("CARGO_PKG_VERSION") },
                }),
            )
            .await?;
        client.notify("notifications/initialized").await?;
        Ok(client)
    }

    pub fn name(&self) -> &str {
        &self.name
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

    async fn notify(&self, method: &str) -> Result<(), McpError> {
        let mut pipes = self.pipes.lock().await;
        Self::write(&mut pipes, &json!({ "jsonrpc": "2.0", "method": method })).await
    }

    /// Sends a request and waits for its answer. Lines that are not JSON, notifications and
    /// answers to other requests are skipped. Requests from the server get a plain refusal.
    pub async fn request(&self, method: &str, params: Value) -> Result<Value, McpError> {
        let id = self.next_id.fetch_add(1, Ordering::SeqCst);
        let mut pipes = self.pipes.lock().await;
        let pipes = &mut *pipes;
        let exchange = async {
            Self::write(
                pipes,
                &json!({ "jsonrpc": "2.0", "id": id, "method": method, "params": params }),
            )
            .await?;
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
                let Ok(message) = serde_json::from_str::<Value>(line.trim()) else {
                    continue;
                };
                if message.get("method").is_some() {
                    if let Some(request_id) = message.get("id") {
                        let reply = if message["method"] == "ping" {
                            json!({ "jsonrpc": "2.0", "id": request_id, "result": {} })
                        } else {
                            json!({ "jsonrpc": "2.0", "id": request_id, "error": { "code": -32601, "message": "Method not found" } })
                        };
                        Self::write(pipes, &reply).await?;
                    }
                    continue;
                }
                if message.get("id") != Some(&json!(id)) {
                    continue;
                }
                if let Some(error) = message.get("error") {
                    let text = error["message"].as_str().unwrap_or("unknown error");
                    return Err(McpError::Server(text.to_string()));
                }
                return Ok(message.get("result").cloned().unwrap_or(Value::Null));
            }
        };
        tokio::time::timeout(self.timeout, exchange)
            .await
            .map_err(|_| McpError::Timeout)?
    }

    /// Every tool the server offers, following paging.
    pub async fn list_tools(&self) -> Result<Vec<McpTool>, McpError> {
        let mut tools = Vec::new();
        let mut cursor: Option<String> = None;
        for _ in 0..50 {
            let params = cursor
                .as_ref()
                .map_or_else(|| json!({}), |c| json!({ "cursor": c }));
            let result = self.request("tools/list", params).await?;
            for tool in result["tools"].as_array().into_iter().flatten() {
                let Some(name) = tool["name"].as_str() else {
                    continue;
                };
                tools.push(McpTool {
                    name: name.to_string(),
                    description: tool["description"].as_str().unwrap_or_default().to_string(),
                    input_schema: tool
                        .get("inputSchema")
                        .cloned()
                        .unwrap_or_else(|| json!({ "type": "object" })),
                });
            }
            cursor = result["nextCursor"].as_str().map(str::to_string);
            if cursor.is_none() {
                break;
            }
        }
        Ok(tools)
    }

    /// Calls a tool and returns its text. An error the tool reports comes back as text starting
    /// with "Error:", so the model can read it. Failures of the server itself are errors.
    pub async fn call_tool(&self, name: &str, arguments: Value) -> Result<String, McpError> {
        let result = self
            .request(
                "tools/call",
                json!({ "name": name, "arguments": arguments }),
            )
            .await?;
        let mut parts = Vec::new();
        for item in result["content"].as_array().into_iter().flatten() {
            match item["type"].as_str() {
                Some("text") => parts.push(item["text"].as_str().unwrap_or_default().to_string()),
                Some(other) => parts.push(format!("[{other} content not shown]")),
                None => {}
            }
        }
        let text = parts.join("\n");
        Ok(if result["isError"].as_bool().unwrap_or(false) {
            format!("Error: {text}")
        } else {
            text
        })
    }
}

/// What the model calls an MCP tool: the server key, two underscores, the tool name.
pub fn exposed_name(server: &str, tool: &str) -> String {
    let mut name = format!("{}__{}", server_key(server), server_key(tool));
    name.truncate(64);
    name
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
        let mut host = Self {
            clients: Vec::new(),
            tools: Vec::new(),
        };
        let mut problems = Vec::new();
        for spec in specs {
            let client = match McpClient::connect_stdio(spec, timeout).await {
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
                    let index = host.clients.len();
                    for tool in list {
                        let exposed = exposed_name(&spec.name, &tool.name);
                        host.tools.push((
                            index,
                            tool.name.clone(),
                            HostTool {
                                entry: Some(ToolEntry::mcp(&spec.name, &tool.name, &exposed)),
                                spec: ToolSpec {
                                    name: exposed,
                                    description: tool.description,
                                    parameters: tool.input_schema,
                                },
                            },
                        ));
                    }
                    host.clients.push(client);
                }
                Err(e) => problems.push(format!(
                    "The MCP server {} gave no tool list: {e}.",
                    spec.name
                )),
            }
        }
        (host, problems)
    }
}

impl ToolHost for McpHost {
    fn tools(&self) -> Vec<HostTool> {
        self.tools.iter().map(|t| t.2.clone()).collect()
    }

    fn call<'a>(&'a self, name: &'a str, arguments: &'a str) -> BoxFuture<'a, Option<String>> {
        Box::pin(async move {
            let (index, tool, _) = self.tools.iter().find(|t| t.2.spec.name == name)?;
            let args: Value = if arguments.trim().is_empty() {
                json!({})
            } else {
                match serde_json::from_str(arguments) {
                    Ok(v) => v,
                    Err(e) => return Some(format!("Error: the arguments are not valid JSON: {e}")),
                }
            };
            Some(match self.clients[*index].call_tool(tool, args).await {
                Ok(text) => text,
                Err(e) => format!("Error: {e}"),
            })
        })
    }
}
