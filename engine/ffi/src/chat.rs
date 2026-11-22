//! The rules of talking to an OpenAI-compatible service: request bodies, whole replies, model
//! lists, error messages and a streamed reply read line by line. The apps only move the bytes.

use imp_engine::chat;
use std::sync::Mutex;

/// What went wrong in the stream.
#[derive(Debug, uniffi::Error)]
pub enum ChatStreamError {
    /// The service sent an error in the stream.
    Http { status: u16, message: String },
    /// The answer held nothing to use. `what` says what was missing, such as `text`.
    Empty { what: String },
    /// Anything else, as a sentence.
    Other { message: String },
}

impl std::fmt::Display for ChatStreamError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Http { status, message } => write!(f, "{status}: {message}"),
            Self::Empty { what } => write!(f, "the model returned no {what}"),
            Self::Other { message } => f.write_str(message),
        }
    }
}

impl From<chat::ChatError> for ChatStreamError {
    fn from(error: chat::ChatError) -> Self {
        match error {
            chat::ChatError::Http { status, message } => Self::Http { status, message },
            chat::ChatError::Empty(what) => Self::Empty { what },
            other => Self::Other {
                message: other.to_string(),
            },
        }
    }
}

/// A call the model wants made.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct StreamToolCall {
    pub id: String,
    pub name: String,
    pub arguments: String,
}

/// A whole reply.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct StreamReply {
    pub text: String,
    /// What the model thought first. For showing only: it is never sent back.
    pub reasoning: String,
    pub tool_calls: Vec<StreamToolCall>,
}

#[derive(uniffi::Object, Default)]
pub struct ChatStream(Mutex<chat::ChatStream>);

#[uniffi::export]
impl ChatStream {
    #[uniffi::constructor]
    pub fn new() -> Self {
        Self::default()
    }

    /// Reads one line of the stream. True when it added text.
    pub fn feed_line(&self, line: String) -> Result<bool, ChatStreamError> {
        self.0
            .lock()
            .expect("stream lock")
            .feed_line(&line)
            .map_err(ChatStreamError::from)
    }

    /// Whether the service said it is done.
    pub fn is_done(&self) -> bool {
        self.0.lock().expect("stream lock").is_done()
    }

    /// All the text so far, as it arrived.
    pub fn text(&self) -> String {
        self.0.lock().expect("stream lock").text().to_string()
    }

    /// All the reasoning so far, as it arrived. For showing, never for sending back to the model.
    pub fn reasoning(&self) -> String {
        self.0.lock().expect("stream lock").reasoning().to_string()
    }

    /// The whole reply so far.
    pub fn reply(&self) -> StreamReply {
        self.0.lock().expect("stream lock").reply().into()
    }
}

impl From<chat::ChatReply> for StreamReply {
    fn from(reply: chat::ChatReply) -> Self {
        Self {
            text: reply.text,
            reasoning: reply.reasoning,
            tool_calls: reply.tool_calls.into_iter().map(Into::into).collect(),
        }
    }
}

impl From<chat::ToolCall> for StreamToolCall {
    fn from(c: chat::ToolCall) -> Self {
        Self {
            id: c.id,
            name: c.name,
            arguments: c.arguments,
        }
    }
}

impl From<StreamToolCall> for chat::ToolCall {
    fn from(c: StreamToolCall) -> Self {
        Self {
            id: c.id,
            name: c.name,
            arguments: c.arguments,
        }
    }
}

/// Who said a message.
#[derive(Debug, Clone, Copy, PartialEq, uniffi::Enum)]
pub enum ModelRole {
    System,
    User,
    Assistant,
    Tool,
}

impl From<ModelRole> for chat::Role {
    fn from(role: ModelRole) -> Self {
        match role {
            ModelRole::System => Self::System,
            ModelRole::User => Self::User,
            ModelRole::Assistant => Self::Assistant,
            ModelRole::Tool => Self::Tool,
        }
    }
}

impl From<chat::Role> for ModelRole {
    fn from(role: chat::Role) -> Self {
        match role {
            chat::Role::System => Self::System,
            chat::Role::User => Self::User,
            chat::Role::Assistant => Self::Assistant,
            chat::Role::Tool => Self::Tool,
        }
    }
}

/// One message of a conversation with a model.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct ModelMessage {
    pub role: ModelRole,
    pub content: String,
    pub tool_calls: Vec<StreamToolCall>,
    /// On a tool message: the call it answers.
    pub tool_call_id: Option<String>,
    /// Pictures as data URLs.
    pub images: Vec<String>,
    /// A user message that carries pictures a tool returned.
    pub attachment: bool,
}

impl From<ModelMessage> for chat::ChatMessage {
    fn from(m: ModelMessage) -> Self {
        Self {
            role: m.role.into(),
            content: m.content,
            tool_calls: m.tool_calls.into_iter().map(Into::into).collect(),
            tool_call_id: m.tool_call_id,
            images: m.images,
            attachment: m.attachment,
        }
    }
}

impl From<chat::ChatMessage> for ModelMessage {
    fn from(m: chat::ChatMessage) -> Self {
        Self {
            role: m.role.into(),
            content: m.content,
            tool_calls: m.tool_calls.into_iter().map(Into::into).collect(),
            tool_call_id: m.tool_call_id,
            images: m.images,
            attachment: m.attachment,
        }
    }
}

/// A function the model may call. `parameters_json` is the JSON schema of its arguments.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct ModelTool {
    pub name: String,
    pub description: String,
    pub parameters_json: String,
}

impl ModelTool {
    pub(crate) fn into_spec(self) -> Result<chat::ToolSpec, ChatStreamError> {
        let parameters =
            serde_json::from_str(&self.parameters_json).map_err(|e| ChatStreamError::Other {
                message: format!("the tool {} has no valid schema: {e}", self.name),
            })?;
        Ok(chat::ToolSpec {
            name: self.name,
            description: self.description,
            parameters,
        })
    }
}

impl From<chat::ToolSpec> for ModelTool {
    fn from(spec: chat::ToolSpec) -> Self {
        Self {
            name: spec.name,
            description: spec.description,
            parameters_json: spec.parameters.to_string(),
        }
    }
}

pub(crate) fn specs(tools: Vec<ModelTool>) -> Result<Vec<chat::ToolSpec>, ChatStreamError> {
    tools.into_iter().map(ModelTool::into_spec).collect()
}

/// The JSON body of a chat-completions request. With `stream` the answer comes as server-sent
/// events. The `tools` key is left out when there are no tools.
#[uniffi::export]
pub fn chat_request_body(
    model: String,
    messages: Vec<ModelMessage>,
    tools: Vec<ModelTool>,
    stream: bool,
) -> Result<String, ChatStreamError> {
    let messages: Vec<chat::ChatMessage> = messages.into_iter().map(Into::into).collect();
    Ok(chat::request_body(&model, &messages, &specs(tools)?, stream).to_string())
}

/// The reply in the JSON of a whole answer. A service error inside it, or an answer with neither
/// text nor tool calls, is an error.
#[uniffi::export]
pub fn parse_chat_reply(body: String) -> Result<StreamReply, ChatStreamError> {
    Ok(chat::parse_reply(&body)?.into())
}

/// The model ids in a model list, sorted and without repeats.
#[uniffi::export]
pub fn parse_model_ids(body: String) -> Vec<String> {
    chat::parse_model_ids(&body)
}

/// A short message out of the body of an error answer.
#[uniffi::export]
pub fn chat_error_message(body: String) -> String {
    chat::error_message(&body)
}

/// Whether an error answer says the account is out of credit (a 429 whose error is
/// `insufficient_quota`). Other 429 answers are rate limits.
#[uniffi::export]
pub fn chat_is_out_of_credit(status: u16, body: String) -> bool {
    chat::is_out_of_credit(status, &body)
}

/// The one message that carries the pictures (data URLs) the tools in `tools` returned.
#[uniffi::export]
pub fn tool_pictures_message(images: Vec<String>, tools: Vec<String>) -> ModelMessage {
    chat::ChatMessage::attachment(images, &tools).into()
}
