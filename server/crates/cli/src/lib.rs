//! The Imp command line app. The binary is called `imp`.
//!
//! The pieces are split so a terminal UI can reuse them later: `cli` is the command line grammar,
//! `config` the settings file, `keys` where API keys come from, `chat_state` the conversation
//! (no input or output in it) and `commands` what each command does.

pub mod chat_state;
pub mod cli;
pub mod commands;
pub mod config;
pub mod keys;
pub mod qr;
pub mod serve;
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

impl From<imp_core::ChatError> for CliError {
    fn from(e: imp_core::ChatError) -> Self {
        Self(e.to_string())
    }
}

pub type Result<T> = std::result::Result<T, CliError>;
