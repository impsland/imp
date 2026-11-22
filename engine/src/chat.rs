//! An async client for OpenAI-compatible `chat/completions`, with streaming and tool calls.
//!
//! Sending the request is retried by the [`RetryPolicy`]. Once the answer starts streaming it is
//! not retried, because a retry would repeat what was already shown.

#[cfg(feature = "io")]
use crate::retry::{RetryNotice, RetryPolicy};
use crate::retry::{Retryable, is_retryable_status};
#[cfg(feature = "io")]
use futures_util::StreamExt;
use serde::Serialize;
use serde_json::{Value, json};
use std::collections::BTreeMap;
#[cfg(feature = "io")]
use std::time::Duration;

/// Who wrote a message. It is sent to the service in lowercase, as `system`, `user`, `assistant` or `tool`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum Role {
    System,
    User,
    Assistant,
    Tool,
}

/// A call the model wants made. `arguments` is the JSON text as the model wrote it.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct ToolCall {
    pub id: String,
    pub name: String,
    pub arguments: String,
}

/// One message of a conversation as the model sees it. The constructors below build the common roles.
#[derive(Debug, Clone, PartialEq)]
pub struct ChatMessage {
    pub role: Role,
    pub content: String,
    pub tool_calls: Vec<ToolCall>,
    /// Set on `Role::Tool` messages: the call this answers.
    pub tool_call_id: Option<String>,
    /// Media that goes with a user message, as data URLs: pictures, sound and video, for models
    /// that can see and hear. The name stays `images` for the apps. See `media_kind`.
    pub images: Vec<String>,
    /// A user message that is not a turn of the user's: the pictures tools returned, sent right
    /// after the tool results. It reads like any user message to the model.
    pub attachment: bool,
}

impl ChatMessage {
    pub fn new(role: Role, content: impl Into<String>) -> Self {
        Self {
            role,
            content: content.into(),
            tool_calls: Vec::new(),
            tool_call_id: None,
            images: Vec::new(),
            attachment: false,
        }
    }

    pub fn system(content: impl Into<String>) -> Self {
        Self::new(Role::System, content)
    }

    pub fn user(content: impl Into<String>) -> Self {
        Self::new(Role::User, content)
    }

    pub fn assistant(content: impl Into<String>) -> Self {
        Self::new(Role::Assistant, content)
    }

    pub fn tool_result(call_id: impl Into<String>, content: impl Into<String>) -> Self {
        Self {
            tool_call_id: Some(call_id.into()),
            ..Self::new(Role::Tool, content)
        }
    }

    /// The one message that carries the pictures tools returned. `tools` are the names of the
    /// tools that returned them, each named once.
    pub fn attachment(images: Vec<String>, tools: &[String]) -> Self {
        let mut names: Vec<&str> = Vec::new();
        for name in tools {
            if !names.contains(&name.as_str()) {
                names.push(name);
            }
        }
        let what = if images.len() == 1 {
            "Screenshot"
        } else {
            "Screenshots"
        };
        Self {
            images,
            attachment: true,
            ..Self::user(format!(
                "{what} from {}. (Attached automatically for you to look at. The user didn't send it.)",
                names.join(", ")
            ))
        }
    }

    /// The message as a chat-completions request carries it.
    pub fn to_json(&self) -> Value {
        let mut m = json!({ "role": self.role });
        if !self.tool_calls.is_empty() {
            m["content"] = if self.content.is_empty() {
                Value::Null
            } else {
                json!(self.content)
            };
            m["tool_calls"] = self
                .tool_calls
                .iter()
                .map(|c| json!({ "id": c.id, "type": "function", "function": { "name": c.name, "arguments": c.arguments } }))
                .collect();
        } else if !self.images.is_empty() {
            // The media come before the words: a model that reads the words first may take a sound or a
            // video for a file name and say it can't hear or see it.
            let mut parts: Vec<Value> = self.images.iter().map(|url| media_part(url)).collect();
            parts.push(json!({ "type": "text", "text": self.content }));
            m["content"] = Value::Array(parts);
        } else {
            m["content"] = json!(self.content);
        }
        if let Some(id) = &self.tool_call_id {
            m["tool_call_id"] = json!(id);
        }
        m
    }
}

/// The biggest media item in bytes that goes with a message.
pub const MAX_MEDIA_BYTES: usize = 25 << 20;
/// The most media items that go with one message.
pub const MAX_ATTACHMENTS: usize = 4;

/// What a MIME type is, for choosing the request part: `image`, `audio`, `video` or `file`.
pub fn media_kind(mime: &str) -> &'static str {
    let mime = mime.trim().to_ascii_lowercase();
    match mime.split('/').next().unwrap_or("") {
        "image" => "image",
        "audio" => "audio",
        "video" => "video",
        _ => "file",
    }
}

/// A data URL for some bytes, as `ChatMessage::images` holds them.
pub fn data_url(mime: &str, data: &[u8]) -> String {
    use base64::Engine as _;
    format!(
        "data:{mime};base64,{}",
        base64::engine::general_purpose::STANDARD.encode(data)
    )
}

/// The `format` an audio MIME type gets in a request: `mp3`, `wav`, or the subtype as given.
pub fn audio_format(mime: &str) -> String {
    let mime = mime.trim().to_ascii_lowercase();
    let sub = mime.split(';').next().unwrap_or("");
    let sub = sub.split('/').nth(1).unwrap_or("").trim();
    match sub {
        "mpeg" | "mp3" | "x-mp3" => "mp3".into(),
        "wav" | "x-wav" | "wave" => "wav".into(),
        other => other.into(),
    }
}

/// The request part for one data URL. A URL that is not well formed is sent as a picture.
fn media_part(url: &str) -> Value {
    let picture = || json!({ "type": "image_url", "image_url": { "url": url } });
    let Some(rest) = url.strip_prefix("data:") else {
        return picture();
    };
    let Some((head, data)) = rest.split_once(',') else {
        return picture();
    };
    let mime = head.split(';').next().unwrap_or("");
    if !mime.contains('/') {
        return picture();
    }
    match media_kind(mime) {
        "image" => picture(),
        "audio" => json!({
            "type": "input_audio",
            "input_audio": { "data": data, "format": audio_format(mime) }
        }),
        "video" => json!({ "type": "video_url", "video_url": { "url": url } }),
        _ => json!({ "type": "file", "file": { "file_data": url } }),
    }
}

/// A tool as offered to the model.
#[derive(Debug, Clone, PartialEq)]
pub struct ToolSpec {
    pub name: String,
    pub description: String,
    /// A JSON schema for the arguments.
    pub parameters: Value,
}

impl ToolSpec {
    /// The tool as a request lists it.
    pub fn to_json(&self) -> Value {
        json!({ "type": "function", "function": { "name": self.name, "description": self.description, "parameters": self.parameters } })
    }
}

/// The body of a chat-completions request. With `stream` the answer comes as server-sent events.
/// The `tools` key is left out when there are no tools.
pub fn request_body(
    model: &str,
    messages: &[ChatMessage],
    tools: &[ToolSpec],
    stream: bool,
) -> Value {
    let mut body = json!({
        "model": model,
        "messages": messages.iter().map(ChatMessage::to_json).collect::<Vec<_>>(),
    });
    if stream {
        body["stream"] = json!(true);
    }
    if !tools.is_empty() {
        body["tools"] = tools.iter().map(ToolSpec::to_json).collect();
    }
    body
}

/// One piece of a streamed answer.
#[derive(Debug, Clone, PartialEq)]
pub enum StreamEvent {
    /// More of the reply text.
    Text(String),
    /// More of the model's reasoning, which is shown but never sent back to the model.
    Reasoning(String),
    /// A part of a tool call. Parts of one call share an `index`. Id and name come first.
    ToolCallDelta {
        index: usize,
        id: Option<String>,
        name: Option<String>,
        arguments: String,
    },
    /// The model stopped, with its reason (`stop`, `tool_calls`, `length`).
    Finished(String),
}

/// A whole answer.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct ChatReply {
    pub text: String,
    /// What the model thought before it answered. For showing only: `into_message` drops it and
    /// requests never carry it.
    pub reasoning: String,
    pub tool_calls: Vec<ToolCall>,
    pub finish_reason: Option<String>,
}

impl ChatReply {
    /// The reply as a message to keep in the history.
    pub fn into_message(self) -> ChatMessage {
        ChatMessage {
            tool_calls: self.tool_calls,
            ..ChatMessage::new(Role::Assistant, self.text)
        }
    }
}

/// Builds a [`ChatReply`] from stream events.
#[derive(Debug, Default, Clone)]
pub struct ReplyAccumulator {
    text: String,
    reasoning: String,
    calls: BTreeMap<usize, ToolCall>,
    finish_reason: Option<String>,
}

impl ReplyAccumulator {
    pub fn apply(&mut self, event: &StreamEvent) {
        match event {
            StreamEvent::Text(t) => self.text.push_str(t),
            StreamEvent::Reasoning(t) => self.reasoning.push_str(t),
            StreamEvent::ToolCallDelta {
                index,
                id,
                name,
                arguments,
            } => {
                let call = self.calls.entry(*index).or_default();
                if let Some(id) = id {
                    call.id.clone_from(id);
                }
                if let Some(name) = name {
                    call.name.push_str(name);
                }
                call.arguments.push_str(arguments);
            }
            StreamEvent::Finished(reason) => self.finish_reason = Some(reason.clone()),
        }
    }

    pub fn text(&self) -> &str {
        &self.text
    }

    /// All the reasoning so far, as it arrived.
    pub fn reasoning(&self) -> &str {
        &self.reasoning
    }

    pub fn tool_calls(&self) -> impl Iterator<Item = &ToolCall> {
        self.calls.values()
    }

    /// The reply so far, tidied for the user: text trimmed, calls without a name dropped, a call
    /// without an id named `call_<index>` and one without arguments given `{}`.
    pub fn tidy_reply(&self) -> ChatReply {
        let tool_calls = self
            .calls
            .iter()
            .filter(|(_, c)| !c.name.is_empty())
            .map(|(i, c)| ToolCall {
                id: if c.id.is_empty() {
                    format!("call_{i}")
                } else {
                    c.id.clone()
                },
                name: c.name.clone(),
                arguments: if c.arguments.is_empty() {
                    "{}".to_string()
                } else {
                    c.arguments.clone()
                },
            })
            .collect();
        ChatReply {
            text: self.text.trim().to_string(),
            reasoning: self.reasoning.trim().to_string(),
            tool_calls,
            finish_reason: self.finish_reason.clone(),
        }
    }

    pub fn finish(self) -> ChatReply {
        ChatReply {
            text: self.text,
            reasoning: self.reasoning,
            tool_calls: self.calls.into_values().collect(),
            finish_reason: self.finish_reason,
        }
    }
}

#[derive(Debug, thiserror::Error)]
pub enum ChatError {
    /// The service answered with an error status.
    #[error("the service answered {status}: {message}")]
    Http { status: u16, message: String },
    /// The connection failed or timed out.
    #[error("could not reach the service: {0}")]
    Network(String),
    /// The answer was not what an OpenAI-compatible service sends.
    #[error("unexpected answer: {0}")]
    Protocol(String),
    /// The answer held nothing to use. The text says what was missing, such as `text`.
    #[error("the model returned no {0}")]
    Empty(String),
}

impl Retryable for ChatError {
    fn is_retryable(&self) -> bool {
        match self {
            Self::Http { status, .. } => is_retryable_status(*status),
            Self::Network(_) => true,
            Self::Protocol(_) | Self::Empty(_) => false,
        }
    }
}

/// Splits a byte stream into the `data:` payloads of server-sent events.
#[derive(Debug, Default)]
pub struct SseParser {
    buffer: Vec<u8>,
}

impl SseParser {
    /// Adds bytes and returns the payloads of every line completed so far.
    pub fn feed(&mut self, bytes: &[u8]) -> Vec<String> {
        self.buffer.extend_from_slice(bytes);
        let mut out = Vec::new();
        while let Some(end) = self.buffer.iter().position(|b| *b == b'\n') {
            let line: Vec<u8> = self.buffer.drain(..=end).collect();
            let line = String::from_utf8_lossy(&line);
            let line = line.trim_end_matches(['\n', '\r']);
            if let Some(data) = line.strip_prefix("data:") {
                out.push(data.strip_prefix(' ').unwrap_or(data).to_string());
            }
        }
        out
    }
}

/// A streamed reply read line by line: the lines of server-sent events go in, the text and the
/// tool calls come out. A line that is not a `data:` line, or whose payload is not JSON, is skipped.
#[derive(Debug, Default, Clone)]
pub struct ChatStream {
    reply: ReplyAccumulator,
    reader: StreamReader,
    done: bool,
}

impl ChatStream {
    /// Reads one line. `Ok(true)` when it added text.
    pub fn feed_line(&mut self, line: &str) -> Result<bool, ChatError> {
        let Some(data) = line.trim().strip_prefix("data:") else {
            return Ok(false);
        };
        let payload = data.trim();
        if payload == "[DONE]" {
            self.done = true;
            let mut added = false;
            for event in self.reader.end() {
                added |= matches!(event, StreamEvent::Text(_));
                self.reply.apply(&event);
            }
            return Ok(added);
        }
        if serde_json::from_str::<Value>(payload).is_err() {
            return Ok(false);
        }
        let mut added = false;
        for event in self.reader.chunk(payload)? {
            added |= matches!(event, StreamEvent::Text(_));
            self.reply.apply(&event);
        }
        Ok(added)
    }

    /// Whether the service said it is done (`[DONE]`).
    pub fn is_done(&self) -> bool {
        self.done
    }

    /// All the text so far, as it arrived.
    pub fn text(&self) -> &str {
        self.reply.text()
    }

    /// All the reasoning so far, as it arrived.
    pub fn reasoning(&self) -> &str {
        self.reply.reasoning()
    }

    /// The whole reply so far (see [`ReplyAccumulator::tidy_reply`]).
    pub fn reply(&self) -> ChatReply {
        self.reply.tidy_reply()
    }
}

/// The error a service reports inside a 200 answer, if the JSON holds one.
fn service_error(value: &Value) -> Option<ChatError> {
    let error = value.get("error")?;
    let message = error
        .get("message")
        .and_then(Value::as_str)
        .unwrap_or("the service reported an error");
    let status = error
        .get("code")
        .and_then(Value::as_u64)
        .and_then(|c| u16::try_from(c).ok())
        .unwrap_or(500);
    Some(ChatError::Http {
        status,
        message: message.to_string(),
    })
}

/// The reply in the JSON of a whole (not streamed) answer: the text of the first choice, trimmed,
/// and its tool calls. A call without a name is skipped, one without an id is named `call_<n>` and
/// arguments given as a JSON value instead of text are written out. Some services answer 200 with
/// an error object, which becomes the error. An answer with neither text nor calls is
/// [`ChatError::Empty`].
pub fn parse_reply(body: &str) -> Result<ChatReply, ChatError> {
    let value = match serde_json::from_str::<Value>(body) {
        Ok(v) if v.is_object() => v,
        _ => return Err(ChatError::Empty("JSON".into())),
    };
    if let Some(error) = service_error(&value) {
        return Err(error);
    }
    let message = value.pointer("/choices/0/message");
    let content = match message.and_then(|m| m.get("content")) {
        Some(Value::String(s)) => s.clone(),
        Some(Value::Array(parts)) => parts
            .iter()
            .filter_map(|p| p.get("text").and_then(Value::as_str))
            .collect::<String>(),
        _ => String::new(),
    };
    let (inline, text) = split_think(&content);
    let reasoning = message
        .map(reasoning_of)
        .filter(|r| !r.is_empty())
        .unwrap_or(inline)
        .trim()
        .to_string();
    let text = text.trim().to_string();
    let mut tool_calls = Vec::new();
    for (i, call) in message
        .and_then(|m| m.get("tool_calls"))
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .enumerate()
    {
        let function = &call["function"];
        let Some(name) = function.get("name").and_then(Value::as_str) else {
            continue;
        };
        let arguments = match function.get("arguments") {
            Some(Value::String(s)) if !s.is_empty() => s.clone(),
            Some(v @ (Value::Object(_) | Value::Array(_))) => v.to_string(),
            _ => "{}".to_string(),
        };
        tool_calls.push(ToolCall {
            id: call
                .get("id")
                .and_then(Value::as_str)
                .map_or_else(|| format!("call_{i}"), str::to_string),
            name: name.to_string(),
            arguments,
        });
    }
    if text.is_empty() && tool_calls.is_empty() {
        return Err(ChatError::Empty("text".into()));
    }
    Ok(ChatReply {
        text,
        reasoning,
        tool_calls,
        finish_reason: None,
    })
}

/// The model ids in the answer to `GET /models`, trimmed, sorted and without repeats. Anything that
/// is not a model list gives none.
pub fn parse_model_ids(body: &str) -> Vec<String> {
    let Ok(value) = serde_json::from_str::<Value>(body) else {
        return Vec::new();
    };
    let ids: std::collections::BTreeSet<String> = value
        .get("data")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter_map(|m| m.get("id").and_then(Value::as_str).map(str::trim))
        .filter(|id| !id.is_empty())
        .map(str::to_string)
        .collect();
    ids.into_iter().collect()
}

/// A short message out of the body of an error answer: the service's own message (with the raw
/// reason a gateway passes on), or the start of the body.
pub fn error_message(body: &str) -> String {
    if let Ok(value) = serde_json::from_str::<Value>(body) {
        if let Some(message) = value.pointer("/error/message").and_then(Value::as_str) {
            let raw = value
                .pointer("/error/metadata/raw")
                .and_then(Value::as_str)
                .filter(|r| !r.is_empty());
            return match raw {
                Some(raw) => format!("{message}: {}", raw.chars().take(300).collect::<String>()),
                None => message.to_string(),
            };
        }
        if let Some(message) = value.get("message").and_then(Value::as_str) {
            return message.to_string();
        }
    }
    body.chars().take(300).collect()
}

/// The events in one `chat.completion.chunk` JSON payload.
pub fn parse_chunk(payload: &str) -> Result<Vec<StreamEvent>, ChatError> {
    let value: Value = serde_json::from_str(payload)
        .map_err(|e| ChatError::Protocol(format!("bad chunk: {e}")))?;
    if let Some(error) = service_error(&value) {
        return Err(error);
    }
    let mut events = Vec::new();
    let Some(choice) = value.get("choices").and_then(|c| c.get(0)) else {
        return Ok(events);
    };
    let delta = &choice["delta"];
    let reasoning = reasoning_of(delta);
    if !reasoning.is_empty() {
        events.push(StreamEvent::Reasoning(reasoning));
    }
    if let Some(text) = delta
        .get("content")
        .and_then(Value::as_str)
        .filter(|t| !t.is_empty())
    {
        events.push(StreamEvent::Text(text.to_string()));
    }
    for call in delta
        .get("tool_calls")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
    {
        let function = &call["function"];
        events.push(StreamEvent::ToolCallDelta {
            index: call.get("index").and_then(Value::as_u64).unwrap_or(0) as usize,
            id: call.get("id").and_then(Value::as_str).map(str::to_string),
            name: function
                .get("name")
                .and_then(Value::as_str)
                .map(str::to_string),
            arguments: function
                .get("arguments")
                .and_then(Value::as_str)
                .unwrap_or_default()
                .to_string(),
        });
    }
    if let Some(reason) = choice.get("finish_reason").and_then(Value::as_str) {
        events.push(StreamEvent::Finished(reason.to_string()));
    }
    Ok(events)
}

/// The reasoning in a streamed `delta` or a whole `message`. Services spell it three ways, and some
/// send two at once with the same words, so only the first that has any is read: `reasoning` (a
/// string), else `reasoning_content`, else the `reasoning.text` and `reasoning.summary` entries of
/// `reasoning_details`. Encrypted entries are not text and are ignored.
fn reasoning_of(object: &Value) -> String {
    for key in ["reasoning", "reasoning_content"] {
        if let Some(text) = object
            .get(key)
            .and_then(Value::as_str)
            .filter(|t| !t.is_empty())
        {
            return text.to_string();
        }
    }
    object
        .get("reasoning_details")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter_map(|d| {
            let field = match d.get("type").and_then(Value::as_str)? {
                "reasoning.text" => "text",
                "reasoning.summary" => "summary",
                _ => return None,
            };
            d.get(field)
                .or_else(|| d.get("text"))
                .and_then(Value::as_str)
        })
        .collect()
}

const THINK_OPEN: &str = "<think>";
const THINK_CLOSE: &str = "</think>";

#[derive(Debug, Clone, Default)]
enum ThinkState {
    /// Nothing decided yet: the reply so far is only blanks and maybe the start of `<think>`.
    #[default]
    Start,
    Inside,
    /// After the block: the blanks that follow it are dropped.
    After {
        started: bool,
    },
    /// The reply did not start with a think block.
    Plain,
}

/// Splits `<think>…</think>` out of streamed text. Local models (Ollama, qwen) write their reasoning
/// that way at the start of the reply. Only a block at the very start counts (blanks may come before
/// it). Tags may arrive in pieces, so a possible tag is held back until it is known. A block still
/// open at the end stays reasoning.
#[derive(Debug, Clone, Default)]
pub struct ThinkSplitter {
    state: ThinkState,
    held: String,
}

impl ThinkSplitter {
    /// Takes the next piece of text. Returns the reasoning and the text that can be shown now.
    pub fn push(&mut self, piece: &str) -> Vec<StreamEvent> {
        let mut out = Vec::new();
        self.held.push_str(piece);
        loop {
            match self.state {
                ThinkState::Start => {
                    let trimmed = self.held.trim_start();
                    if let Some(rest) = trimmed.strip_prefix(THINK_OPEN) {
                        self.held = rest.to_string();
                        self.state = ThinkState::Inside;
                    } else if trimmed.is_empty() || THINK_OPEN.starts_with(trimmed) {
                        return out;
                    } else {
                        self.state = ThinkState::Plain;
                    }
                }
                ThinkState::Inside => {
                    if let Some(at) = self.held.find(THINK_CLOSE) {
                        let rest = self.held.split_off(at + THINK_CLOSE.len());
                        self.held.truncate(at);
                        emit(
                            &mut out,
                            StreamEvent::Reasoning(std::mem::take(&mut self.held)),
                        );
                        self.held = rest;
                        self.state = ThinkState::After { started: false };
                    } else {
                        let keep = (1..THINK_CLOSE.len())
                            .rev()
                            .find(|k| self.held.ends_with(&THINK_CLOSE[..*k]))
                            .unwrap_or(0);
                        let kept = self.held.split_off(self.held.len() - keep);
                        emit(
                            &mut out,
                            StreamEvent::Reasoning(std::mem::replace(&mut self.held, kept)),
                        );
                        return out;
                    }
                }
                ThinkState::After { started } => {
                    let text = std::mem::take(&mut self.held);
                    let text = if started { &text } else { text.trim_start() };
                    if !text.is_empty() {
                        self.state = ThinkState::After { started: true };
                        emit(&mut out, StreamEvent::Text(text.to_string()));
                    }
                    return out;
                }
                ThinkState::Plain => {
                    emit(&mut out, StreamEvent::Text(std::mem::take(&mut self.held)));
                    return out;
                }
            }
        }
    }

    /// The reply ended: what was held back comes out, text if no block was open and reasoning if one was.
    pub fn finish(&mut self) -> Vec<StreamEvent> {
        let held = std::mem::take(&mut self.held);
        let mut out = Vec::new();
        match self.state {
            ThinkState::Inside => emit(&mut out, StreamEvent::Reasoning(held)),
            _ => emit(&mut out, StreamEvent::Text(held)),
        }
        self.state = ThinkState::Plain;
        out
    }
}

fn emit(out: &mut Vec<StreamEvent>, event: StreamEvent) {
    let empty = matches!(&event, StreamEvent::Text(t) | StreamEvent::Reasoning(t) if t.is_empty());
    if !empty {
        out.push(event);
    }
}

/// A whole text split into its leading think block and the rest.
fn split_think(text: &str) -> (String, String) {
    let mut splitter = ThinkSplitter::default();
    let (mut reasoning, mut rest) = (String::new(), String::new());
    for event in splitter.push(text).into_iter().chain(splitter.finish()) {
        match event {
            StreamEvent::Reasoning(t) => reasoning.push_str(&t),
            StreamEvent::Text(t) => rest.push_str(&t),
            _ => {}
        }
    }
    (reasoning, rest)
}

/// Reads the chunks of a stream: [`parse_chunk`] plus the `<think>` splitting of the text. Held-back
/// text comes out when something other than text arrives, and at [`end`](Self::end).
#[derive(Debug, Clone, Default)]
pub struct StreamReader {
    think: ThinkSplitter,
}

impl StreamReader {
    pub fn chunk(&mut self, payload: &str) -> Result<Vec<StreamEvent>, ChatError> {
        let mut out = Vec::new();
        for event in parse_chunk(payload)? {
            match event {
                StreamEvent::Text(t) => out.extend(self.think.push(&t)),
                StreamEvent::Reasoning(_) => out.push(event),
                other => {
                    out.extend(self.think.finish());
                    out.push(other);
                }
            }
        }
        Ok(out)
    }

    /// The stream is over: whatever was held back.
    pub fn end(&mut self) -> Vec<StreamEvent> {
        self.think.finish()
    }
}

#[cfg(feature = "io")]
/// A client for one service. `Debug` hides the key.
#[derive(Clone)]
pub struct OpenAiClient {
    base_url: String,
    api_key: Option<String>,
    http: reqwest::Client,
    retry: RetryPolicy,
    headers: std::collections::BTreeMap<String, String>,
    extra_body: serde_json::Map<String, Value>,
}

#[cfg(feature = "io")]
impl std::fmt::Debug for OpenAiClient {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("OpenAiClient")
            .field("base_url", &self.base_url)
            .field("api_key", &self.api_key.as_ref().map(|_| "<hidden>"))
            .field("retry", &self.retry)
            .finish_non_exhaustive()
    }
}

#[cfg(feature = "io")]
impl OpenAiClient {
    /// `base_url` is the service root such as `https://openrouter.ai/api/v1`. The key is sent as a
    /// bearer token and never logged or shown by this type.
    pub fn new(
        base_url: &str,
        api_key: Option<String>,
        retry: RetryPolicy,
    ) -> Result<Self, ChatError> {
        let http = reqwest::Client::builder()
            .connect_timeout(Duration::from_secs(15))
            .read_timeout(Duration::from_secs(120))
            .build()
            .map_err(|e| ChatError::Network(e.to_string()))?;
        Ok(Self {
            base_url: base_url.trim_end_matches('/').to_string(),
            api_key,
            http,
            retry,
            headers: std::collections::BTreeMap::new(),
            extra_body: serde_json::Map::new(),
        })
    }

    /// Adds headers to every request and fields to every request body (a model's variant, an agent's
    /// `request`). The fields never replace `model`, `messages`, `tools` or `stream`.
    #[must_use]
    pub fn with_request(
        mut self,
        headers: std::collections::BTreeMap<String, String>,
        body: serde_json::Map<String, Value>,
    ) -> Self {
        self.headers = headers;
        self.extra_body = body;
        self
    }

    async fn send(&self, body: &Value) -> Result<reqwest::Response, ChatError> {
        let mut request = self
            .http
            .post(format!("{}/chat/completions", self.base_url))
            .json(body);
        if let Some(key) = &self.api_key {
            request = request.bearer_auth(key);
        }
        for (name, value) in &self.headers {
            request = request.header(name, value);
        }
        let response = request
            .send()
            .await
            .map_err(|e| ChatError::Network(e.without_url().to_string()))?;
        let status = response.status();
        if status.is_success() {
            return Ok(response);
        }
        let text = response.text().await.unwrap_or_default();
        Err(ChatError::Http {
            status: status.as_u16(),
            message: error_message(&text),
        })
    }

    /// The models the service lists at `GET /models`, sorted and without repeats (see
    /// [`parse_model_ids`]). A service that answers with something else lists none.
    pub async fn models(&self) -> Result<Vec<String>, ChatError> {
        let mut request = self.http.get(format!("{}/models", self.base_url));
        if let Some(key) = &self.api_key {
            request = request.bearer_auth(key);
        }
        for (name, value) in &self.headers {
            request = request.header(name, value);
        }
        let response = request
            .send()
            .await
            .map_err(|e| ChatError::Network(e.without_url().to_string()))?;
        let status = response.status();
        let text = response
            .text()
            .await
            .map_err(|e| ChatError::Network(e.without_url().to_string()))?;
        if status.is_success() {
            Ok(parse_model_ids(&text))
        } else {
            Err(ChatError::Http {
                status: status.as_u16(),
                message: error_message(&text),
            })
        }
    }

    /// Asks for a reply and streams it. `on_event` hears every piece as it arrives and `on_retry`
    /// hears each retry of the request before its wait. Dropping the future cancels the request.
    pub async fn stream(
        &self,
        model: &str,
        messages: &[ChatMessage],
        tools: &[ToolSpec],
        mut on_event: impl FnMut(&StreamEvent),
        on_retry: impl FnMut(RetryNotice),
    ) -> Result<ChatReply, ChatError> {
        let mut body = request_body(model, messages, tools, true);
        for (key, value) in &self.extra_body {
            if !matches!(key.as_str(), "model" | "messages" | "tools" | "stream") {
                body[key] = value.clone();
            }
        }
        let response = self
            .retry
            .run(|| self.send(&body), || true, on_retry)
            .await?;
        let mut bytes = response.bytes_stream();
        let mut parser = SseParser::default();
        let mut reader = StreamReader::default();
        let mut reply = ReplyAccumulator::default();
        while let Some(chunk) = bytes.next().await {
            let chunk = chunk.map_err(|e| ChatError::Network(e.without_url().to_string()))?;
            for payload in parser.feed(&chunk) {
                let events = if payload.trim() == "[DONE]" {
                    reader.end()
                } else {
                    reader.chunk(&payload)?
                };
                for event in events {
                    reply.apply(&event);
                    on_event(&event);
                }
                if payload.trim() == "[DONE]" {
                    return Ok(reply.finish());
                }
            }
        }
        for event in reader.end() {
            reply.apply(&event);
            on_event(&event);
        }
        Ok(reply.finish())
    }
}

#[cfg(test)]
mod tests {
    #[cfg(feature = "io")]
    #[test]
    fn debug_hides_the_key() {
        let client = OpenAiClient::new(
            "http://localhost:1/v1",
            Some("sk-secret-value".into()),
            RetryPolicy::default(),
        )
        .unwrap();
        let shown = format!("{client:?}");
        assert!(!shown.contains("sk-secret-value"), "{shown}");
        assert!(shown.contains("<hidden>"));
    }

    use super::*;

    #[test]
    fn a_stream_of_lines_makes_a_reply() {
        let mut s = ChatStream::default();
        assert!(!s.feed_line(": keep-alive").unwrap());
        assert!(!s.feed_line("data: not json").unwrap());
        assert!(
            s.feed_line(r#"data: {"choices":[{"delta":{"content":" Hi "}}]}"#)
                .unwrap()
        );
        assert!(!s.feed_line(r#"data: {"choices":[{"delta":{"tool_calls":[{"index":1,"function":{"name":"ec"}}]}}]}"#).unwrap());
        s.feed_line(r#"data: {"choices":[{"delta":{"tool_calls":[{"index":1,"function":{"name":"ho"}}]}}]}"#)
            .unwrap();
        s.feed_line(r#"data: {"choices":[{"delta":{"tool_calls":[{"index":2,"id":"x"}]}}]}"#)
            .unwrap();
        assert!(!s.is_done());
        s.feed_line("data: [DONE]").unwrap();
        assert!(s.is_done());
        assert_eq!(s.text(), " Hi ");
        let reply = s.reply();
        assert_eq!(reply.text, "Hi");
        assert_eq!(
            reply.tool_calls,
            [ToolCall {
                id: "call_1".into(),
                name: "echo".into(),
                arguments: "{}".into()
            }]
        );
        match s.feed_line(r#"data: {"error":{"code":402,"message":"broke"}}"#) {
            Err(ChatError::Http {
                status: 402,
                message,
            }) => assert_eq!(message, "broke"),
            other => panic!("{other:?}"),
        }
    }

    #[test]
    fn sse_lines_split_across_chunks() {
        let mut p = SseParser::default();
        assert!(p.feed(b"data: {\"a\"").is_empty());
        assert_eq!(
            p.feed(b":1}\r\n\r\n: comment\ndata:[DONE]\n"),
            ["{\"a\":1}", "[DONE]"]
        );
    }

    #[test]
    fn chunks_become_events() {
        let events =
            parse_chunk(r#"{"choices":[{"delta":{"content":"Hi"},"finish_reason":null}]}"#)
                .unwrap();
        assert_eq!(events, [StreamEvent::Text("Hi".into())]);
        let events = parse_chunk(
            r#"{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"c1","function":{"name":"f","arguments":"{\"a"}}]},"finish_reason":"tool_calls"}]}"#,
        )
        .unwrap();
        assert_eq!(events.len(), 2);
        assert_eq!(events[1], StreamEvent::Finished("tool_calls".into()));
        assert!(parse_chunk(r#"{"choices":[]}"#).unwrap().is_empty());
        assert!(parse_chunk("not json").is_err());
        assert!(parse_chunk(r#"{"error":{"message":"boom"}}"#).is_err());
    }

    #[test]
    fn accumulator_joins_tool_call_parts() {
        let mut acc = ReplyAccumulator::default();
        let delta =
            |index, id: Option<&str>, name: Option<&str>, args: &str| StreamEvent::ToolCallDelta {
                index,
                id: id.map(str::to_string),
                name: name.map(str::to_string),
                arguments: args.to_string(),
            };
        acc.apply(&StreamEvent::Text("Let me ".into()));
        acc.apply(&delta(0, Some("c1"), Some("look"), "{\"q\":"));
        acc.apply(&delta(1, Some("c2"), Some("other"), "{}"));
        acc.apply(&delta(0, None, None, "\"cat\"}"));
        acc.apply(&StreamEvent::Text("check".into()));
        acc.apply(&StreamEvent::Finished("tool_calls".into()));
        let reply = acc.finish();
        assert_eq!(reply.text, "Let me check");
        assert_eq!(reply.tool_calls.len(), 2);
        assert_eq!(
            reply.tool_calls[0],
            ToolCall {
                id: "c1".into(),
                name: "look".into(),
                arguments: "{\"q\":\"cat\"}".into()
            }
        );
        assert_eq!(reply.finish_reason.as_deref(), Some("tool_calls"));
    }

    #[test]
    fn messages_serialize_the_openai_way() {
        let mut m = ChatMessage::assistant("");
        m.tool_calls.push(ToolCall {
            id: "c1".into(),
            name: "f".into(),
            arguments: "{}".into(),
        });
        let j = m.to_json();
        assert_eq!(j["tool_calls"][0]["function"]["name"], "f");
        let t = ChatMessage::tool_result("c1", "done").to_json();
        assert_eq!(t["role"], "tool");
        assert_eq!(t["tool_call_id"], "c1");
    }

    #[test]
    fn a_tool_call_message_without_text_has_null_content() {
        let mut m = ChatMessage::assistant("");
        m.tool_calls.push(ToolCall {
            id: "c1".into(),
            name: "f".into(),
            arguments: "{}".into(),
        });
        assert!(m.to_json()["content"].is_null());
        assert_eq!(ChatMessage::assistant("hi").to_json()["content"], "hi");
    }

    #[test]
    fn pictures_make_a_multimodal_message() {
        let mut m = ChatMessage::user("look");
        m.images = vec!["data:image/png;base64,AA".into()];
        let j = m.to_json();
        assert_eq!(
            j["content"][0],
            json!({"type": "image_url", "image_url": {"url": "data:image/png;base64,AA"}})
        );
        assert_eq!(j["content"][1], json!({"type": "text", "text": "look"}));
    }

    fn part(url: &str) -> Value {
        let mut m = ChatMessage::user("x");
        m.images = vec![url.into()];
        m.to_json()["content"][0].clone()
    }

    #[test]
    fn audio_becomes_input_audio_with_a_format() {
        for (mime, format) in [
            ("audio/wav", "wav"),
            ("audio/x-wav", "wav"),
            ("audio/wave", "wav"),
            ("audio/mpeg", "mp3"),
            ("audio/mp3", "mp3"),
            ("audio/x-mp3", "mp3"),
            ("audio/ogg", "ogg"),
        ] {
            assert_eq!(
                part(&format!("data:{mime};base64,QUJD")),
                json!({"type": "input_audio", "input_audio": {"data": "QUJD", "format": format}}),
                "{mime}"
            );
        }
        assert_eq!(audio_format("audio/MPEG"), "mp3");
        assert_eq!(audio_format("audio/webm;codecs=opus"), "webm");
    }

    #[test]
    fn data_urls_round_trip_through_the_request() {
        assert_eq!(data_url("audio/wav", b"ABC"), "data:audio/wav;base64,QUJD");
    }

    #[test]
    fn video_other_files_and_odd_urls() {
        let video = "data:video/mp4;base64,QUJD";
        assert_eq!(
            part(video),
            json!({"type": "video_url", "video_url": {"url": video}})
        );
        let pdf = "data:application/pdf;base64,QUJD";
        assert_eq!(
            part(pdf),
            json!({"type": "file", "file": {"file_data": pdf}})
        );
        for odd in [
            "https://x/y.png",
            "data:nonsense",
            "data:;base64,QQ",
            "plain",
        ] {
            assert_eq!(
                part(odd),
                json!({"type": "image_url", "image_url": {"url": odd}}),
                "{odd}"
            );
        }
        assert_eq!(media_kind("image/png"), "image");
        assert_eq!(media_kind("Audio/wav"), "audio");
        assert_eq!(media_kind("video/webm"), "video");
        assert_eq!(media_kind("text/plain"), "file");
        assert_eq!((MAX_MEDIA_BYTES, MAX_ATTACHMENTS), (25 << 20, 4));
    }

    #[test]
    fn the_message_for_tool_pictures_names_the_tools_once() {
        let one = ChatMessage::attachment(vec!["a".into()], &["shot".to_string()]);
        assert_eq!(one.role, Role::User);
        assert!(one.attachment);
        assert_eq!(one.images, ["a"]);
        assert!(
            one.content.starts_with("Screenshot from shot."),
            "{}",
            one.content
        );
        let two = ChatMessage::attachment(
            vec!["a".into(), "b".into()],
            &["shot".to_string(), "look".to_string(), "shot".to_string()],
        );
        assert!(
            two.content.starts_with("Screenshots from shot, look."),
            "{}",
            two.content
        );
    }

    #[test]
    fn request_bodies_list_tools_only_when_there_are_some() {
        let messages = [ChatMessage::user("hi")];
        let plain = request_body("m", &messages, &[], false);
        assert_eq!(plain["model"], "m");
        assert!(plain.get("tools").is_none());
        assert!(plain.get("stream").is_none());
        let tool = ToolSpec {
            name: "f".into(),
            description: "d".into(),
            parameters: json!({"type": "object"}),
        };
        let body = request_body("m", &messages, &[tool], true);
        assert_eq!(body["stream"], true);
        assert_eq!(body["tools"][0]["function"]["name"], "f");
        assert_eq!(body["tools"][0]["type"], "function");
    }

    #[test]
    fn a_whole_reply_is_read_from_its_json() {
        let reply = parse_reply(
            r#"{"choices":[{"message":{"content":"  hi  ","tool_calls":[
                {"id":"a","function":{"name":"f","arguments":"{\"x\":1}"}},
                {"function":{"name":"g","arguments":{"y":2}}},
                {"function":{"name":"h"}},
                {"function":{}}]}}]}"#,
        )
        .unwrap();
        assert_eq!(reply.text, "hi");
        let calls: Vec<_> = reply
            .tool_calls
            .iter()
            .map(|c| (c.id.as_str(), c.name.as_str(), c.arguments.as_str()))
            .collect();
        assert_eq!(
            calls,
            [
                ("a", "f", "{\"x\":1}"),
                ("call_1", "g", "{\"y\":2}"),
                ("call_2", "h", "{}"),
            ]
        );
        let parts = parse_reply(
            r#"{"choices":[{"message":{"content":[{"text":"a"},{"type":"x"},{"text":"b "}]}}]}"#,
        )
        .unwrap();
        assert_eq!(parts.text, "ab");
    }

    #[test]
    fn a_reply_that_says_nothing_or_fails_is_an_error() {
        assert!(matches!(
            parse_reply(r#"{"choices":[{"message":{"content":"  "}}]}"#),
            Err(ChatError::Empty(what)) if what == "text"
        ));
        assert!(matches!(
            parse_reply("[1]"),
            Err(ChatError::Empty(what)) if what == "JSON"
        ));
        assert!(matches!(
            parse_reply("nope"),
            Err(ChatError::Empty(what)) if what == "JSON"
        ));
        match parse_reply(r#"{"error":{"code":402,"message":"broke"}}"#) {
            Err(ChatError::Http {
                status: 402,
                message,
            }) => assert_eq!(message, "broke"),
            other => panic!("{other:?}"),
        }
        match parse_reply(r#"{"error":{}}"#) {
            Err(ChatError::Http {
                status: 500,
                message,
            }) => assert!(!message.contains('\u{2014}')),
            other => panic!("{other:?}"),
        }
        assert_eq!(
            ChatError::Empty("text".into()).to_string(),
            "the model returned no text"
        );
    }

    #[test]
    fn model_ids_are_sorted_and_unique() {
        assert_eq!(
            parse_model_ids(r#"{"data":[{"id":"b"},{"id":"a"},{"id":"b"},{"x":1}]}"#),
            ["a", "b"]
        );
        assert!(parse_model_ids("nope").is_empty());
        assert!(parse_model_ids(r#"{"data":3}"#).is_empty());
        assert_eq!(
            parse_model_ids(r#"{"data":[{"id":" qwen3 "},{"id":" "},{"id":"qwen3"}]}"#),
            ["qwen3"]
        );
    }

    #[test]
    fn error_bodies_become_one_message() {
        assert_eq!(
            error_message(r#"{"error":{"message":"bad key"}}"#),
            "bad key"
        );
        assert_eq!(
            error_message(r#"{"error":{"message":"m","metadata":{"raw":"why"}}}"#),
            "m: why"
        );
        assert_eq!(error_message(r#"{"message":"top"}"#), "top");
        assert_eq!(error_message("plain text"), "plain text");
        assert_eq!(error_message(&"x".repeat(500)).chars().count(), 300);
    }

    #[test]
    fn errors_know_if_they_are_retryable() {
        assert!(
            ChatError::Http {
                status: 503,
                message: String::new()
            }
            .is_retryable()
        );
        assert!(
            ChatError::Http {
                status: 429,
                message: String::new()
            }
            .is_retryable()
        );
        assert!(
            !ChatError::Http {
                status: 401,
                message: String::new()
            }
            .is_retryable()
        );
        assert!(ChatError::Network(String::new()).is_retryable());
        assert!(!ChatError::Protocol(String::new()).is_retryable());
    }

    fn events(payload: &str) -> Vec<StreamEvent> {
        parse_chunk(payload).unwrap()
    }

    fn reasoning(text: &str) -> StreamEvent {
        StreamEvent::Reasoning(text.into())
    }

    fn text(text: &str) -> StreamEvent {
        StreamEvent::Text(text.into())
    }

    #[test]
    fn openrouter_sends_reasoning_once_though_it_is_in_two_places() {
        let chunk = r#"{"choices":[{"delta":{"content":"","role":"assistant","reasoning":" need answer simple","reasoning_details":[{"type":"reasoning.text","text":" need answer simple","format":"unknown","index":0}]}}]}"#;
        assert_eq!(events(chunk), vec![reasoning(" need answer simple")]);
    }

    #[test]
    fn reasoning_content_is_read_when_there_is_no_reasoning() {
        let chunk = r#"{"choices":[{"delta":{"reasoning_content":"hmm"}}]}"#;
        assert_eq!(events(chunk), vec![reasoning("hmm")]);
        let both = r#"{"choices":[{"delta":{"reasoning":"","reasoning_content":"hmm"}}]}"#;
        assert_eq!(events(both), vec![reasoning("hmm")]);
    }

    #[test]
    fn reasoning_details_alone_give_text_and_summaries_but_not_encrypted_data() {
        let chunk = r#"{"choices":[{"delta":{"reasoning_details":[
            {"type":"reasoning.text","text":"a"},
            {"type":"reasoning.summary","summary":"b"},
            {"type":"reasoning.encrypted","data":"SECRET"},
            {"type":"reasoning.text","text":"c"}]}}]}"#;
        assert_eq!(events(chunk), vec![reasoning("abc")]);
        let encrypted = r#"{"choices":[{"delta":{"reasoning_details":[{"type":"reasoning.encrypted","data":"x"}]}}]}"#;
        assert!(events(encrypted).is_empty());
    }

    #[test]
    fn reasoning_comes_before_the_text_of_the_same_chunk() {
        let chunk = r#"{"choices":[{"delta":{"reasoning":"r","content":"c"}}]}"#;
        assert_eq!(events(chunk), vec![reasoning("r"), text("c")]);
    }

    #[test]
    fn a_whole_reply_keeps_its_reasoning() {
        for key in ["reasoning", "reasoning_content"] {
            let body =
                format!(r#"{{"choices":[{{"message":{{"content":" 391 ","{key}":" 17*23 "}}}}]}}"#);
            let reply = parse_reply(&body).unwrap();
            assert_eq!(reply.text, "391");
            assert_eq!(reply.reasoning, "17*23");
        }
        let details = r#"{"choices":[{"message":{"content":"x","reasoning":"same","reasoning_details":[{"type":"reasoning.text","text":"same"}]}}]}"#;
        assert_eq!(parse_reply(details).unwrap().reasoning, "same");
        let inline = r#"{"choices":[{"message":{"content":"<think>why</think>\n\nbecause"}}]}"#;
        let reply = parse_reply(inline).unwrap();
        assert_eq!(
            (reply.reasoning.as_str(), reply.text.as_str()),
            ("why", "because")
        );
    }

    /// Everything the splitter says for these pieces, with the reasoning and the text each joined.
    fn split(pieces: &[&str]) -> (String, String) {
        let mut splitter = ThinkSplitter::default();
        let mut all = Vec::new();
        for piece in pieces {
            all.extend(splitter.push(piece));
        }
        all.extend(splitter.finish());
        let (mut r, mut t) = (String::new(), String::new());
        for event in all {
            match event {
                StreamEvent::Reasoning(x) => r.push_str(&x),
                StreamEvent::Text(x) => t.push_str(&x),
                _ => unreachable!(),
            }
        }
        (r, t)
    }

    #[test]
    fn a_think_block_at_the_start_is_reasoning() {
        assert_eq!(
            split(&["<think>\nadd them\n</think>\n\nIt is 4."]),
            ("\nadd them\n".into(), "It is 4.".into())
        );
        assert_eq!(split(&["  \n<think>x</think>y"]), ("x".into(), "y".into()));
    }

    #[test]
    fn tags_split_across_chunks_still_work() {
        assert_eq!(
            split(&["<thi", "nk>pon", "der</th", "ink>", "\n", "The ", "answer"]),
            ("ponder".into(), "The answer".into())
        );
        let by_char: Vec<String> = "<think>ab</think>cd".chars().map(String::from).collect();
        let pieces: Vec<&str> = by_char.iter().map(String::as_str).collect();
        assert_eq!(split(&pieces), ("ab".into(), "cd".into()));
        // A lookalike inside the block is reasoning, not the end of it.
        assert_eq!(
            split(&["<think>a </thin", "g b</think>z"]),
            ("a </thing b".into(), "z".into())
        );
    }

    #[test]
    fn an_unclosed_block_stays_reasoning() {
        assert_eq!(
            split(&["<think>still ", "going </th"]),
            ("still going </th".into(), String::new())
        );
    }

    #[test]
    fn a_think_block_not_at_the_start_is_text() {
        let said = "Hi <think>no</think> there";
        assert_eq!(split(&[said]), (String::new(), said.into()));
        assert_eq!(
            split(&["Hi ", "<think>no</think>"]),
            (String::new(), "Hi <think>no</think>".into())
        );
    }

    #[test]
    fn a_start_that_only_looks_like_a_tag_comes_out_as_text() {
        assert_eq!(split(&["<thi"]), (String::new(), "<thi".into()));
        assert_eq!(
            split(&["<thi", "s is html"]),
            (String::new(), "<thi".to_string() + "s is html")
        );
        assert_eq!(split(&["  "]), (String::new(), "  ".into()));
    }

    #[test]
    fn a_stream_splits_think_tags_in_content() {
        let mut s = ChatStream::default();
        for piece in ["<thi", "nk>2+2", "</think>", "\n4"] {
            let line = format!(
                "data: {}",
                serde_json::json!({"choices":[{"delta":{"content":piece}}]})
            );
            s.feed_line(&line).unwrap();
        }
        s.feed_line("data: [DONE]").unwrap();
        assert_eq!(s.reasoning(), "2+2");
        assert_eq!(s.text(), "4");
        let reply = s.reply();
        assert_eq!(
            (reply.reasoning.as_str(), reply.text.as_str()),
            ("2+2", "4")
        );
    }

    #[test]
    fn held_back_text_comes_out_before_a_tool_call() {
        let mut reader = StreamReader::default();
        assert!(
            reader
                .chunk(r#"{"choices":[{"delta":{"content":"<thi"}}]}"#)
                .unwrap()
                .is_empty()
        );
        let out = reader
            .chunk(r#"{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"c","function":{"name":"f"}}]}}]}"#)
            .unwrap();
        assert_eq!(out[0], text("<thi"));
        assert!(matches!(out[1], StreamEvent::ToolCallDelta { .. }));
    }

    #[test]
    fn the_accumulator_keeps_reasoning_apart_from_the_text() {
        let mut acc = ReplyAccumulator::default();
        acc.apply(&reasoning(" think "));
        acc.apply(&reasoning("more "));
        acc.apply(&text(" answer "));
        assert_eq!(acc.reasoning(), " think more ");
        assert_eq!(acc.text(), " answer ");
        let tidy = acc.tidy_reply();
        assert_eq!(
            (tidy.reasoning.as_str(), tidy.text.as_str()),
            ("think more", "answer")
        );
        let reply = acc.finish();
        assert_eq!(reply.reasoning, " think more ");
    }

    #[test]
    fn reasoning_is_never_sent_back_to_the_model() {
        let reply = ChatReply {
            text: "391".into(),
            reasoning: "SECRET-THOUGHT".into(),
            ..ChatReply::default()
        };
        let message = reply.into_message();
        let body = request_body("m", &[ChatMessage::user("q"), message], &[], true).to_string();
        assert!(!body.contains("SECRET-THOUGHT"), "{body}");
        assert!(!body.contains("reasoning"), "{body}");
    }
}
