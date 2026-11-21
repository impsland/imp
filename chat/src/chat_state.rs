//! The conversation, with no input or output in it, so the line chat and a terminal UI can share it.
//!
//! It keeps two things, as the apps do: the whole chat as it shows (`messages`), and what the model is
//! sent, which is the core's chat memory (`imp_engine::memory`): the last exchanges (all by default),
//! long tool results clipped, and a recap in place of what came before once the chat was summed up
//! with `/compact`. An exchange (a message and every tool call and reply it led to) is remembered
//! when it is answered. Until then, and for callers that never finish one, what is not remembered yet
//! is sent as it is.

use imp_engine::memory::{self, ChatMemory, MemoryMessage};
use imp_engine::{
    AgentEvent, ChatMessage, ChatReply, ReplyAccumulator, Role, StreamEvent, ToolCall,
};

#[derive(Debug)]
pub struct ChatState {
    system: Option<String>,
    history: Vec<ChatMessage>,
    pending: Option<ReplyAccumulator>,
    /// What the model remembers of the chat, and the first message of `history` not in it yet.
    memory: ChatMemory,
    unremembered: usize,
    /// How many of the remembered exchanges are sent with each message.
    exchanges: usize,
    /// The long-chat notice was given for this chat.
    noticed: bool,
}

impl Default for ChatState {
    fn default() -> Self {
        Self {
            system: None,
            history: Vec::new(),
            pending: None,
            memory: ChatMemory::default(),
            unremembered: 0,
            exchanges: usize::MAX,
            noticed: false,
        }
    }
}

fn remembered(messages: &[ChatMessage]) -> Vec<MemoryMessage> {
    messages.iter().map(MemoryMessage::from).collect()
}

impl ChatState {
    pub fn new(system: impl Into<String>) -> Self {
        Self {
            system: Some(system.into()),
            ..Self::default()
        }
    }

    /// A conversation that goes on from `messages` (without a system text of their own). They are
    /// remembered as they are, as if each exchange had been answered here.
    pub fn from_messages(system: impl Into<String>, messages: Vec<ChatMessage>) -> Self {
        let history: Vec<ChatMessage> = messages
            .into_iter()
            .filter(|m| m.role != Role::System)
            .collect();
        let mut memory = ChatMemory::default();
        memory.remember(&remembered(&history));
        Self {
            system: Some(system.into()),
            unremembered: history.len(),
            history,
            memory,
            ..Self::default()
        }
    }

    /// Sends only the last `exchanges` remembered exchanges with each message. 0: all of them.
    pub fn set_exchanges(&mut self, exchanges: usize) {
        self.exchanges = if exchanges == 0 {
            usize::MAX
        } else {
            exchanges
        };
    }

    /// What the model remembers of the chat.
    pub fn memory(&self) -> &ChatMemory {
        &self.memory
    }

    /// The exchange that was asked is over. Answered, it is remembered (long tool results clipped).
    /// Not answered (it failed or was stopped), the model is not sent it again, though it still shows.
    pub fn finish_exchange(&mut self, answered: bool) {
        let from = self.unremembered.min(self.history.len());
        if answered {
            self.memory.remember(&remembered(&self.history[from..]));
        }
        self.unremembered = self.history.len();
    }

    /// The chat was summed up: `summary` stands for everything before the last exchange, which is
    /// still sent as it is. A blank summary changes nothing. True when it took.
    pub fn recapped(&mut self, summary: &str) -> bool {
        self.memory.recapped(summary, None)
    }

    /// The long-chat notice, the first time what is sent reaches `threshold` tokens (0: never). Returns
    /// about how many tokens are sent now.
    pub fn long_chat_notice(&mut self, threshold: usize) -> Option<usize> {
        let due = memory::notice_due(threshold, self.noticed, &self.memory, self.exchanges, true);
        if !due {
            return None;
        }
        self.noticed = true;
        Some(self.memory.estimated_tokens(self.exchanges, true))
    }

    /// Replaces the system text, keeping the conversation. For a model or personality that changed.
    pub fn set_system(&mut self, system: impl Into<String>) {
        self.system = Some(system.into());
    }

    /// Adds what the person said. Ignored while a reply is still arriving.
    pub fn push_user(&mut self, text: &str) -> bool {
        if self.pending.is_some() || text.trim().is_empty() {
            return false;
        }
        self.history.push(ChatMessage::user(text.trim()));
        true
    }

    /// Adds what the person said with media that goes along (data URLs: pictures, sound, video).
    pub fn push_user_with(&mut self, text: &str, media: Vec<String>) -> bool {
        if !self.push_user(text) {
            return false;
        }
        self.attach_media(media);
        true
    }

    /// Puts media (data URLs) on the person's last message, which the model sees along with its text.
    pub fn attach_media(&mut self, media: Vec<String>) {
        if media.is_empty() {
            return;
        }
        if let Some(m) = self.history.iter_mut().rev().find(|m| m.role == Role::User) {
            m.images = media;
        }
    }

    /// Replaces the text of the person's last message, as when the files it names are put in.
    pub fn amend_last_user(&mut self, content: String) {
        if let Some(m) = self.history.iter_mut().rev().find(|m| m.role == Role::User) {
            m.content = content;
        }
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

    /// What to send to the model: the system text, what it remembers (the recap and the last
    /// exchanges), then what is not remembered yet (the message being answered).
    pub fn request_messages(&self) -> Vec<ChatMessage> {
        self.request(self.system.as_deref())
    }

    /// The same with `system` as the system text.
    pub fn request_messages_with(&self, system: &str) -> Vec<ChatMessage> {
        self.request(Some(system))
    }

    fn request(&self, system: Option<&str>) -> Vec<ChatMessage> {
        let mut all: Vec<ChatMessage> = system.map(ChatMessage::system).into_iter().collect();
        all.extend(
            self.memory
                .context(self.exchanges, true)
                .iter()
                .map(ChatMessage::from),
        );
        let from = self.unremembered.min(self.history.len());
        all.extend(self.history[from..].iter().cloned());
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
        self.memory = ChatMemory::default();
        self.unremembered = 0;
        self.noticed = false;
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

    fn answered(chat: &mut ChatState, ask: &str, reply: &str) {
        chat.push_user(ask);
        chat.begin_reply();
        chat.apply(&StreamEvent::Text(reply.into()));
        chat.finish_reply();
        chat.finish_exchange(true);
    }

    #[test]
    fn the_model_is_sent_what_it_remembers_and_the_chat_shows_everything() {
        let mut chat = ChatState::new("sys");
        answered(&mut chat, "one", "1");
        // A tool result is clipped when it is remembered, but shows whole.
        chat.push_user("read");
        chat.history
            .push(ChatMessage::tool_result("c", "x".repeat(20_000)));
        chat.finish_exchange(true);
        answered(&mut chat, "three", "3");
        let sent = chat.request_messages();
        assert_eq!(sent[0].role, Role::System);
        assert!(sent.iter().any(|m| m.content.contains("clipped")));
        assert_eq!(chat.messages()[3].content.len(), 20_000);
        // A failed exchange shows but is not sent again.
        chat.push_user("fails");
        assert_eq!(chat.request_messages().last().unwrap().content, "fails");
        chat.finish_exchange(false);
        assert!(!chat.request_messages().iter().any(|m| m.content == "fails"));
        assert!(chat.messages().iter().any(|m| m.content == "fails"));
        // Only the last exchanges, when set.
        chat.set_exchanges(1);
        let sent = chat.request_messages();
        assert_eq!(sent.len(), 3, "{sent:?}");
        assert_eq!(sent[1].content, "three");
        // A recap stands for what came before the last exchange.
        chat.set_exchanges(0);
        assert!(chat.recapped("They counted to three."));
        let sent = chat.request_messages();
        assert!(sent[1].content.contains("They counted to three."));
        assert!(!sent.iter().any(|m| m.content == "one"));
        assert!(sent.iter().any(|m| m.content == "three"));
        assert_eq!(chat.messages().len(), 7, "the chat still shows it all");
        chat.clear();
        assert_eq!(chat.request_messages().len(), 1);
    }

    #[test]
    fn the_long_chat_notice_comes_once() {
        let mut chat = ChatState::new("s");
        assert_eq!(chat.long_chat_notice(10), None, "an empty chat");
        answered(&mut chat, &"word ".repeat(40), "ok");
        assert_eq!(chat.long_chat_notice(0), None, "off");
        assert_eq!(chat.long_chat_notice(1_000), None, "not yet");
        assert!(chat.long_chat_notice(10).unwrap() >= 10);
        assert_eq!(chat.long_chat_notice(10), None, "once");
        let from = ChatState::from_messages(
            "s",
            vec![ChatMessage::user("a"), ChatMessage::assistant("b")],
        );
        assert_eq!(from.memory().messages.len(), 2);
        assert_eq!(from.request_messages().len(), 3);
    }

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
