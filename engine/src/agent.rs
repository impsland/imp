//! The agent loop: ask the model, run the tools it calls, ask again, up to a step limit.
//!
//! [`AgentRun`] holds every rule of the loop and does no I/O, so the apps (which do their own
//! requests and run their own tools) and the command line app drive the same machine. A driver asks
//! it what to do next, does it, and reports back. [`run_agent`] is that driver for the command line
//! app. Futures there are not `Send`, so run them on the current task (`block_on`, `select!`).

#[cfg(feature = "io")]
use crate::chat::OpenAiClient;
use crate::chat::{ChatError, ChatMessage, ChatReply, StreamEvent, ToolCall, ToolSpec};
use crate::retry::RetryNotice;
use crate::tools::ToolEntry;
#[cfg(feature = "io")]
use crate::tools::{ToolSelection, refusal};
#[cfg(feature = "io")]
use std::cell::RefCell;
use std::future::Future;
use std::pin::Pin;
use std::rc::Rc;

/// What the machine wants next.
#[derive(Debug, Clone, PartialEq)]
pub enum AgentNext {
    /// Ask the model with these messages and tools. Report its answer with [`AgentRun::reply`].
    Ask {
        messages: Vec<ChatMessage>,
        tools: Vec<ToolSpec>,
    },
    /// The run is over. This is the final text.
    Done(String),
}

/// How a tool call ended: whether it worked, and the text the model reads back.
#[derive(Debug, Clone, PartialEq)]
pub struct ToolDone {
    pub ok: bool,
    pub text: String,
}

#[derive(Debug, Clone, PartialEq)]
enum Phase {
    /// Ready to ask the model for a step.
    Ready,
    /// Waiting for the answer to a step.
    Asked,
    /// Waiting for the answer to the last, plain request.
    AskedFinal,
    /// Running the tools the model called.
    Running,
    Finished(String),
}

/// The agent loop without I/O. Create it with the transcript so far and the tools on offer, then:
/// `advance()` says to ask the model, `reply()` hands over its answer and returns the calls to run,
/// `tool_result()` or `tool_failed()` hands over each result, and `advance()` again, until it says
/// done. Without tools there is one step. When the steps run out while the model still calls tools,
/// it is asked once more for a plain answer with no tools.
#[derive(Debug, Clone)]
pub struct AgentRun {
    messages: Vec<ChatMessage>,
    tools: Vec<ToolSpec>,
    steps_left: usize,
    phase: Phase,
    pictures: Vec<String>,
    picture_tools: Vec<String>,
}

impl AgentRun {
    pub fn new(messages: Vec<ChatMessage>, tools: Vec<ToolSpec>, max_steps: usize) -> Self {
        Self {
            steps_left: if tools.is_empty() { 1 } else { max_steps },
            messages,
            tools,
            phase: Phase::Ready,
            pictures: Vec::new(),
            picture_tools: Vec::new(),
        }
    }

    /// The transcript so far: the messages given plus every turn the run added.
    pub fn messages(&self) -> &[ChatMessage] {
        &self.messages
    }

    pub fn advance(&mut self) -> AgentNext {
        if let Phase::Finished(text) = &self.phase {
            return AgentNext::Done(text.clone());
        }
        if !self.pictures.is_empty() {
            // Tool messages can't carry pictures across providers: they follow as one user message.
            let images = std::mem::take(&mut self.pictures);
            let names = std::mem::take(&mut self.picture_tools);
            self.messages.push(ChatMessage::attachment(images, &names));
        }
        let tools = if self.steps_left > 0 {
            if matches!(self.phase, Phase::Ready | Phase::Running) {
                self.steps_left -= 1;
            }
            self.phase = Phase::Asked;
            self.tools.clone()
        } else {
            self.phase = Phase::AskedFinal;
            Vec::new()
        };
        AgentNext::Ask {
            messages: self.messages.clone(),
            tools,
        }
    }

    /// Takes the model's answer. Returns the tool calls to run, none when the run is over (then
    /// `advance()` gives the final text).
    pub fn reply(&mut self, reply: ChatReply) -> Vec<ToolCall> {
        let final_step = match self.phase {
            Phase::Asked => false,
            Phase::AskedFinal => true,
            _ => return Vec::new(),
        };
        if final_step || reply.tool_calls.is_empty() || self.tools.is_empty() {
            self.messages
                .push(ChatMessage::assistant(reply.text.clone()));
            self.phase = Phase::Finished(reply.text);
            return Vec::new();
        }
        let calls = reply.tool_calls.clone();
        self.messages.push(reply.into_message());
        self.phase = Phase::Running;
        calls
    }

    /// Takes what a tool returned: its text and the pictures (data URLs) it handed back.
    pub fn tool_result(
        &mut self,
        call_id: &str,
        tool: &str,
        text: &str,
        images: Vec<String>,
    ) -> ToolDone {
        self.messages.push(ChatMessage::tool_result(call_id, text));
        if !images.is_empty() {
            self.picture_tools.push(tool.to_string());
            self.pictures.extend(images);
        }
        ToolDone {
            ok: !text.starts_with("Error:"),
            text: text.to_string(),
        }
    }

    /// Takes a failure of a tool call: the model reads it as `Error: <message>`.
    pub fn tool_failed(&mut self, call_id: &str, tool: &str, message: &str) -> ToolDone {
        self.tool_result(call_id, tool, &format!("Error: {message}"), Vec::new())
    }
}

/// A boxed future that is not `Send`, so the agent loop can run on the current task.
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

/// Why an agent run stopped early. A failed tool call is not one of these: it goes back to the model as
/// text.
#[derive(Debug, thiserror::Error)]
pub enum AgentError {
    #[error("{0}")]
    Chat(#[from] ChatError),
}

/// Runs the loop with `client` and `host`. New assistant and tool messages are added to
/// `messages`. Returns the text of the final answer. Calls to tools that are switched off or
/// unknown are answered with a refusal.
#[cfg(feature = "io")]
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
    let mut run = AgentRun::new(std::mem::take(messages), offered.clone(), max_steps);
    let outcome = loop {
        let (request, tools) = match run.advance() {
            AgentNext::Done(text) => break Ok(text),
            AgentNext::Ask { messages, tools } => (messages, tools),
        };
        emit(AgentEvent::StepStart);
        let reply = client
            .stream(
                model,
                &request,
                &tools,
                |e| emit(AgentEvent::Stream(e.clone())),
                |n| emit(AgentEvent::Retry(n)),
            )
            .await;
        let reply = match reply {
            Ok(reply) => reply,
            Err(error) => break Err(AgentError::from(error)),
        };
        emit(AgentEvent::StepEnd);
        for call in run.reply(reply) {
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
            run.tool_result(&call.id, &call.name, &content, Vec::new());
        }
    };
    *messages = run.messages;
    outcome
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::chat::{ChatReply, Role};
    use serde_json::json;

    fn tool(name: &str) -> ToolSpec {
        ToolSpec {
            name: name.into(),
            description: String::new(),
            parameters: json!({"type": "object"}),
        }
    }

    fn call(id: &str, name: &str) -> ToolCall {
        ToolCall {
            id: id.into(),
            name: name.into(),
            arguments: "{}".into(),
        }
    }

    fn says(text: &str) -> ChatReply {
        ChatReply {
            text: text.into(),
            ..ChatReply::default()
        }
    }

    fn calls(list: Vec<ToolCall>) -> ChatReply {
        ChatReply {
            tool_calls: list,
            ..ChatReply::default()
        }
    }

    fn ask(run: &mut AgentRun) -> (Vec<ChatMessage>, Vec<ToolSpec>) {
        match run.advance() {
            AgentNext::Ask { messages, tools } => (messages, tools),
            AgentNext::Done(text) => panic!("done: {text}"),
        }
    }

    #[test]
    fn an_answer_without_calls_ends_the_run() {
        let mut run = AgentRun::new(vec![ChatMessage::user("hi")], vec![tool("f")], 3);
        let (messages, tools) = ask(&mut run);
        assert_eq!((messages.len(), tools.len()), (1, 1));
        assert!(run.reply(says("hello")).is_empty());
        assert_eq!(run.advance(), AgentNext::Done("hello".into()));
        assert_eq!(run.messages().last().unwrap().role, Role::Assistant);
        assert_eq!(run.messages().last().unwrap().content, "hello");
    }

    #[test]
    fn without_tools_there_is_one_step_and_calls_are_ignored() {
        let mut run = AgentRun::new(vec![ChatMessage::user("hi")], Vec::new(), 16);
        ask(&mut run);
        let mut reply = says("plain");
        reply.tool_calls = vec![call("c", "f")];
        assert!(run.reply(reply).is_empty());
        assert_eq!(run.advance(), AgentNext::Done("plain".into()));
    }

    #[test]
    fn tool_results_follow_the_assistant_turn_and_the_model_is_asked_again() {
        let mut run = AgentRun::new(vec![ChatMessage::user("go")], vec![tool("f")], 3);
        ask(&mut run);
        let todo = run.reply(calls(vec![call("c1", "f"), call("c2", "f")]));
        assert_eq!(todo.len(), 2);
        assert!(run.tool_result("c1", "f", "one", Vec::new()).ok);
        assert!(run.tool_result("c2", "f", "two", Vec::new()).ok);
        let (messages, tools) = ask(&mut run);
        assert_eq!(tools.len(), 1);
        let roles: Vec<Role> = messages.iter().map(|m| m.role).collect();
        assert_eq!(roles, [Role::User, Role::Assistant, Role::Tool, Role::Tool]);
        assert!(messages[1].content.is_empty());
        assert_eq!(messages[1].tool_calls.len(), 2);
        assert_eq!(messages[2].tool_call_id.as_deref(), Some("c1"));
        assert_eq!(messages[3].content, "two");
    }

    #[test]
    fn an_error_text_is_not_ok() {
        let mut run = AgentRun::new(vec![ChatMessage::user("go")], vec![tool("f")], 3);
        ask(&mut run);
        run.reply(calls(vec![call("c1", "f"), call("c2", "f")]));
        let bad = run.tool_result("c1", "f", "Error: no", Vec::new());
        assert!(!bad.ok);
        let failed = run.tool_failed("c2", "f", "it broke");
        assert!(!failed.ok);
        assert_eq!(failed.text, "Error: it broke");
        let (messages, _) = ask(&mut run);
        assert_eq!(messages.last().unwrap().content, "Error: it broke");
    }

    #[test]
    fn pictures_come_as_one_user_message_after_the_tool_messages() {
        let mut run = AgentRun::new(vec![ChatMessage::user("go")], vec![tool("shot")], 3);
        ask(&mut run);
        run.reply(calls(vec![call("c1", "shot"), call("c2", "shot")]));
        run.tool_result("c1", "shot", "ok", vec!["data:a".into()]);
        run.tool_result("c2", "shot", "ok", vec!["data:b".into()]);
        let (messages, _) = ask(&mut run);
        let last = messages.last().unwrap();
        assert_eq!(last.role, Role::User);
        assert!(last.attachment);
        assert_eq!(last.images, ["data:a", "data:b"]);
        assert!(last.content.starts_with("Screenshots from shot."));
        assert_eq!(messages[messages.len() - 2].role, Role::Tool);
    }

    #[test]
    fn out_of_steps_forces_a_plain_answer() {
        let mut run = AgentRun::new(vec![ChatMessage::user("go")], vec![tool("f")], 2);
        for i in 0..2 {
            let (_, tools) = ask(&mut run);
            assert_eq!(tools.len(), 1);
            run.reply(calls(vec![call(&format!("c{i}"), "f")]));
            run.tool_result(&format!("c{i}"), "f", "r", Vec::new());
        }
        let (messages, tools) = ask(&mut run);
        assert!(tools.is_empty());
        assert_eq!(messages.len(), 5);
        let mut stubborn = says("sorry");
        stubborn.tool_calls = vec![call("again", "f")];
        assert!(run.reply(stubborn).is_empty());
        assert_eq!(run.advance(), AgentNext::Done("sorry".into()));
        assert_eq!(run.messages().last().unwrap().content, "sorry");
    }
}
