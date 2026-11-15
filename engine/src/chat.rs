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
    /// Pictures that go with a user message (data URLs), for models that can see.
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
                "{what} from {}. (Attached automatically for you to look at; the user didn't send this.)",
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
            let mut parts = vec![json!({ "type": "text", "text": self.content })];
            parts.extend(
                self.images
                    .iter()
                    .map(|url| json!({ "type": "image_url", "image_url": { "url": url } })),
            );
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
    calls: BTreeMap<usize, ToolCall>,
    finish_reason: Option<String>,
}

impl ReplyAccumulator {
    pub fn apply(&mut self, event: &StreamEvent) {
        match event {
            StreamEvent::Text(t) => self.text.push_str(t),
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
            tool_calls,
            finish_reason: self.finish_reason.clone(),
        }
    }

    pub fn finish(self) -> ChatReply {
        ChatReply {
            text: self.text,
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
            return Ok(false);
        }
        if serde_json::from_str::<Value>(payload).is_err() {
            return Ok(false);
        }
        let mut added = false;
        for event in parse_chunk(payload)? {
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
    let text = match message.and_then(|m| m.get("content")) {
        Some(Value::String(s)) => s.trim().to_string(),
        Some(Value::Array(parts)) => parts
            .iter()
            .filter_map(|p| p.get("text").and_then(Value::as_str))
            .collect::<String>()
            .trim()
            .to_string(),
        _ => String::new(),
    };
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
        tool_calls,
        finish_reason: None,
    })
}

/// The model ids in the JSON of a model list, sorted and without repeats. Anything else is no models.
pub fn parse_model_ids(body: &str) -> Vec<String> {
    let Ok(value) = serde_json::from_str::<Value>(body) else {
        return Vec::new();
    };
    let ids: std::collections::BTreeSet<String> = value
        .get("data")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter_map(|m| m.get("id").and_then(Value::as_str).map(str::to_string))
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

#[cfg(feature = "io")]
/// A client for one service. `Debug` hides the key.
#[derive(Clone)]
pub struct OpenAiClient {
    base_url: String,
    api_key: Option<String>,
    http: reqwest::Client,
    retry: RetryPolicy,
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
        })
    }

    async fn send(&self, body: &Value) -> Result<reqwest::Response, ChatError> {
        let mut request = self
            .http
            .post(format!("{}/chat/completions", self.base_url))
            .json(body);
        if let Some(key) = &self.api_key {
            request = request.bearer_auth(key);
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
        let body = request_body(model, messages, tools, true);
        let response = self
            .retry
            .run(|| self.send(&body), || true, on_retry)
            .await?;
        let mut bytes = response.bytes_stream();
        let mut parser = SseParser::default();
        let mut reply = ReplyAccumulator::default();
        while let Some(chunk) = bytes.next().await {
            let chunk = chunk.map_err(|e| ChatError::Network(e.without_url().to_string()))?;
            for payload in parser.feed(&chunk) {
                if payload.trim() == "[DONE]" {
                    return Ok(reply.finish());
                }
                for event in parse_chunk(&payload)? {
                    reply.apply(&event);
                    on_event(&event);
                }
            }
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
        assert_eq!(j["content"][0], json!({"type": "text", "text": "look"}));
        assert_eq!(
            j["content"][1],
            json!({"type": "image_url", "image_url": {"url": "data:image/png;base64,AA"}})
        );
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
}
