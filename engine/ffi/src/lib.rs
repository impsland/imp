//! The face `imp-engine` shows the apps. Every export here is a thin translation to plain records the
//! bindings understand. The rules themselves stay in `imp-engine`, so the apps never hold a copy.

uniffi::setup_scaffolding!("imp_engine");

mod agent;
mod chat;
mod config;
mod issuance;
mod library;
mod link;
mod link_ui;
mod local_brain;
mod mcp;
mod mcp_auth;
mod mcp_setup;
mod memory;
mod retry;
mod servers;
mod talk;
mod tools;
mod troupe;
mod workspace;

pub use agent::*;
pub use chat::*;
pub use config::*;
pub use link::*;
pub use link_ui::*;
pub use local_brain::*;
pub use mcp::*;
pub use mcp_auth::*;
pub use memory::*;
pub use retry::*;
pub use servers::*;
pub use talk::*;
pub use tools::*;
pub use workspace::*;
