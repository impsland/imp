//! The configuration the Mac app and the terminal app share (`docs/architecture/configuration.md`).
//!
//! Everything that decides what a file means is a pure function over text and values, checked by the
//! vectors in `spec/fixtures/config/`:
//!
//! - `model`: `provider/model#variant`.
//! - `types`: `imp.json` (and `auth.json`) as typed values, read leniently (`parse_config`) so a
//!   broken entry becomes a `Diagnostic` and not a failed load.
//! - `doc`: agents, skills and commands (Markdown with YAML front matter).
//! - `subst`: `{env:NAME}` and `{file:path}`.
//! - `permissions`: rules, the built-in defaults and which one decides.
//! - `gate`: what a tool call is (action and resource) for those rules.
//!
//! The files themselves are reached with `std::fs`, as the rest of the core does for its own files
//! (the `io` feature is for the network and other processes): `Env` finds the folders, `load`
//! reads and merges them, `trust` remembers which projects the person allowed and `store` writes,
//! atomically and under a lock.

pub mod doc;
pub mod env;
pub mod gate;
pub mod load;
pub mod model;
pub mod permissions;
pub mod resolve;
pub mod store;
pub mod subst;
pub mod trust;
pub mod types;

pub use doc::{Agent, AgentRequest, Command, Mode, Skill, valid_agent_name};
pub use env::Env;
pub use gate::{Permission, classify, judge};
pub use load::{Loaded, Scope, Sourced, load};
pub use model::{ModelRef, ModelRefError};
pub use permissions::{
    Effect, Rule, decide, decide_in, default_rules, effective_rules, glob_match, group_enabled,
    set_group, set_mcp_server, set_rule,
};
pub use resolve::{KeySource, Resolved, resolve, variant_body};
pub use store::{ConfigError, Store, to_json};
pub use subst::{Sources, substitute};
pub use trust::TrustStore;
pub use types::{
    Auth, ImpConfig, ImpExtras, Link, McpOAuth, McpServer, Memory, ModelDef, Provider,
    ProviderAuth, ProviderOptions, Requests, parse_config,
};

use std::path::PathBuf;

/// A problem with one file that did not stop the rest from loading.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Diagnostic {
    pub file: Option<PathBuf>,
    pub message: String,
}

impl Diagnostic {
    pub fn new(file: impl Into<Option<PathBuf>>, message: impl Into<String>) -> Self {
        Self {
            file: file.into(),
            message: message.into(),
        }
    }
}

impl std::fmt::Display for Diagnostic {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match &self.file {
            Some(file) => write!(f, "{}: {}", file.display(), self.message),
            None => f.write_str(&self.message),
        }
    }
}
