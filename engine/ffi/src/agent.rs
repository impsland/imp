//! The agent loop for the apps. The core holds the rules (steps, the final plain answer, how tool
//! results and pictures join the transcript). The app makes the requests and runs the tools.

use crate::chat::{ChatStreamError, ModelMessage, ModelTool, StreamReply, StreamToolCall, specs};
use imp_engine::agent;
use imp_engine::chat::ChatReply;
use std::sync::Mutex;

/// What to do next.
#[derive(Debug, Clone, PartialEq, uniffi::Enum)]
pub enum AgentStep {
    /// Ask the model with these messages and tools, then hand over its answer with `reply`.
    Ask {
        messages: Vec<ModelMessage>,
        tools: Vec<ModelTool>,
    },
    /// The run is over. This is the final text.
    Done { text: String },
}

/// How a tool call ended.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct ToolOutcome {
    /// False when the model reads the text as a failure.
    pub ok: bool,
    /// What the model reads back.
    pub text: String,
}

impl From<agent::ToolDone> for ToolOutcome {
    fn from(done: agent::ToolDone) -> Self {
        Self {
            ok: done.ok,
            text: done.text,
        }
    }
}

#[derive(uniffi::Object)]
pub struct AgentRun(Mutex<agent::AgentRun>);

#[uniffi::export]
impl AgentRun {
    /// A run over the conversation so far with the tools on offer. Without tools there is one step.
    #[uniffi::constructor]
    pub fn new(
        messages: Vec<ModelMessage>,
        tools: Vec<ModelTool>,
        max_steps: u32,
    ) -> Result<Self, ChatStreamError> {
        Ok(Self(Mutex::new(agent::AgentRun::new(
            messages.into_iter().map(Into::into).collect(),
            specs(tools)?,
            max_steps as usize,
        ))))
    }

    /// What to do next.
    pub fn advance(&self) -> AgentStep {
        match self.0.lock().expect("agent lock").advance() {
            agent::AgentNext::Ask { messages, tools } => AgentStep::Ask {
                messages: messages.into_iter().map(Into::into).collect(),
                tools: tools.into_iter().map(Into::into).collect(),
            },
            agent::AgentNext::Done(text) => AgentStep::Done { text },
        }
    }

    /// Takes the model's answer. Returns the tool calls to run, none when the run is over.
    pub fn reply(&self, reply: StreamReply) -> Vec<StreamToolCall> {
        let reply = ChatReply {
            text: reply.text,
            reasoning: reply.reasoning,
            tool_calls: reply.tool_calls.into_iter().map(Into::into).collect(),
            finish_reason: None,
        };
        self.0
            .lock()
            .expect("agent lock")
            .reply(reply)
            .into_iter()
            .map(Into::into)
            .collect()
    }

    /// Takes what a tool returned: its text and the pictures (data URLs) it handed back.
    pub fn tool_result(
        &self,
        call_id: String,
        tool: String,
        text: String,
        images: Vec<String>,
    ) -> ToolOutcome {
        self.0
            .lock()
            .expect("agent lock")
            .tool_result(&call_id, &tool, &text, images)
            .into()
    }

    /// Takes the failure of a tool call. The model reads it as `Error: <message>`.
    pub fn tool_failed(&self, call_id: String, tool: String, message: String) -> ToolOutcome {
        self.0
            .lock()
            .expect("agent lock")
            .tool_failed(&call_id, &tool, &message)
            .into()
    }

    /// The conversation so far, with every turn the run added.
    pub fn messages(&self) -> Vec<ModelMessage> {
        self.0
            .lock()
            .expect("agent lock")
            .messages()
            .iter()
            .cloned()
            .map(Into::into)
            .collect()
    }
}
