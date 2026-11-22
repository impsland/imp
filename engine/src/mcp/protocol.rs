//! The MCP rules that need no I/O: the JSON-RPC requests an MCP client sends, how it reads the replies,
//! the names the model sees for each server's tools, and what a status or an event stream means. The
//! transports in `client` and `http` only move the text these functions build and read.

use crate::tools::{mcp_group_id, mcp_id, server_key};
use base64::Engine as _;
use base64::engine::general_purpose::STANDARD as BASE64;
use serde_json::{Value, json};

/// The newest revision Imp speaks. It has no handshake and no session: every request names the
/// revision and the client in its `_meta` and in the `MCP-Protocol-Version` and `Mcp-Method` headers.
/// Imp speaks it over HTTP and asks for it first with `server/discover`.
pub const STATELESS_VERSION: &str = "2026-07-28";
/// The revision asked for in `initialize`, the handshake of servers without [`STATELESS_VERSION`].
pub const HANDSHAKE_VERSION: &str = "2025-11-25";
/// The handshake revisions Imp speaks, newest first. A server may answer `initialize` with any of them.
pub const HANDSHAKE_VERSIONS: &[&str] =
    &[HANDSHAKE_VERSION, "2025-06-18", "2025-03-26", "2024-11-05"];
/// The header that carries the session a handshake server starts after `initialize`.
pub const SESSION_HEADER: &str = "Mcp-Session-Id";
/// The header that carries the revision: on every request of [`STATELESS_VERSION`], and on every
/// request after `initialize` with a handshake revision.
pub const PROTOCOL_HEADER: &str = "MCP-Protocol-Version";
/// The header that repeats a stateless request's method.
pub const METHOD_HEADER: &str = "Mcp-Method";
/// The header that repeats the name of the tool a stateless `tools/call` calls.
pub const NAME_HEADER: &str = "Mcp-Name";
/// The `_meta` keys of a stateless request.
const META_VERSION: &str = "io.modelcontextprotocol/protocolVersion";
const META_CAPABILITIES: &str = "io.modelcontextprotocol/clientCapabilities";
const META_CLIENT: &str = "io.modelcontextprotocol/clientInfo";
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

fn client_info() -> Value {
    json!({ "name": "imp", "version": env!("CARGO_PKG_VERSION") })
}

/// A request in `version`. A stateless request carries the revision and the client in `_meta`.
fn request(id: u64, method: &str, mut params: Value, version: &str) -> Value {
    if version == STATELESS_VERSION {
        params["_meta"] = json!({
            META_VERSION: STATELESS_VERSION,
            META_CAPABILITIES: {},
            META_CLIENT: client_info(),
        });
    }
    json!({ "jsonrpc": "2.0", "id": id, "method": method, "params": params })
}

/// Asks a server whether it speaks [`STATELESS_VERSION`]. See [`speaks_stateless`] for the answer.
pub fn discover_request(id: u64) -> Value {
    request(id, "server/discover", json!({}), STATELESS_VERSION)
}

/// Whether the result of `server/discover` lists [`STATELESS_VERSION`].
pub fn speaks_stateless(discover_result: &Value) -> bool {
    discover_result["supportedVersions"]
        .as_array()
        .is_some_and(|versions| versions.iter().any(|v| v == STATELESS_VERSION))
}

/// The handshake, for a server that does not speak [`STATELESS_VERSION`].
pub fn initialize_request(id: u64) -> Value {
    json!({
        "jsonrpc": "2.0",
        "id": id,
        "method": "initialize",
        "params": {
            "protocolVersion": HANDSHAKE_VERSION,
            "capabilities": {},
            "clientInfo": client_info(),
        },
    })
}

pub fn initialized_notification() -> Value {
    json!({ "jsonrpc": "2.0", "method": "notifications/initialized" })
}

/// A page of the tool list, in the revision the connection speaks.
pub fn tools_list_request(id: u64, cursor: Option<&str>, version: &str) -> Value {
    let params = cursor.map_or_else(|| json!({}), |c| json!({ "cursor": c }));
    request(id, "tools/list", params, version)
}

/// A tool call, in the revision the connection speaks.
pub fn tools_call_request(id: u64, name: &str, arguments: Value, version: &str) -> Value {
    request(
        id,
        "tools/call",
        json!({ "name": name, "arguments": arguments }),
        version,
    )
}

/// The revision to speak after `initialize`: the one the server picked (ours when it names none), or
/// the sentence to show when Imp does not speak it (the client must then disconnect).
pub fn checked_version(initialize_result: &Value) -> Result<String, String> {
    let version = initialize_result["protocolVersion"]
        .as_str()
        .unwrap_or(HANDSHAKE_VERSION);
    if HANDSHAKE_VERSIONS.contains(&version) {
        Ok(version.to_string())
    } else {
        Err(format!(
            "This server speaks MCP {version}; Imp speaks {STATELESS_VERSION}, {}.",
            HANDSHAKE_VERSIONS.join(", ")
        ))
    }
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
/// brackets. A result the tool marks as an error starts with "Error:", and so does a stateless result
/// that asks for more input (Imp offers no elicitation, so it has none to give).
pub fn tool_result_text(result: &Value) -> String {
    if result["resultType"] == "input_required" {
        return "Error: the tool asked for more input, which Imp cannot give.".to_string();
    }
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

/// The headers of a POST of `message`: the content types, the session once a handshake server
/// started one, and the revision once it is known. A stateless request also names its method and, for
/// `tools/call`, the tool.
pub fn post_headers(
    message: &Value,
    session: Option<&str>,
    version: Option<&str>,
) -> Vec<(String, String)> {
    let mut headers = vec![
        ("Content-Type".to_string(), "application/json".to_string()),
        (
            "Accept".to_string(),
            "application/json, text/event-stream".to_string(),
        ),
    ];
    headers.extend(session_headers(session, version));
    if version == Some(STATELESS_VERSION)
        && let Some(method) = message["method"].as_str()
    {
        headers.push((METHOD_HEADER.to_string(), method.to_string()));
        if method == "tools/call"
            && let Some(name) = message["params"]["name"].as_str()
        {
            headers.push((NAME_HEADER.to_string(), header_value(name)));
        }
    }
    headers
}

/// A value as a header carries it: as it is when it is plain printable ASCII, otherwise
/// `=?base64?…?=` around its UTF-8 bytes (and so is a plain value that looks like that form).
pub fn header_value(text: &str) -> String {
    let plain = !text.is_empty()
        && text.trim() == text
        && text.bytes().all(|b| b == b' ' || b.is_ascii_graphic())
        && !(text.starts_with("=?base64?") && text.ends_with("?="));
    if plain {
        text.to_string()
    } else {
        format!("=?base64?{}?=", BASE64.encode(text))
    }
}

/// The headers that end a session with a DELETE, or nothing when no session was started (a stateless
/// connection never has one).
pub fn end_headers(session: Option<&str>, version: Option<&str>) -> Option<Vec<(String, String)>> {
    session?;
    Some(session_headers(session, version))
}

fn session_headers(session: Option<&str>, version: Option<&str>) -> Vec<(String, String)> {
    let mut headers = Vec::new();
    if let Some(session) = session {
        headers.push((SESSION_HEADER.to_string(), session.to_string()));
    }
    if let Some(version) = version {
        headers.push((PROTOCOL_HEADER.to_string(), version.to_string()));
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
    fn the_server_may_pick_any_handshake_revision_imp_speaks() {
        assert_eq!(
            checked_version(&json!({ "protocolVersion": "2025-03-26" })).unwrap(),
            "2025-03-26"
        );
        assert_eq!(checked_version(&json!({})).unwrap(), HANDSHAKE_VERSION);
        assert_eq!(
            checked_version(&json!({ "protocolVersion": "2024-01-01" })).unwrap_err(),
            "This server speaks MCP 2024-01-01; Imp speaks 2026-07-28, 2025-11-25, 2025-06-18, 2025-03-26, 2024-11-05."
        );
    }

    #[test]
    fn handshake_requests_carry_ids_and_methods() {
        let init = initialize_request(1);
        assert_eq!(init["jsonrpc"], "2.0");
        assert_eq!(init["id"], 1);
        assert_eq!(init["method"], "initialize");
        assert_eq!(init["params"]["protocolVersion"], HANDSHAKE_VERSION);
        assert_eq!(init["params"]["clientInfo"]["name"], "imp");
        assert_eq!(
            initialized_notification(),
            json!({ "jsonrpc": "2.0", "method": "notifications/initialized" })
        );
        assert_eq!(
            tools_list_request(2, None, "2025-06-18")["params"],
            json!({})
        );
        assert_eq!(
            tools_list_request(3, Some("p2"), HANDSHAKE_VERSION)["params"],
            json!({ "cursor": "p2" })
        );
        let call = tools_call_request(4, "add", json!({ "a": 1 }), HANDSHAKE_VERSION);
        assert_eq!(call["method"], "tools/call");
        assert_eq!(
            call["params"],
            json!({ "name": "add", "arguments": { "a": 1 } })
        );
    }

    #[test]
    fn stateless_requests_name_the_revision_and_the_client_in_meta() {
        let discover = discover_request(1);
        assert_eq!(discover["method"], "server/discover");
        let meta = &discover["params"]["_meta"];
        assert_eq!(meta[META_VERSION], STATELESS_VERSION);
        assert_eq!(meta[META_CAPABILITIES], json!({}));
        assert_eq!(meta[META_CLIENT]["name"], "imp");
        let call = tools_call_request(2, "add", json!({ "a": 1 }), STATELESS_VERSION);
        assert_eq!(call["params"]["name"], "add");
        assert_eq!(call["params"]["arguments"], json!({ "a": 1 }));
        assert_eq!(call["params"]["_meta"][META_VERSION], STATELESS_VERSION);
        let list = tools_list_request(3, Some("p2"), STATELESS_VERSION);
        assert_eq!(list["params"]["cursor"], "p2");
        assert!(list["params"]["_meta"].is_object());
    }

    #[test]
    fn discovery_finds_the_stateless_revision() {
        assert!(speaks_stateless(
            &json!({ "supportedVersions": ["2026-07-28", "2025-11-25"] })
        ));
        assert!(!speaks_stateless(
            &json!({ "supportedVersions": ["2025-11-25"] })
        ));
        assert!(!speaks_stateless(&json!({})));
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
        assert_eq!(
            tool_result_text(&json!({ "resultType": "input_required", "inputRequests": {} })),
            "Error: the tool asked for more input, which Imp cannot give."
        );
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
        let list = tools_list_request(1, None, HANDSHAKE_VERSION);
        let first = post_headers(&initialize_request(1), None, None);
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
        let later = post_headers(&list, Some("s-7"), Some("2025-03-26"));
        assert!(later.contains(&(SESSION_HEADER.to_string(), "s-7".to_string())));
        assert!(later.contains(&(PROTOCOL_HEADER.to_string(), "2025-03-26".to_string())));
        assert!(!later.iter().any(|(n, _)| n == METHOD_HEADER));
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
    fn stateless_headers_repeat_the_method_and_the_tool() {
        let header = |headers: &[(String, String)], name: &str| {
            headers
                .iter()
                .find(|(n, _)| n == name)
                .map(|(_, v)| v.clone())
        };
        let discover = post_headers(&discover_request(1), None, Some(STATELESS_VERSION));
        assert_eq!(
            header(&discover, PROTOCOL_HEADER).as_deref(),
            Some(STATELESS_VERSION)
        );
        assert_eq!(
            header(&discover, METHOD_HEADER).as_deref(),
            Some("server/discover")
        );
        assert_eq!(header(&discover, NAME_HEADER), None);
        let call = tools_call_request(2, "Hello, 世界", json!({}), STATELESS_VERSION);
        let headers = post_headers(&call, None, Some(STATELESS_VERSION));
        assert_eq!(
            header(&headers, METHOD_HEADER).as_deref(),
            Some("tools/call")
        );
        assert_eq!(
            header(&headers, NAME_HEADER).as_deref(),
            Some("=?base64?SGVsbG8sIOS4lueVjA==?=")
        );
    }

    #[test]
    fn header_values_are_plain_or_base64() {
        assert_eq!(header_value("list_plans"), "list_plans");
        assert_eq!(header_value("with space"), "with space");
        assert_eq!(header_value(" padded "), "=?base64?IHBhZGRlZCA=?=");
        assert_eq!(
            header_value("=?base64?literal?="),
            "=?base64?PT9iYXNlNjQ/bGl0ZXJhbD89?="
        );
        assert_eq!(header_value(""), "=?base64??=");
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
