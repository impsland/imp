//! What an Imp remembers of a chat and sends the model, and the recap that stands for the rest.

use imp_engine::memory;

/// A call the model made.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct MemoryCall {
    pub id: String,
    pub name: String,
    pub arguments: String,
}

/// One message of a chat. `role` is `system`, `user`, `assistant` or `tool`.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct MemoryMessage {
    pub role: String,
    pub content: Option<String>,
    pub tool_calls: Vec<MemoryCall>,
    pub tool_call_id: Option<String>,
    pub attachment: bool,
}

/// The messages remembered after the system prompt, and the recap of what came before them.
#[derive(Debug, Clone, Default, PartialEq, Eq, uniffi::Record)]
pub struct MemoryState {
    pub messages: Vec<MemoryMessage>,
    pub recap: Option<String>,
}

/// The sizes and wording the memory goes by.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct MemoryRules {
    pub default_exchanges: u32,
    pub stored_exchanges: u32,
    /// The "Remembers" choices, besides no limit.
    pub choices: Vec<u32>,
    pub tool_result_limit: u32,
    pub transcript_limit: u32,
    /// Turns a chat keeps.
    pub turn_limit: u32,
    pub recap_preface: String,
    pub recap_acknowledgement: String,
}

impl From<MemoryCall> for memory::MemoryCall {
    fn from(c: MemoryCall) -> Self {
        Self {
            id: c.id,
            name: c.name,
            arguments: c.arguments,
        }
    }
}

impl From<memory::MemoryCall> for MemoryCall {
    fn from(c: memory::MemoryCall) -> Self {
        Self {
            id: c.id,
            name: c.name,
            arguments: c.arguments,
        }
    }
}

impl From<MemoryMessage> for memory::MemoryMessage {
    fn from(m: MemoryMessage) -> Self {
        Self {
            role: m.role,
            content: m.content,
            tool_calls: m.tool_calls.into_iter().map(Into::into).collect(),
            tool_call_id: m.tool_call_id,
            attachment: m.attachment,
        }
    }
}

impl From<memory::MemoryMessage> for MemoryMessage {
    fn from(m: memory::MemoryMessage) -> Self {
        Self {
            role: m.role,
            content: m.content,
            tool_calls: m.tool_calls.into_iter().map(Into::into).collect(),
            tool_call_id: m.tool_call_id,
            attachment: m.attachment,
        }
    }
}

fn messages_in(ms: Vec<MemoryMessage>) -> Vec<memory::MemoryMessage> {
    ms.into_iter().map(Into::into).collect()
}

fn messages_out(ms: Vec<memory::MemoryMessage>) -> Vec<MemoryMessage> {
    ms.into_iter().map(Into::into).collect()
}

impl From<MemoryState> for memory::ChatMemory {
    fn from(s: MemoryState) -> Self {
        Self {
            messages: messages_in(s.messages),
            recap: s.recap,
        }
    }
}

impl From<memory::ChatMemory> for MemoryState {
    fn from(m: memory::ChatMemory) -> Self {
        Self {
            messages: messages_out(m.messages),
            recap: m.recap,
        }
    }
}

fn count(n: u32) -> usize {
    n as usize
}

#[uniffi::export]
pub fn memory_rules() -> MemoryRules {
    MemoryRules {
        default_exchanges: memory::DEFAULT_EXCHANGES as u32,
        stored_exchanges: memory::STORED_EXCHANGES as u32,
        choices: memory::CHOICES.iter().map(|c| *c as u32).collect(),
        tool_result_limit: memory::TOOL_RESULT_LIMIT as u32,
        transcript_limit: memory::TRANSCRIPT_LIMIT as u32,
        turn_limit: memory::TURN_LIMIT as u32,
        recap_preface: memory::RECAP_PREFACE.to_string(),
        recap_acknowledgement: memory::RECAP_ACKNOWLEDGEMENT.to_string(),
    }
}

/// Splits messages into exchanges, each starting with a user turn.
#[uniffi::export]
pub fn memory_exchanges(messages: Vec<MemoryMessage>) -> Vec<Vec<MemoryMessage>> {
    memory::exchanges(&messages_in(messages))
        .into_iter()
        .map(messages_out)
        .collect()
}

/// How many exchanges are remembered.
#[uniffi::export]
pub fn memory_exchange_count(memory: MemoryState) -> u32 {
    memory::ChatMemory::from(memory).exchange_count() as u32
}

/// What goes between the system prompt and the new turn: the recap as the opening exchange, then
/// the last `exchanges` exchanges (without tool calls unless `tools`).
#[uniffi::export]
pub fn memory_context(memory: MemoryState, exchanges: u32, tools: bool) -> Vec<MemoryMessage> {
    messages_out(memory::ChatMemory::from(memory).context(count(exchanges), tools))
}

/// The memory with one finished exchange added: pictures dropped, long tool results clipped, the
/// oldest exchanges forgotten past the stored limit.
#[uniffi::export]
pub fn memory_remember(memory: MemoryState, exchange: Vec<MemoryMessage>) -> MemoryState {
    let mut m = memory::ChatMemory::from(memory);
    m.remember(&messages_in(exchange));
    m.into()
}

/// The memory after a recap: `summary` stands for the first `covered` exchanges (all by default)
/// but the last. A blank summary returns the memory as it was.
#[uniffi::export]
pub fn memory_recapped(memory: MemoryState, summary: String, covered: Option<u32>) -> MemoryState {
    let mut m = memory::ChatMemory::from(memory);
    m.recapped(&summary, covered.map(count));
    m.into()
}

/// A rough size of what is sent, in tokens.
#[uniffi::export]
pub fn memory_estimated_tokens(memory: MemoryState, exchanges: u32, tools: bool) -> u32 {
    memory::ChatMemory::from(memory).estimated_tokens(count(exchanges), tools) as u32
}

/// The remembered chat as text for a recap, at most `limit` characters.
#[uniffi::export]
pub fn memory_transcript(memory: MemoryState, tool_limit: u32, limit: u32) -> String {
    memory::ChatMemory::from(memory).transcript(count(tool_limit), count(limit))
}

/// The request that asks the model for a recap of the chat.
#[uniffi::export]
pub fn memory_recap_request(memory: MemoryState, name: String) -> Vec<MemoryMessage> {
    messages_out(memory::ChatMemory::from(memory).recap_request(&name))
}

/// Whether the long-chat notice is due now.
#[uniffi::export]
pub fn memory_notice_due(
    threshold: u32,
    already: bool,
    memory: MemoryState,
    exchanges: u32,
    tools: bool,
) -> bool {
    memory::notice_due(
        count(threshold),
        already,
        &memory.into(),
        count(exchanges),
        tools,
    )
}

/// A name for a chat from the first thing asked.
#[uniffi::export]
pub fn memory_chat_title(request: String, has_picture: bool, sender: Option<String>) -> String {
    memory::chat_title(&request, has_picture, sender.as_deref())
}
