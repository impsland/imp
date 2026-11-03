//! Portable Imp logic for Rust programs: the command line app, servers and later bindings.
//!
//! The Swift `ImpKit` stays the core of the Mac and iPhone apps. The pieces here follow it and
//! are checked against the same JSON vectors in `Tests/Fixtures`.

pub mod agent;
pub mod chat;
pub mod link;
pub mod mcp;
pub mod retry;
pub mod talk;
pub mod tools;
pub mod workspace;

pub use agent::{AgentError, AgentEvent, BoxFuture, HostTool, ToolHost, Toolbox, run_agent};
pub use chat::{
    ChatError, ChatMessage, ChatReply, OpenAiClient, ReplyAccumulator, Role, StreamEvent, ToolCall,
    ToolSpec,
};
pub use mcp::{McpClient, McpHost, McpServerSpec, McpTool};
pub use retry::{RetryNotice, RetryPolicy, Retryable};
pub use talk::{PairLog, TalkStore, Threading};
pub use tools::{ToolEntry, ToolSelection};
