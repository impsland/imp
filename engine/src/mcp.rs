//! A client for MCP servers (JSON-RPC 2.0), over standard input and output or over Streamable HTTP.
//!
//! `protocol` holds every rule and needs no I/O, so the apps reach it through `imp-ffi` and bring
//! their own transports. With the `io` feature this module also has the transports: a child process
//! (see `client`) and an HTTP client (see `http`). Both only move text and ask `protocol` what it
//! means. `setup` reads what a person pastes to add a server, and MCP config files.

pub mod auth;
#[cfg(feature = "io")]
pub mod auth_flow;
#[cfg(feature = "io")]
mod client;
#[cfg(feature = "io")]
mod http;
pub mod protocol;
pub mod setup;

#[cfg(feature = "io")]
pub use client::{McpClient, McpEndpoint, McpError, McpHost, McpSecrets, McpServerSpec, McpSignIn};
pub use protocol::{McpTool, exposed_name};
