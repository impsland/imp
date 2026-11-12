//! The face `imp-core` shows the apps. Every export here is a thin translation to plain records the
//! bindings understand. The rules themselves stay in `imp-core`, so the apps never hold a copy.

uniffi::setup_scaffolding!("imp_core");

mod agent;
mod chat;
mod link;
mod link_ui;
mod local_brain;
mod mcp;
mod memory;
mod retry;
mod servers;
mod talk;
mod tools;
mod workspace;

pub use agent::*;
pub use chat::*;
pub use link::*;
pub use link_ui::*;
pub use local_brain::*;
pub use mcp::*;
pub use memory::*;
pub use retry::*;
pub use servers::*;
pub use talk::*;
pub use tools::*;
pub use workspace::*;
