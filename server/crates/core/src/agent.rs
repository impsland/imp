//! The agent loop: ask the model, run the tools it calls, ask again, up to a step limit.
//!
//! It follows the Swift `Agent`. The loop works on a plain list of messages and tells its caller
//! what happens through [`AgentEvent`], so a terminal screen and a line chat can both show it.
//! Futures here are not `Send`, so run them on the current task (`block_on`, `select!`).

use crate::chat::{ChatError, ChatMessage, OpenAiClient, StreamEvent, ToolCall, ToolSpec};
use crate::retry::RetryNotice;
use crate::tools::{ToolEntry, ToolSelection, refusal};
use std::cell::RefCell;
use std::future::Future;
use std::pin::Pin;
use std::rc::Rc;

pub type BoxFuture<'a, T> = Pin<Box<dyn Future<Output = T> + 'a>>;

/// A tool a host offers: its entry (for switching it off) and what the model sees.
#[derive(Debug, Clone, PartialEq)]
pub struct HostTool {
    pub entry: Option<ToolEntry>,
    pub spec: ToolSpec,
}

/// Something that offers tools and runs them.
pub trait ToolHost {
    fn tools(&self) -> Vec<HostTool>;
    /// Runs the tool `name` with the model's JSON `arguments`. `None` means this host has no such
    /// tool. A failure is returned as text for the model to read.
    fn call<'a>(&'a self, name: &'a str, arguments: &'a str) -> BoxFuture<'a, Option<String>>;
}

/// Several hosts as one. The first that knows a tool name runs it.
#[derive(Default, Clone)]
pub struct Toolbox {
    hosts: Vec<Rc<dyn ToolHost>>,
}

impl Toolbox {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn add(&mut self, host: Rc<dyn ToolHost>) {
        self.hosts.push(host);
    }
}

impl ToolHost for Toolbox {
    fn tools(&self) -> Vec<HostTool> {
        self.hosts.iter().flat_map(|h| h.tools()).collect()
    }

    fn call<'a>(&'a self, name: &'a str, arguments: &'a str) -> BoxFuture<'a, Option<String>> {
        Box::pin(async move {
            for host in &self.hosts {
                if let Some(answer) = host.call(name, arguments).await {
                    return Some(answer);
                }
            }
            None
        })
    }
}

/// What the loop reports. A step is one request to the model.
#[derive(Debug, Clone, PartialEq)]
pub enum AgentEvent {
    StepStart,
    Stream(StreamEvent),
    Retry(RetryNotice),
    /// The model's answer for the step is complete.
    StepEnd,
    ToolStart(ToolCall),
    ToolResult {
        call_id: String,
        name: String,
        content: String,
    },
}

#[derive(Debug, thiserror::Error)]
pub enum AgentError {
    #[error("{0}")]
    Chat(#[from] ChatError),
    #[error("stopped after {0} steps, because the tools kept being called")]
    StepLimit(usize),
}

/// Runs the loop. New assistant and tool messages are added to `messages`. Returns the text of the
/// final answer. Calls to tools that are switched off or unknown are answered with a refusal.
pub async fn run_agent(
    client: &OpenAiClient,
    model: &str,
    messages: &mut Vec<ChatMessage>,
    host: &dyn ToolHost,
    selection: &ToolSelection,
    max_steps: usize,
    on_event: impl FnMut(AgentEvent),
) -> Result<String, AgentError> {
    let all = host.tools();
    let offered: Vec<ToolSpec> = selection
        .filter(&all, |t| t.entry.as_ref())
        .into_iter()
        .map(|t| t.spec.clone())
        .collect();
    let on_event = RefCell::new(on_event);
    let emit = |e: AgentEvent| (on_event.borrow_mut())(e);
    let steps = max_steps.max(1);
    for _ in 0..steps {
        emit(AgentEvent::StepStart);
        let reply = client
            .stream(
                model,
                messages,
                &offered,
                |e| emit(AgentEvent::Stream(e.clone())),
                |n| emit(AgentEvent::Retry(n)),
            )
            .await?;
        emit(AgentEvent::StepEnd);
        let text = reply.text.clone();
        let calls = reply.tool_calls.clone();
        if !text.is_empty() || !calls.is_empty() {
            messages.push(reply.into_message());
        }
        if calls.is_empty() {
            return Ok(text);
        }
        for call in calls {
            emit(AgentEvent::ToolStart(call.clone()));
            let content = if offered.iter().any(|s| s.name == call.name) {
                host.call(&call.name, &call.arguments).await
            } else {
                None
            }
            .unwrap_or_else(|| refusal(&call.name));
            emit(AgentEvent::ToolResult {
                call_id: call.id.clone(),
                name: call.name.clone(),
                content: content.clone(),
            });
            messages.push(ChatMessage::tool_result(call.id, content));
        }
    }
    Err(AgentError::StepLimit(steps))
}
