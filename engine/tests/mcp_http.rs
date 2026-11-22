//! The MCP client over Streamable HTTP, against a small server written in this file.

use imp_engine::{
    McpClient, McpEndpoint, McpHost, McpSecrets, McpServerSpec, ToolHost, ToolSelection,
};
use serde_json::{Value, json};
use std::collections::HashMap;
use std::sync::{Arc, Mutex};
use std::time::Duration;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpListener;

/// What one request carried: its headers (names in lower case) and its JSON body.
type Seen = Arc<Mutex<Vec<(HashMap<String, String>, Value)>>>;

/// The answer of a server that speaks the stateless revision when `stateless` is set, and only the
/// handshake otherwise.
fn reply(method: &str, body: &Value, stateless: bool) -> String {
    let (kind, extra, text) = match method {
        "server/discover" if stateless => (
            "application/json",
            "",
            json!({ "jsonrpc": "2.0", "id": body["id"], "result": {
                "resultType": "complete",
                "supportedVersions": ["2026-07-28", "2025-11-25"],
                "capabilities": { "tools": {} },
            } })
            .to_string(),
        ),
        "server/discover" => {
            let text = json!({ "jsonrpc": "2.0", "id": body["id"], "error": { "code": -32601, "message": "Method not found" } }).to_string();
            return format!(
                "HTTP/1.1 400 Bad Request\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{text}",
                text.len()
            );
        }
        "initialize" => (
            "application/json",
            "Mcp-Session-Id: session-7\r\n",
            json!({ "jsonrpc": "2.0", "id": body["id"], "result": { "protocolVersion": "2025-03-26" } }).to_string(),
        ),
        "tools/list" => {
            let list = json!({ "jsonrpc": "2.0", "id": body["id"], "result": { "tools": [
                { "name": "echo", "description": "Says it back", "inputSchema": { "type": "object" } },
                { "name": "delete", "description": "Removes things" },
            ] } });
            // A notification first, and a request from the server, then the answer. Lines end in CRLF.
            (
                "text/event-stream",
                "",
                format!(
                    "event: message\r\ndata: {}\r\n\r\ndata: {}\r\n\r\nevent: message\r\ndata: {}\r\n\r\n",
                    json!({ "jsonrpc": "2.0", "method": "notifications/message", "params": {} }),
                    json!({ "jsonrpc": "2.0", "id": 99, "method": "roots/list" }),
                    list
                ),
            )
        }
        "tools/call" => (
            "application/json",
            "",
            json!({ "jsonrpc": "2.0", "id": body["id"], "result": { "content": [
                { "type": "text", "text": format!("echo: {}", body["params"]["arguments"]["text"].as_str().unwrap_or("")) }
            ] } })
            .to_string(),
        ),
        _ => return "HTTP/1.1 202 Accepted\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".into(),
    };
    format!(
        "HTTP/1.1 200 OK\r\nContent-Type: {kind}\r\n{extra}Content-Length: {}\r\nConnection: close\r\n\r\n{text}",
        text.len()
    )
}

async fn serve(stateless: bool) -> (String, Seen) {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let url = format!("http://{}/mcp", listener.local_addr().unwrap());
    let seen: Seen = Arc::default();
    let log = seen.clone();
    tokio::spawn(async move {
        loop {
            let Ok((mut socket, _)) = listener.accept().await else {
                return;
            };
            let log = log.clone();
            tokio::spawn(async move {
                let mut data = Vec::new();
                let mut buf = [0u8; 4096];
                let (headers, body) = loop {
                    let read = socket.read(&mut buf).await.unwrap_or(0);
                    data.extend_from_slice(&buf[..read]);
                    let text = String::from_utf8_lossy(&data).to_string();
                    if let Some((head, rest)) = text.split_once("\r\n\r\n") {
                        let mut headers: HashMap<String, String> = head
                            .lines()
                            .skip(1)
                            .filter_map(|l| l.split_once(':'))
                            .map(|(k, v)| (k.to_ascii_lowercase(), v.trim().to_string()))
                            .collect();
                        // The verb is kept under the ":method" pseudo-header, which no real header name can use.
                        let verb = head.split_whitespace().next().unwrap_or_default();
                        headers.insert(":method".into(), verb.to_string());
                        let length: usize = headers
                            .get("content-length")
                            .map_or(0, |l| l.parse().unwrap());
                        if rest.len() >= length || read == 0 {
                            break (headers, rest.to_string());
                        }
                    }
                    if read == 0 {
                        return;
                    }
                };
                let body: Value = serde_json::from_str(&body).unwrap_or(Value::Null);
                let method = body["method"].as_str().unwrap_or_default().to_string();
                // A reply to the server's own request carries no method. It gets no answer of substance.
                let answer = reply(&method, &body, stateless);
                log.lock().unwrap().push((headers, body));
                let _ = socket.write_all(answer.as_bytes()).await;
            });
        }
    });
    (url, seen)
}

fn spec(url: &str) -> McpServerSpec {
    McpServerSpec {
        name: "web".into(),
        endpoint: McpEndpoint::Http {
            url: url.into(),
            headers: McpSecrets(vec![(
                "Authorization".into(),
                "Bearer fake-token-123".into(),
            )]),
        },
    }
}

#[tokio::test]
async fn initialize_list_and_call_over_json_and_event_streams() {
    let (url, seen) = serve(false).await;
    let client = McpClient::connect(&spec(&url), Duration::from_secs(5))
        .await
        .unwrap();
    let tools = client.list_tools().await.unwrap();
    assert_eq!(
        tools.iter().map(|t| t.name.as_str()).collect::<Vec<_>>(),
        ["echo", "delete"]
    );
    assert_eq!(tools[1].input_schema, json!({ "type": "object" }));
    let text = client
        .call_tool("echo", json!({ "text": "hi" }), &std::env::temp_dir())
        .await;
    assert_eq!(text.unwrap(), "echo: hi");

    let seen = seen.lock().unwrap();
    let methods: Vec<&str> = seen
        .iter()
        .filter_map(|(_, b)| b["method"].as_str())
        .collect();
    assert_eq!(
        methods,
        [
            "server/discover",
            "initialize",
            "notifications/initialized",
            "tools/list",
            "tools/call"
        ]
    );
    for (headers, _) in seen.iter() {
        assert_eq!(headers["authorization"], "Bearer fake-token-123");
        assert!(headers["accept"].contains("application/json"));
        assert!(headers["accept"].contains("text/event-stream"));
        assert_eq!(headers["content-type"], "application/json");
    }
    // Discovery asked for the stateless revision. The handshake that followed it starts afresh.
    assert_eq!(seen[0].0["mcp-protocol-version"], "2026-07-28");
    assert_eq!(seen[0].0["mcp-method"], "server/discover");
    assert!(!seen[1].0.contains_key("mcp-protocol-version"));
    assert!(!seen[1].0.contains_key("mcp-session-id"));
    // The session id from the answer to initialize is sent on every request after it.
    for (headers, _) in &seen[2..] {
        assert_eq!(headers["mcp-session-id"], "session-7");
        assert_eq!(headers["mcp-protocol-version"], "2025-03-26");
        assert!(!headers.contains_key("mcp-method"));
    }
    // The server's own request got a plain refusal.
    let refusal = &seen[4].1;
    assert_eq!(refusal["id"], 99);
    assert_eq!(refusal["error"]["code"], -32601);
}

#[tokio::test]
async fn a_stateless_server_gets_no_handshake_and_no_session() {
    let (url, seen) = serve(true).await;
    let client = McpClient::connect(&spec(&url), Duration::from_secs(5))
        .await
        .unwrap();
    assert_eq!(client.list_tools().await.unwrap().len(), 2);
    let text = client
        .call_tool("echo", json!({ "text": "hi" }), &std::env::temp_dir())
        .await;
    assert_eq!(text.unwrap(), "echo: hi");
    client.close().await.unwrap();

    let seen = seen.lock().unwrap();
    let methods: Vec<&str> = seen
        .iter()
        .filter_map(|(_, b)| b["method"].as_str())
        .collect();
    assert_eq!(methods, ["server/discover", "tools/list", "tools/call"]);
    // Every request names the revision, the method and, for a call, the tool. The reply to the
    // server's own request is not a request, so it names no method.
    for (headers, body) in seen.iter().filter(|(_, b)| b["method"].is_string()) {
        assert_eq!(headers["mcp-protocol-version"], "2026-07-28");
        assert_eq!(headers["mcp-method"], body["method"].as_str().unwrap());
        assert_eq!(
            body["params"]["_meta"]["io.modelcontextprotocol/protocolVersion"],
            "2026-07-28"
        );
        assert!(!headers.contains_key("mcp-session-id"));
    }
    let call = seen
        .iter()
        .find(|(_, b)| b["method"] == "tools/call")
        .unwrap();
    assert_eq!(call.0["mcp-name"], "echo");
    assert!(seen.iter().all(|(h, _)| h[":method"] == "POST"));
}

#[tokio::test]
async fn closing_a_session_sends_a_delete_with_its_id() {
    let (url, seen) = serve(false).await;
    let client = McpClient::connect(&spec(&url), Duration::from_secs(5))
        .await
        .unwrap();
    client.close().await.unwrap();
    {
        let seen = seen.lock().unwrap();
        let (headers, _) = seen.last().unwrap();
        assert_eq!(headers[":method"], "DELETE");
        assert_eq!(headers["mcp-session-id"], "session-7");
        assert_eq!(headers["mcp-protocol-version"], "2025-03-26");
        assert_eq!(headers["authorization"], "Bearer fake-token-123");
        assert_eq!(
            seen.iter()
                .filter(|(h, _)| h[":method"] == "DELETE")
                .count(),
            1
        );
    }
    // The session is over, so closing again sends nothing.
    client.close().await.unwrap();
    assert_eq!(
        seen.lock()
            .unwrap()
            .iter()
            .filter(|(h, _)| h[":method"] == "DELETE")
            .count(),
        1
    );
}

#[tokio::test]
async fn a_server_without_sessions_gets_no_delete() {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let url = format!("http://{}/mcp", listener.local_addr().unwrap());
    let verbs: Arc<Mutex<Vec<String>>> = Arc::default();
    let log = verbs.clone();
    tokio::spawn(async move {
        loop {
            let (mut socket, _) = listener.accept().await.unwrap();
            let mut buf = [0u8; 4096];
            let read = socket.read(&mut buf).await.unwrap_or(0);
            let text = String::from_utf8_lossy(&buf[..read]).to_string();
            log.lock().unwrap().push(
                text.split_whitespace()
                    .next()
                    .unwrap_or_default()
                    .to_string(),
            );
            let body = if text.contains("\"initialize\"") {
                let request: Value = text
                    .split_once("\r\n\r\n")
                    .and_then(|(_, body)| serde_json::from_str(body).ok())
                    .unwrap_or_default();
                json!({ "jsonrpc": "2.0", "id": request["id"], "result": {} }).to_string()
            } else {
                String::new()
            };
            let reply = if body.is_empty() {
                "HTTP/1.1 202 Accepted\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
                    .to_string()
            } else {
                format!(
                    "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
                    body.len()
                )
            };
            let _ = socket.write_all(reply.as_bytes()).await;
        }
    });
    let client = McpClient::connect(&spec(&url), Duration::from_secs(5))
        .await
        .unwrap();
    client.close().await.unwrap();
    assert!(verbs.lock().unwrap().iter().all(|v| v == "POST"));
}

#[tokio::test]
async fn a_switched_off_tool_is_not_offered_and_headers_are_not_shown() {
    let (url, _) = serve(false).await;
    let s = spec(&url);
    let shown = format!("{s:?}");
    assert!(shown.contains("Authorization"));
    assert!(!shown.contains("fake-token-123"));
    let (host, problems) =
        McpHost::connect(&[s], Duration::from_secs(5), &std::env::temp_dir()).await;
    assert!(problems.is_empty(), "{problems:?}");
    let selection = ToolSelection {
        tools_off: ["mcp.web.delete".to_string()].into(),
        ..ToolSelection::all()
    };
    let tools = host.tools();
    let offered: Vec<&str> = selection
        .filter(&tools, |t| t.entry.as_ref())
        .iter()
        .map(|t| t.spec.name.as_str())
        .collect();
    assert_eq!(offered, ["web__echo"]);
    let answer = host.call("web__echo", r#"{"text":"yo"}"#).await;
    assert_eq!(answer.as_deref(), Some("echo: yo"));
}

#[tokio::test]
async fn a_refused_request_is_a_plain_error() {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let url = format!("http://{}/mcp", listener.local_addr().unwrap());
    tokio::spawn(async move {
        loop {
            let (mut socket, _) = listener.accept().await.unwrap();
            let mut buf = [0u8; 4096];
            let _ = socket.read(&mut buf).await;
            let _ = socket
                .write_all(
                    b"HTTP/1.1 401 Unauthorized\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
                )
                .await;
        }
    });
    let error = McpClient::connect(&spec(&url), Duration::from_secs(5))
        .await
        .err()
        .unwrap();
    // A 401 is a typed demand to sign in, even without a challenge header.
    assert!(
        matches!(
            error,
            imp_engine::McpError::Unauthorized {
                resource_metadata: None,
                ..
            }
        ),
        "{error:?}"
    );
    assert_eq!(error.to_string(), "the MCP server needs you to sign in");
}
