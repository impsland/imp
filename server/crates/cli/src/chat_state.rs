//! The conversation, with no input or output in it, so the line chat and a terminal UI can share it.

use imp_core::{AgentEvent, ChatMessage, ChatReply, ReplyAccumulator, Role, StreamEvent, ToolCall};

#[derive(Debug, Default)]
pub struct ChatState {
    system: Option<String>,
    history: Vec<ChatMessage>,
    pending: Option<ReplyAccumulator>,
}

impl ChatState {
    pub fn new(system: impl Into<String>) -> Self {
        Self {
            system: Some(system.into()),
            ..Self::default()
        }
    }

    /// Adds what the person said. Ignored while a reply is still arriving.
    pub fn push_user(&mut self, text: &str) -> bool {
        if self.pending.is_some() || text.trim().is_empty() {
            return false;
        }
        self.history.push(ChatMessage::user(text.trim()));
        true
    }

    /// Starts a reply. Returns false if one is already arriving.
    pub fn begin_reply(&mut self) -> bool {
        if self.pending.is_some() {
            return false;
        }
        self.pending = Some(ReplyAccumulator::default());
        true
    }

    /// Feeds one streamed piece in. Returns the new text, if the piece had any.
    pub fn apply<'a>(&mut self, event: &'a StreamEvent) -> Option<&'a str> {
        let pending = self.pending.as_mut()?;
        pending.apply(event);
        match event {
            StreamEvent::Text(t) => Some(t),
            _ => None,
        }
    }

    /// Follows one event of the agent loop, so the history ends up as the loop's own messages.
    pub fn apply_agent(&mut self, event: &AgentEvent) {
        match event {
            AgentEvent::StepStart => {
                self.begin_reply();
            }
            AgentEvent::Stream(e) => {
                self.apply(e);
            }
            AgentEvent::StepEnd => {
                self.finish_reply();
            }
            AgentEvent::ToolResult {
                call_id, content, ..
            } => self.push_tool_result(call_id, content),
            AgentEvent::Retry(_) | AgentEvent::ToolStart(_) => {}
        }
    }

    pub fn is_streaming(&self) -> bool {
        self.pending.is_some()
    }

    /// The reply text so far.
    pub fn streaming_text(&self) -> &str {
        self.pending.as_ref().map_or("", ReplyAccumulator::text)
    }

    /// The tool calls collected so far in the reply that is arriving.
    pub fn pending_tool_calls(&self) -> Vec<&ToolCall> {
        self.pending
            .as_ref()
            .map(|p| p.tool_calls().collect())
            .unwrap_or_default()
    }

    /// Ends the reply and keeps it in the history. Returns it.
    pub fn finish_reply(&mut self) -> Option<ChatReply> {
        let reply = self.pending.take()?.finish();
        if !reply.text.is_empty() || !reply.tool_calls.is_empty() {
            self.history.push(reply.clone().into_message());
        }
        Some(reply)
    }

    /// Drops a reply that failed or was cancelled. Text that already arrived is kept, so the
    /// person sees what was said, but tool calls are dropped because they may be cut short.
    pub fn abort_reply(&mut self) {
        if let Some(pending) = self.pending.take() {
            let text = pending.text().to_string();
            if !text.is_empty() {
                self.history.push(ChatMessage::assistant(text));
            }
        }
    }

    /// Adds the answer to a tool call.
    pub fn push_tool_result(&mut self, call_id: &str, content: &str) {
        self.history
            .push(ChatMessage::tool_result(call_id, content));
    }

    /// Everything to send to the model: the system text, then the history.
    pub fn request_messages(&self) -> Vec<ChatMessage> {
        let mut all = Vec::with_capacity(self.history.len() + 1);
        if let Some(system) = &self.system {
            all.push(ChatMessage::system(system.clone()));
        }
        all.extend(self.history.iter().cloned());
        all
    }

    /// What to show: the history without the system text.
    pub fn messages(&self) -> &[ChatMessage] {
        &self.history
    }

    /// Forgets the conversation but keeps the system text.
    pub fn clear(&mut self) {
        self.history.clear();
        self.pending = None;
    }

    /// The last message from the person, for editing or repeating.
    pub fn last_user_text(&self) -> Option<&str> {
        self.history
            .iter()
            .rev()
            .find(|m| m.role == Role::User)
            .map(|m| m.content.as_str())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn call(index: usize, id: Option<&str>, name: Option<&str>, args: &str) -> StreamEvent {
        StreamEvent::ToolCallDelta {
            index,
            id: id.map(Into::into),
            name: name.map(Into::into),
            arguments: args.into(),
        }
    }

    #[test]
    fn user_messages_and_the_request() {
        let mut chat = ChatState::new("You are pip.");
        assert!(!chat.push_user("   "));
        assert!(chat.push_user("  hello "));
        let request = chat.request_messages();
        assert_eq!(request.len(), 2);
        assert_eq!(request[0].role, Role::System);
        assert_eq!(request[1].content, "hello");
        assert_eq!(chat.messages().len(), 1);
        assert_eq!(chat.last_user_text(), Some("hello"));
    }

    #[test]
    fn streaming_deltas_build_one_reply() {
        let mut chat = ChatState::new("s");
        chat.push_user("hi");
        assert!(chat.begin_reply());
        assert!(!chat.begin_reply());
        assert!(!chat.push_user("too soon"));
        assert_eq!(chat.apply(&StreamEvent::Text("Hel".into())), Some("Hel"));
        assert_eq!(chat.apply(&StreamEvent::Text("lo".into())), Some("lo"));
        assert_eq!(chat.apply(&StreamEvent::Finished("stop".into())), None);
        assert_eq!(chat.streaming_text(), "Hello");
        assert!(chat.is_streaming());
        let reply = chat.finish_reply().unwrap();
        assert_eq!(reply.text, "Hello");
        assert!(!chat.is_streaming());
        assert_eq!(chat.messages().last().unwrap().role, Role::Assistant);
        assert_eq!(chat.messages().last().unwrap().content, "Hello");
        assert!(chat.finish_reply().is_none());
    }

    #[test]
    fn tool_calls_accumulate_and_get_results() {
        let mut chat = ChatState::new("s");
        chat.push_user("look");
        chat.begin_reply();
        chat.apply(&call(0, Some("c1"), Some("look"), "{\"q\":"));
        chat.apply(&call(0, None, None, "1}"));
        chat.apply(&call(1, Some("c2"), Some("other"), "{}"));
        let pending = chat.pending_tool_calls();
        assert_eq!(pending.len(), 2);
        assert_eq!(pending[0].arguments, "{\"q\":1}");
        let reply = chat.finish_reply().unwrap();
        assert_eq!(reply.tool_calls.len(), 2);
        assert_eq!(chat.messages().last().unwrap().tool_calls.len(), 2);
        chat.push_tool_result("c1", "found");
        let last = chat.messages().last().unwrap();
        assert_eq!(last.role, Role::Tool);
        assert_eq!(last.tool_call_id.as_deref(), Some("c1"));
    }

    #[test]
    fn agent_events_build_the_same_history() {
        let mut chat = ChatState::new("s");
        chat.push_user("go");
        for e in [
            AgentEvent::StepStart,
            AgentEvent::Stream(call(0, Some("c"), Some("t"), "{}")),
            AgentEvent::StepEnd,
            AgentEvent::ToolResult {
                call_id: "c".into(),
                name: "t".into(),
                content: "done".into(),
            },
            AgentEvent::StepStart,
            AgentEvent::Stream(StreamEvent::Text("Fine".into())),
            AgentEvent::StepEnd,
        ] {
            chat.apply_agent(&e);
        }
        let roles: Vec<Role> = chat.messages().iter().map(|m| m.role).collect();
        assert_eq!(
            roles,
            [Role::User, Role::Assistant, Role::Tool, Role::Assistant]
        );
        assert!(!chat.is_streaming());
    }

    #[test]
    fn abort_keeps_text_and_drops_tool_calls() {
        let mut chat = ChatState::new("s");
        chat.push_user("hi");
        chat.begin_reply();
        chat.apply(&StreamEvent::Text("Half".into()));
        chat.apply(&call(0, Some("c"), Some("f"), "{"));
        chat.abort_reply();
        assert!(!chat.is_streaming());
        let last = chat.messages().last().unwrap();
        assert_eq!(last.content, "Half");
        assert!(last.tool_calls.is_empty());

        chat.push_user("again");
        chat.begin_reply();
        chat.abort_reply();
        assert_eq!(chat.messages().last().unwrap().content, "again");
    }

    #[test]
    fn events_without_a_reply_are_ignored_and_clear_keeps_the_system_text() {
        let mut chat = ChatState::new("keep me");
        assert_eq!(chat.apply(&StreamEvent::Text("x".into())), None);
        chat.push_user("hi");
        chat.clear();
        assert!(chat.messages().is_empty());
        assert_eq!(chat.request_messages().len(), 1);
    }
}
