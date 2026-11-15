//! The portable Imp core: the logic every platform shares. The apps call it through `imp-ffi`. The
//! command line app and the servers use it directly. It is checked against the shared vectors in
//! `spec/fixtures`.

pub mod agent;
pub mod chat;
pub mod link;
pub mod local_brain;
pub mod mcp;
pub mod memory;
pub mod retry;
pub mod servers;
pub mod talk;
pub mod tools;
pub mod workspace;

#[cfg(feature = "io")]
pub use agent::run_agent;
pub use agent::{
    AgentError, AgentEvent, AgentNext, AgentRun, BoxFuture, HostTool, ToolDone, ToolHost, Toolbox,
};
#[cfg(feature = "io")]
pub use chat::OpenAiClient;
pub use chat::{
    ChatError, ChatMessage, ChatReply, ChatStream, ReplyAccumulator, Role, StreamEvent, ToolCall,
    ToolSpec,
};
pub use mcp::McpTool;
#[cfg(feature = "io")]
pub use mcp::{McpClient, McpEndpoint, McpHost, McpSecrets, McpServerSpec};
pub use retry::{LimitRange, RequestLimits, RetryNotice, RetryPolicy, Retryable};
pub use talk::{PairLog, TalkStore, Threading};
pub use tools::{ToolEntry, ToolSelection};
