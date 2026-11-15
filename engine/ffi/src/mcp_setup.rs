//! Adding an MCP server from what a person pastes, and reading or writing a command line, for the
//! apps. The rules are in `imp_engine::mcp::setup`.

use imp_engine::mcp::setup;
use std::collections::HashMap;

/// One server found in setup text: a command to start, or an address. `name` is empty when nothing
/// suggested one, so the app shows its own word.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct McpSetupServer {
    pub name: String,
    pub command: String,
    pub args: Vec<String>,
    pub env: HashMap<String, String>,
    pub url: String,
    pub headers: HashMap<String, String>,
}

impl From<setup::SetupServer> for McpSetupServer {
    fn from(s: setup::SetupServer) -> Self {
        Self {
            name: s.name,
            command: s.command,
            args: s.args,
            env: s.env.into_iter().collect(),
            url: s.url,
            headers: s.headers.into_iter().collect(),
        }
    }
}

/// The servers in what a person pasted: a JSON config, a web address or a command line.
#[uniffi::export]
pub fn mcp_parse_setup(text: String) -> Vec<McpSetupServer> {
    setup::parse_setup(&text)
        .into_iter()
        .map(McpSetupServer::from)
        .collect()
}

/// The words of a command line, read as a shell reads them.
#[uniffi::export]
pub fn mcp_split_command_line(line: String) -> Vec<String> {
    setup::split_words(&line).words
}

/// A command and its arguments as one line that `mcp_split_command_line` reads back the same.
#[uniffi::export]
pub fn mcp_join_command_line(command: String, args: Vec<String>) -> String {
    setup::join_words(&command, &args)
}

/// A name for a server from its command's words (its arguments, then the command). Empty if none.
#[uniffi::export]
pub fn mcp_suggested_name_for_command(words: Vec<String>) -> String {
    setup::suggested_name_for_command(&words)
}

/// A name for a server from its address. Empty without a host.
#[uniffi::export]
pub fn mcp_suggested_name_for_url(url: String) -> String {
    setup::suggested_name_for_url(&url)
}
