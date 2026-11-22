//! The Imp command line app. The binary is called `imp`.
//!
//! - `cli` is the command line grammar and `commands` what each command does.
//! - `settings` is the configuration shared with the Mac app (`imp_engine::config`), `folders` where the data lives,
//!   `gate` the permissions that decide every tool call.
//! - `session` is an Imp ready to chat: its model client, MCP servers and tools.
//! - `project` is what a folder's `AGENTS.md` and `.agents/` add, `mentions` the files picked with `@`.
//! - `chat_state` is the conversation (no input or output in it), `transcript` how tool calls read,
//!   `slash` the `/` commands of a chat, `tui` the full-screen chat.
//! - `troupe` is Imps messaging each other, `link` this computer as one of the person's devices.
//! - `presets` are the services the first run offers (generated from `spec/presets`).
//! - `qr` draws codes and pairs, `serve` runs The Den and The Hop.

pub mod chat_state;
pub mod cli;
pub mod commands;
pub mod custom;
pub mod folders;
pub mod gate;
pub mod grammar;
pub mod link;
pub mod mcp_auth;
pub mod mentions;
#[path = "presets.generated.rs"]
mod presets;
pub mod project;
pub mod qr;
pub mod serve;
pub mod session;
pub mod settings;
pub mod slash;
pub mod strings;
pub mod theme;
pub mod transcript;
pub mod troupe;
pub mod tui;

use std::fmt;

/// An error that is shown to the person as one plain sentence.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CliError(pub String);

impl fmt::Display for CliError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.0)
    }
}

impl std::error::Error for CliError {}

impl From<std::io::Error> for CliError {
    fn from(e: std::io::Error) -> Self {
        Self(e.to_string())
    }
}

impl From<imp_engine::ChatError> for CliError {
    fn from(e: imp_engine::ChatError) -> Self {
        Self(e.to_string())
    }
}

impl From<imp_engine::config::ConfigError> for CliError {
    fn from(e: imp_engine::config::ConfigError) -> Self {
        match e {
            imp_engine::config::ConfigError::NoFolder => {
                Self("There is no data folder to remember this in. Set IMP_DATA_DIR.".into())
            }
            e => Self(e.to_string()),
        }
    }
}

pub type Result<T> = std::result::Result<T, CliError>;
