//! The MCP protocol for the apps. The apps move the messages (a child process, URLSession) and ask
//! these functions what each message says and what to send next. Messages are JSON text.

use imp_engine::mcp::protocol;
use serde_json::Value;

/// Why a message could not be made or read, as a sentence.
#[derive(Debug, uniffi::Error)]
pub enum McpProtocolError {
    Failed { message: String },
}

impl std::fmt::Display for McpProtocolError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Failed { message } => f.write_str(message),
        }
    }
}

/// What one message from the server asks of the client.
#[derive(Debug, Clone, PartialEq, uniffi::Enum)]
pub enum McpIncoming {
    /// Nothing to do: chatter, a notification, or an answer without a number id.
    Skip,
    /// The answer to request `id`. `result_json` is its result.
    Answer { id: u64, result_json: String },
    /// The server refused request `id`.
    Failure { id: u64, code: i64, message: String },
    /// A request from the server. Send `reply_json` back.
    Request { reply_json: String },
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct McpTool {
    pub name: String,
    pub description: String,
    pub input_schema_json: String,
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct McpToolPage {
    pub tools: Vec<McpTool>,
    /// The cursor of the next page. Nothing on the last page, or when the cursor was already read.
    pub next_cursor: Option<String>,
}

/// A tool as the model is offered it.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct McpExposedTool {
    /// The index of its server in the list given to `mcp_expose`.
    pub server: u32,
    /// The server's own name for the tool.
    pub tool: String,
    /// What the model calls it.
    pub name: String,
    /// Its registry id, `mcp.<server>.<tool>`.
    pub id: String,
    /// Its group id, `mcp.<server>`.
    pub group: String,
}

/// The tool names one server offers.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct McpServerTools {
    pub name: String,
    pub tools: Vec<String>,
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct McpHeader {
    pub name: String,
    pub value: String,
}

fn headers(pairs: Vec<(String, String)>) -> Vec<McpHeader> {
    pairs
        .into_iter()
        .map(|(name, value)| McpHeader { name, value })
        .collect()
}

fn json(text: &str) -> Result<Value, McpProtocolError> {
    serde_json::from_str(text).map_err(|_| McpProtocolError::Failed {
        message: "the MCP server sent something that is not JSON".into(),
    })
}

#[uniffi::export]
pub fn mcp_initialize_request(id: u64) -> String {
    protocol::initialize_request(id).to_string()
}

#[uniffi::export]
pub fn mcp_initialized_notification() -> String {
    protocol::initialized_notification().to_string()
}

#[uniffi::export]
pub fn mcp_tools_list_request(id: u64, cursor: Option<String>) -> String {
    protocol::tools_list_request(id, cursor.as_deref()).to_string()
}

/// The call of a tool. `arguments` is the JSON text the model wrote, or nothing.
#[uniffi::export]
pub fn mcp_tools_call_request(
    id: u64,
    name: String,
    arguments: String,
) -> Result<String, McpProtocolError> {
    let arguments = protocol::parse_arguments(&arguments)
        .map_err(|message| McpProtocolError::Failed { message })?;
    Ok(protocol::tools_call_request(id, &name, arguments).to_string())
}

/// Reads one message the server sent. Text that is not JSON is skipped.
#[uniffi::export]
pub fn mcp_parse_message(text: String) -> McpIncoming {
    match protocol::parse_message(&text) {
        protocol::Incoming::Skip => McpIncoming::Skip,
        protocol::Incoming::Answer {
            id,
            result: Ok(result),
        } => McpIncoming::Answer {
            id,
            result_json: result.to_string(),
        },
        protocol::Incoming::Answer { id, result: Err(e) } => McpIncoming::Failure {
            id,
            code: e.code,
            message: e.message,
        },
        protocol::Incoming::Request { reply } => McpIncoming::Request {
            reply_json: reply.to_string(),
        },
    }
}

/// One page of tools from the result of `tools/list`. `seen_cursors` are the cursors already read.
#[uniffi::export]
pub fn mcp_tools_page(
    result_json: String,
    seen_cursors: Vec<String>,
) -> Result<McpToolPage, McpProtocolError> {
    let page = protocol::tools_page(&json(&result_json)?, &seen_cursors);
    Ok(McpToolPage {
        tools: page
            .tools
            .into_iter()
            .map(|t| McpTool {
                name: t.name,
                description: t.description,
                input_schema_json: t.input_schema.to_string(),
            })
            .collect(),
        next_cursor: page.next_cursor,
    })
}

/// The text a model reads for the result of `tools/call`.
#[uniffi::export]
pub fn mcp_tool_result_text(result_json: String) -> Result<String, McpProtocolError> {
    Ok(protocol::tool_result_text(&json(&result_json)?))
}

/// The tools of several servers as the model is offered them, servers in name order.
#[uniffi::export]
pub fn mcp_expose(servers: Vec<McpServerTools>) -> Vec<McpExposedTool> {
    let servers: Vec<(String, Vec<String>)> =
        servers.into_iter().map(|s| (s.name, s.tools)).collect();
    protocol::expose(&servers)
        .into_iter()
        .map(|t| McpExposedTool {
            server: t.server as u32,
            tool: t.tool,
            name: t.name,
            id: t.id,
            group: t.group,
        })
        .collect()
}

/// The name of the header that carries the session id.
#[uniffi::export]
pub fn mcp_session_header_name() -> String {
    protocol::SESSION_HEADER.to_string()
}

/// The headers of a POST, once the session and protocol version are known.
#[uniffi::export]
pub fn mcp_post_headers(
    session: Option<String>,
    protocol_version: Option<String>,
) -> Vec<McpHeader> {
    headers(protocol::post_headers(
        session.as_deref(),
        protocol_version.as_deref(),
    ))
}

/// The headers of the DELETE that ends a session, or nothing when there is no session.
#[uniffi::export]
pub fn mcp_end_headers(
    session: Option<String>,
    protocol_version: Option<String>,
) -> Option<Vec<McpHeader>> {
    protocol::end_headers(session.as_deref(), protocol_version.as_deref()).map(headers)
}

/// Whether an HTTP status means the server took the message.
#[uniffi::export]
pub fn mcp_reply_is_accepted(status: u16) -> bool {
    protocol::reply_is_accepted(status)
}

/// The plain sentence for a status that was not accepted.
#[uniffi::export]
pub fn mcp_status_text(status: u16) -> String {
    protocol::status_text(status)
}

/// The messages in the body of a POST reply (JSON, a JSON batch, or an event stream), each as text.
#[uniffi::export]
pub fn mcp_reply_messages(
    content_type: String,
    body: Vec<u8>,
) -> Result<Vec<String>, McpProtocolError> {
    protocol::reply_messages(&content_type, &body)
        .map(|messages| messages.iter().map(Value::to_string).collect())
        .map_err(|message| McpProtocolError::Failed { message })
}
