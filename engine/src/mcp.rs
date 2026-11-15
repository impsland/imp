//! A client for MCP servers (JSON-RPC 2.0), over standard input and output or over Streamable HTTP.
//!
//! `protocol` holds every rule and needs no I/O, so the apps reach it through `imp-ffi` and bring
//! their own transports. With the `io` feature this module also has the transports: a child process
//! (see `client`) and an HTTP client (see `http`). Both only move text and ask `protocol` what it
//! means.

#[cfg(feature = "io")]
mod client;
#[cfg(feature = "io")]
mod http;
pub mod protocol;

#[cfg(feature = "io")]
pub use client::{McpClient, McpEndpoint, McpError, McpHost, McpSecrets, McpServerSpec};
pub use protocol::{McpTool, exposed_name};
