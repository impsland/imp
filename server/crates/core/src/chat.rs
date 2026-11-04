//! An async client for OpenAI-compatible `chat/completions`, with streaming and tool calls.
//!
//! Sending the request is retried by the [`RetryPolicy`]. Once the answer starts streaming it is
//! not retried, because a retry would repeat what was already shown.

use crate::retry::{RetryNotice, RetryPolicy, Retryable, is_retryable_status};
use futures_util::StreamExt;
use serde::Serialize;
use serde_json::{Value, json};
use std::collections::BTreeMap;
use std::time::Duration;

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

#[derive(Debug, Clone, PartialEq)]
pub struct ChatMessage {
    pub role: Role,
    pub content: String,
    pub tool_calls: Vec<ToolCall>,
    /// Set on `Role::Tool` messages: the call this answers.
    pub tool_call_id: Option<String>,
}

impl ChatMessage {
    pub fn new(role: Role, content: impl Into<String>) -> Self {
        Self {
            role,
            content: content.into(),
            tool_calls: Vec::new(),
            tool_call_id: None,
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

    fn to_json(&self) -> Value {
        let mut m = json!({ "role": self.role, "content": self.content });
        if !self.tool_calls.is_empty() {
            m["tool_calls"] = self
                .tool_calls
                .iter()
                .map(|c| json!({ "id": c.id, "type": "function", "function": { "name": c.name, "arguments": c.arguments } }))
                .collect();
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
            role: Role::Assistant,
            content: self.text,
            tool_calls: self.tool_calls,
            tool_call_id: None,
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
}

impl Retryable for ChatError {
    fn is_retryable(&self) -> bool {
        match self {
            Self::Http { status, .. } => is_retryable_status(*status),
            Self::Network(_) => true,
            Self::Protocol(_) => false,
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

/// The events in one `chat.completion.chunk` JSON payload.
pub fn parse_chunk(payload: &str) -> Result<Vec<StreamEvent>, ChatError> {
    let value: Value = serde_json::from_str(payload)
        .map_err(|e| ChatError::Protocol(format!("bad chunk: {e}")))?;
    if let Some(error) = value.get("error") {
        let message = error
            .get("message")
            .and_then(Value::as_str)
            .unwrap_or("the service reported an error");
        return Err(ChatError::Http {
            status: 500,
            message: message.to_string(),
        });
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

/// A client for one service. `Debug` hides the key.
#[derive(Clone)]
pub struct OpenAiClient {
    base_url: String,
    api_key: Option<String>,
    http: reqwest::Client,
    retry: RetryPolicy,
}

impl std::fmt::Debug for OpenAiClient {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("OpenAiClient")
            .field("base_url", &self.base_url)
            .field("api_key", &self.api_key.as_ref().map(|_| "<hidden>"))
            .field("retry", &self.retry)
            .finish_non_exhaustive()
    }
}

impl OpenAiClient {
    /// `base_url` is the service root such as `https://api.openai.com/v1`. The key is sent as a
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

    fn body(model: &str, messages: &[ChatMessage], tools: &[ToolSpec]) -> Value {
        let mut body = json!({
            "model": model,
            "stream": true,
            "messages": messages.iter().map(ChatMessage::to_json).collect::<Vec<_>>(),
        });
        if !tools.is_empty() {
            body["tools"] = tools
                .iter()
                .map(|t| json!({ "type": "function", "function": { "name": t.name, "description": t.description, "parameters": t.parameters } }))
                .collect();
        }
        body
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
            message: text.chars().take(300).collect(),
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
        let body = Self::body(model, messages, tools);
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
