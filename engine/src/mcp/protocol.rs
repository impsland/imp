//! The MCP rules that need no I/O: the JSON-RPC requests an MCP client sends, how it reads the replies,
//! the names the model sees for each server's tools, and what a status or an event stream means. The
//! transports in `client` and `http` only move the text these functions build and read.

use crate::tools::{mcp_group_id, mcp_id, server_key};
use serde_json::{Value, json};

/// The protocol version this client speaks. A server may answer with an older one.
pub const PROTOCOL_VERSION: &str = "2025-06-18";
/// The header that carries the session a Streamable HTTP server starts after `initialize`.
pub const SESSION_HEADER: &str = "Mcp-Session-Id";
/// The header that carries the protocol version on every request after `initialize`.
pub const PROTOCOL_HEADER: &str = "MCP-Protocol-Version";
/// The most pages of tools read from one server.
pub const MAX_TOOL_PAGES: usize = 50;
/// The longest name a model may call a tool by.
const MAX_NAME: usize = 64;

/// The error a server answers a request with.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RpcError {
    pub code: i64,
    pub message: String,
}

/// What one message from the server asks of the client.
#[derive(Debug, Clone, PartialEq)]
pub enum Incoming {
    /// Nothing: chatter that is not JSON, a notification, or an answer without a number id.
    Skip,
    /// The answer to the request with this id.
    Answer {
        id: u64,
        result: Result<Value, RpcError>,
    },
    /// A request from the server. Send `reply` back.
    Request { reply: Value },
}

#[derive(Debug, Clone, PartialEq)]
pub struct McpTool {
    pub name: String,
    pub description: String,
    pub input_schema: Value,
}

/// One page of a tool list.
#[derive(Debug, Clone, PartialEq)]
pub struct ToolPage {
    pub tools: Vec<McpTool>,
    /// The cursor of the next page, if there is one worth reading.
    pub next_cursor: Option<String>,
}

/// A tool as the model is offered it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ExposedTool {
    /// The index of its server in the list given to [`expose`].
    pub server: usize,
    /// The server's own name for the tool.
    pub tool: String,
    /// What the model calls it.
    pub name: String,
    /// Its registry id, `mcp.<server>.<tool>`.
    pub id: String,
    /// Its group id, `mcp.<server>`.
    pub group: String,
}

fn request(id: u64, method: &str, params: Value) -> Value {
    json!({ "jsonrpc": "2.0", "id": id, "method": method, "params": params })
}

pub fn initialize_request(id: u64) -> Value {
    request(
        id,
        "initialize",
        json!({
            "protocolVersion": PROTOCOL_VERSION,
            "capabilities": {},
            "clientInfo": { "name": "imp", "version": env!("CARGO_PKG_VERSION") },
        }),
    )
}

pub fn initialized_notification() -> Value {
    json!({ "jsonrpc": "2.0", "method": "notifications/initialized" })
}

pub fn tools_list_request(id: u64, cursor: Option<&str>) -> Value {
    let params = cursor.map_or_else(|| json!({}), |c| json!({ "cursor": c }));
    request(id, "tools/list", params)
}

pub fn tools_call_request(id: u64, name: &str, arguments: Value) -> Value {
    request(
        id,
        "tools/call",
        json!({ "name": name, "arguments": arguments }),
    )
}

/// The revisions Imp speaks, newest first.
pub const SUPPORTED_VERSIONS: &[&str] = &[PROTOCOL_VERSION, "2025-03-26", "2024-11-05"];

/// The version to speak after `initialize`, or the sentence to show when the server picked a
/// revision Imp does not speak (the client must then disconnect).
pub fn checked_version(initialize_result: &Value) -> Result<String, String> {
    let version = negotiated_version(initialize_result);
    if SUPPORTED_VERSIONS.contains(&version.as_str()) {
        Ok(version)
    } else {
        Err(format!(
            "This server speaks MCP {version}; Imp speaks {}.",
            SUPPORTED_VERSIONS.join(", ")
        ))
    }
}

/// The version to speak after `initialize`: the one the server picked, or ours.
pub fn negotiated_version(initialize_result: &Value) -> String {
    initialize_result["protocolVersion"]
        .as_str()
        .unwrap_or(PROTOCOL_VERSION)
        .to_string()
}

/// Reads one message from the server.
pub fn classify(message: &Value) -> Incoming {
    if let Some(method) = message.get("method") {
        let Some(id) = message.get("id") else {
            return Incoming::Skip;
        };
        let reply = if method == "ping" {
            json!({ "jsonrpc": "2.0", "id": id, "result": {} })
        } else {
            json!({ "jsonrpc": "2.0", "id": id, "error": { "code": -32601, "message": "Method not found" } })
        };
        return Incoming::Request { reply };
    }
    let Some(id) = message.get("id").and_then(Value::as_u64) else {
        return Incoming::Skip;
    };
    let result = match message.get("error") {
        Some(error) => Err(RpcError {
            code: error["code"].as_i64().unwrap_or(-1),
            message: error["message"]
                .as_str()
                .unwrap_or("unknown error")
                .to_string(),
        }),
        None => Ok(message.get("result").cloned().unwrap_or(Value::Null)),
    };
    Incoming::Answer { id, result }
}

/// Reads one line a server wrote. A line that is not JSON is skipped.
pub fn parse_message(line: &str) -> Incoming {
    serde_json::from_str::<Value>(line.trim()).map_or(Incoming::Skip, |m| classify(&m))
}

/// The tools of one page. `seen` holds the cursors already read: a cursor that comes again, or
/// one past [`MAX_TOOL_PAGES`], ends the list.
pub fn tools_page(result: &Value, seen: &[String]) -> ToolPage {
    let tools = result["tools"]
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(|tool| {
            Some(McpTool {
                name: tool["name"].as_str()?.to_string(),
                description: tool["description"].as_str().unwrap_or_default().to_string(),
                input_schema: tool
                    .get("inputSchema")
                    .cloned()
                    .unwrap_or_else(|| json!({ "type": "object" })),
            })
        })
        .collect();
    let next_cursor = result["nextCursor"]
        .as_str()
        .filter(|c| seen.len() < MAX_TOOL_PAGES && !seen.iter().any(|s| s == c))
        .map(str::to_string);
    ToolPage { tools, next_cursor }
}

/// The text a model reads for the result of a tool call. Content that is not text is named in
/// brackets. A result the tool marks as an error starts with "Error:".
pub fn tool_result_text(result: &Value) -> String {
    let parts: Vec<String> = result["content"]
        .as_array()
        .into_iter()
        .flatten()
        .map(|item| match item["type"].as_str().unwrap_or("unknown") {
            "text" => item["text"].as_str().unwrap_or_default().to_string(),
            "resource" => item["resource"]["text"]
                .as_str()
                .unwrap_or("[resource]")
                .to_string(),
            "resource_link" => format!("[resource: {}]", item["uri"].as_str().unwrap_or_default()),
            other => format!("[{other}]"),
        })
        .collect();
    let text = parts.join("\n");
    if result["isError"].as_bool() == Some(true) {
        format!("Error: {text}")
    } else {
        text
    }
}

/// The arguments of a tool call as the model wrote them: JSON text, or nothing.
pub fn parse_arguments(text: &str) -> Result<Value, String> {
    if text.trim().is_empty() {
        return Ok(json!({}));
    }
    serde_json::from_str(text).map_err(|e| format!("the arguments are not valid JSON: {e}"))
}

/// What the model calls an MCP tool: the server key, two underscores, the tool key, at most 64
/// characters.
pub fn exposed_name(server: &str, tool: &str) -> String {
    let mut name = format!("{}__{}", server_key(server), server_key(tool));
    name.truncate(MAX_NAME);
    name
}

/// The tools of several servers (a name and the server's tool names each), as the model is offered
/// them. Servers are taken in name order. Two tools that end up with one name get `_2`, `_3` and so on.
pub fn expose(servers: &[(String, Vec<String>)]) -> Vec<ExposedTool> {
    let mut order: Vec<usize> = (0..servers.len()).collect();
    order.sort_by(|&a, &b| servers[a].0.cmp(&servers[b].0));
    let mut used = std::collections::HashSet::new();
    let mut out = Vec::new();
    for server in order {
        let (server_name, tools) = &servers[server];
        for tool in tools {
            let base = exposed_name(server_name, tool);
            let mut name = base.clone();
            let mut n = 2;
            while !used.insert(name.clone()) {
                let suffix = format!("_{n}");
                name = format!(
                    "{}{suffix}",
                    &base[..base.len().min(MAX_NAME - suffix.len())]
                );
                n += 1;
            }
            out.push(ExposedTool {
                server,
                tool: tool.clone(),
                name,
                id: mcp_id(server_name, tool),
                group: mcp_group_id(server_name),
            });
        }
    }
    out
}

/// The headers of a POST: the content types, and the session and protocol version once known.
pub fn post_headers(session: Option<&str>, protocol: Option<&str>) -> Vec<(String, String)> {
    let mut headers = vec![
        ("Content-Type".to_string(), "application/json".to_string()),
        (
            "Accept".to_string(),
            "application/json, text/event-stream".to_string(),
        ),
    ];
    headers.extend(session_headers(session, protocol));
    headers
}

/// The headers that end a session with a DELETE, or nothing when no session was started.
pub fn end_headers(session: Option<&str>, protocol: Option<&str>) -> Option<Vec<(String, String)>> {
    session?;
    Some(session_headers(session, protocol))
}

fn session_headers(session: Option<&str>, protocol: Option<&str>) -> Vec<(String, String)> {
    let mut headers = Vec::new();
    if let Some(session) = session {
        headers.push((SESSION_HEADER.to_string(), session.to_string()));
    }
    if let Some(protocol) = protocol {
        headers.push((PROTOCOL_HEADER.to_string(), protocol.to_string()));
    }
    headers
}

/// Whether an HTTP status means the server took the message. Any 2xx status counts, which covers
/// 200 for a request and 202 for a notification.
pub fn reply_is_accepted(status: u16) -> bool {
    (200..300).contains(&status)
}

/// The plain sentence for a status that was not accepted.
pub fn status_text(status: u16) -> String {
    format!("the MCP server answered with status {status}")
}

/// Whether a reply is an event stream rather than JSON.
pub fn reply_is_stream(content_type: &str) -> bool {
    content_type.contains("text/event-stream")
}

/// The messages in the body of a POST reply: one JSON message, a JSON batch, or an event stream.
pub fn reply_messages(content_type: &str, body: &[u8]) -> Result<Vec<Value>, String> {
    if reply_is_stream(content_type) {
        let mut stream = EventStream::default();
        let mut messages = stream.push(&String::from_utf8_lossy(body));
        messages.extend(stream.finish());
        return Ok(messages);
    }
    let value: Value =
        serde_json::from_slice(body).map_err(|_| "the reply is not JSON".to_string())?;
    Ok(match value {
        Value::Array(items) => items,
        single => vec![single],
    })
}

/// Reads server-sent events as they arrive. Each event's `data:` lines are joined and read as one
/// JSON message. Events that are not JSON are dropped.
#[derive(Debug, Default)]
pub struct EventStream {
    buffer: String,
}

impl EventStream {
    /// Adds text and returns the messages of the events it completed.
    pub fn push(&mut self, text: &str) -> Vec<Value> {
        self.buffer.push_str(text);
        self.buffer = self.buffer.replace("\r\n", "\n");
        let mut messages = Vec::new();
        while let Some(end) = self.buffer.find("\n\n") {
            let event: String = self.buffer.drain(..end + 2).collect();
            messages.extend(Self::message_of(&event));
        }
        messages
    }

    /// The message of an event the stream ended in the middle of, if it holds one.
    pub fn finish(&mut self) -> Vec<Value> {
        let event = std::mem::take(&mut self.buffer);
        Self::message_of(&event).into_iter().collect()
    }

    fn message_of(event: &str) -> Option<Value> {
        let data: Vec<&str> = event
            .lines()
            .filter_map(|l| l.strip_prefix("data:"))
            .map(|d| d.strip_prefix(' ').unwrap_or(d))
            .collect();
        if data.is_empty() {
            return None;
        }
        serde_json::from_str(&data.join("\n")).ok()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn unsupported_revisions_are_refused() {
        assert_eq!(
            checked_version(&json!({ "protocolVersion": "2025-03-26" })).unwrap(),
            "2025-03-26"
        );
        assert_eq!(checked_version(&json!({})).unwrap(), PROTOCOL_VERSION);
        assert_eq!(
            checked_version(&json!({ "protocolVersion": "2025-11-25" })).unwrap_err(),
            "This server speaks MCP 2025-11-25; Imp speaks 2025-06-18, 2025-03-26, 2024-11-05."
        );
    }

    #[test]
    fn requests_carry_ids_and_methods() {
        let init = initialize_request(1);
        assert_eq!(init["jsonrpc"], "2.0");
        assert_eq!(init["id"], 1);
        assert_eq!(init["method"], "initialize");
        assert_eq!(init["params"]["protocolVersion"], PROTOCOL_VERSION);
        assert_eq!(init["params"]["clientInfo"]["name"], "imp");
        assert_eq!(
            initialized_notification(),
            json!({ "jsonrpc": "2.0", "method": "notifications/initialized" })
        );
        assert_eq!(tools_list_request(2, None)["params"], json!({}));
        assert_eq!(
            tools_list_request(3, Some("p2"))["params"],
            json!({ "cursor": "p2" })
        );
        let call = tools_call_request(4, "add", json!({ "a": 1 }));
        assert_eq!(call["method"], "tools/call");
        assert_eq!(
            call["params"],
            json!({ "name": "add", "arguments": { "a": 1 } })
        );
    }

    #[test]
    fn answers_errors_and_server_requests_are_told_apart() {
        let ok = parse_message(r#"{"jsonrpc":"2.0","id":7,"result":{"x":1}}"#);
        assert_eq!(
            ok,
            Incoming::Answer {
                id: 7,
                result: Ok(json!({ "x": 1 }))
            }
        );
        let missing = parse_message(r#"{"id":8}"#);
        assert_eq!(
            missing,
            Incoming::Answer {
                id: 8,
                result: Ok(json!(null))
            }
        );
        let failed = parse_message(r#"{"id":9,"error":{"code":-32000,"message":"nope"}}"#);
        assert_eq!(
            failed,
            Incoming::Answer {
                id: 9,
                result: Err(RpcError {
                    code: -32000,
                    message: "nope".into()
                })
            }
        );
        let odd = parse_message(r#"{"id":10,"error":{}}"#);
        assert_eq!(
            odd,
            Incoming::Answer {
                id: 10,
                result: Err(RpcError {
                    code: -1,
                    message: "unknown error".into()
                })
            }
        );
        // Chatter that is not JSON, notifications and answers without a number id need no action.
        assert_eq!(parse_message("npm notice hello"), Incoming::Skip);
        assert_eq!(
            parse_message(r#"{"method":"notifications/message"}"#),
            Incoming::Skip
        );
        assert_eq!(parse_message(r#"{"id":"abc","result":{}}"#), Incoming::Skip);
        // A request from the server: only ping is answered.
        let ping = parse_message(r#"{"id":99,"method":"ping"}"#);
        assert_eq!(
            ping,
            Incoming::Request {
                reply: json!({ "jsonrpc": "2.0", "id": 99, "result": {} })
            }
        );
        let other = parse_message(r#"{"id":"r","method":"roots/list"}"#);
        assert_eq!(
            other,
            Incoming::Request {
                reply: json!({ "jsonrpc": "2.0", "id": "r", "error": { "code": -32601, "message": "Method not found" } })
            }
        );
    }

    #[test]
    fn the_server_may_pick_an_older_protocol_version() {
        assert_eq!(
            negotiated_version(&json!({ "protocolVersion": "2025-03-26" })),
            "2025-03-26"
        );
        assert_eq!(negotiated_version(&json!({})), PROTOCOL_VERSION);
    }

    #[test]
    fn tool_pages_follow_cursors_once_and_stop_at_the_limit() {
        let page = tools_page(
            &json!({ "tools": [
                { "name": "add", "description": "Adds", "inputSchema": { "type": "object", "properties": {} } },
                { "description": "no name" },
                { "name": "bare" },
            ], "nextCursor": "p2" }),
            &[],
        );
        assert_eq!(page.tools.len(), 2);
        assert_eq!(page.tools[0].name, "add");
        assert_eq!(page.tools[1].description, "");
        assert_eq!(page.tools[1].input_schema, json!({ "type": "object" }));
        assert_eq!(page.next_cursor.as_deref(), Some("p2"));
        let again = tools_page(
            &json!({ "tools": [], "nextCursor": "p2" }),
            &["p2".to_string()],
        );
        assert_eq!(again.next_cursor, None);
        let many: Vec<String> = (0..MAX_TOOL_PAGES).map(|n| n.to_string()).collect();
        assert_eq!(
            tools_page(&json!({ "nextCursor": "z" }), &many).next_cursor,
            None
        );
        assert_eq!(tools_page(&json!({}), &[]).next_cursor, None);
    }

    #[test]
    fn tool_results_become_text() {
        let result = json!({ "content": [
            { "type": "text", "text": "a" },
            { "type": "image", "data": "x" },
            { "type": "resource", "resource": { "text": "r" } },
            { "type": "resource", "resource": {} },
            { "type": "resource_link", "uri": "file:///x" },
            { "text": "typeless" },
        ], "isError": true });
        assert_eq!(
            tool_result_text(&result),
            "Error: a\n[image]\nr\n[resource]\n[resource: file:///x]\n[unknown]"
        );
        assert_eq!(
            tool_result_text(&json!({ "content": [{ "type": "text", "text": "ok" }] })),
            "ok"
        );
        assert_eq!(tool_result_text(&json!({})), "");
    }

    #[test]
    fn arguments_are_json_or_empty() {
        assert_eq!(parse_arguments("  ").unwrap(), json!({}));
        assert_eq!(parse_arguments(r#"{"a":1}"#).unwrap(), json!({ "a": 1 }));
        assert!(
            parse_arguments("{oops")
                .unwrap_err()
                .starts_with("the arguments are not valid JSON: ")
        );
    }

    #[test]
    fn tool_names_are_exposed_sorted_by_server_with_collisions_numbered() {
        assert_eq!(
            exposed_name("git hub", "list/issues"),
            "git_hub__list_issues"
        );
        assert_eq!(exposed_name("", ""), "____");
        assert_eq!(exposed_name(&"a".repeat(50), &"b".repeat(50)).len(), 64);
        let servers = vec![
            ("zed".to_string(), vec!["go".to_string()]),
            (
                "a b".to_string(),
                vec!["x y".to_string(), "x_y".to_string(), "x.y".to_string()],
            ),
        ];
        let out = expose(&servers);
        let names: Vec<&str> = out.iter().map(|t| t.name.as_str()).collect();
        assert_eq!(names, ["a_b__x_y", "a_b__x_y_2", "a_b__x_y_3", "zed__go"]);
        assert_eq!(out[0].server, 1);
        assert_eq!(out[0].tool, "x y");
        assert_eq!(out[0].id, "mcp.a_b.x y");
        assert_eq!(out[0].group, "mcp.a_b");
        assert_eq!(out[3].server, 0);
        let long = expose(&[("s".repeat(40), vec!["t".repeat(40), "t".repeat(40)])]);
        assert_eq!(long[0].name.len(), 64);
        assert_eq!(long[1].name.len(), 64);
        assert!(long[1].name.ends_with("_2"));
    }

    #[test]
    fn sessions_ride_in_headers() {
        let first = post_headers(None, None);
        assert!(first.contains(&("Content-Type".to_string(), "application/json".to_string())));
        assert!(first.contains(&(
            "Accept".to_string(),
            "application/json, text/event-stream".to_string()
        )));
        assert!(
            !first
                .iter()
                .any(|(n, _)| n.eq_ignore_ascii_case(SESSION_HEADER))
        );
        let later = post_headers(Some("s-7"), Some("2025-03-26"));
        assert!(later.contains(&(SESSION_HEADER.to_string(), "s-7".to_string())));
        assert!(later.contains(&(PROTOCOL_HEADER.to_string(), "2025-03-26".to_string())));
        assert_eq!(end_headers(None, Some("2025-03-26")), None);
        let end = end_headers(Some("s-7"), Some("2025-03-26")).unwrap();
        assert_eq!(
            end,
            [
                (SESSION_HEADER.to_string(), "s-7".to_string()),
                (PROTOCOL_HEADER.to_string(), "2025-03-26".to_string())
            ]
        );
    }

    #[test]
    fn replies_are_json_batches_or_event_streams() {
        assert!(reply_is_accepted(200) && reply_is_accepted(202) && !reply_is_accepted(401));
        assert_eq!(status_text(401), "the MCP server answered with status 401");
        assert!(reply_is_stream("text/event-stream; charset=utf-8"));
        assert!(!reply_is_stream("application/json"));
        let batch = reply_messages("application/json", br#"[{"id":3},{"id":4}]"#).unwrap();
        assert_eq!(batch, [json!({ "id": 3 }), json!({ "id": 4 })]);
        assert_eq!(
            reply_messages("application/json", br#"{"id":5}"#).unwrap(),
            [json!({ "id": 5 })]
        );
        assert_eq!(
            reply_messages("application/json", b"<html>").unwrap_err(),
            "the reply is not JSON"
        );
        let text = "event: message\ndata: {\"id\":1,\r\ndata: \"result\":{}}\n\n: comment\ndata: {\"id\":2}\n\ndata: not json\n\n";
        let events = reply_messages("text/event-stream", text.as_bytes()).unwrap();
        assert_eq!(
            events,
            [json!({ "id": 1, "result": {} }), json!({ "id": 2 })]
        );
    }

    #[test]
    fn an_event_stream_can_arrive_in_pieces() {
        let mut stream = EventStream::default();
        assert!(stream.push("data: {\"id\"").is_empty());
        assert!(stream.push(":1}\r").is_empty());
        let first = stream.push("\n\r\ndata: {\"id\":2}\n\n");
        assert_eq!(first, [json!({ "id": 1 }), json!({ "id": 2 })]);
    }
}
