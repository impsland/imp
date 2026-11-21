//! The Imp Den: accounts, shared kits, the web gallery and the MCP
//! endpoint. See spec/PROTOCOL.md.
#![forbid(unsafe_code)]

pub mod admin;
pub mod api;
pub mod app;
pub mod config;
mod crypto;
pub mod db;
pub mod den;
pub mod error;
pub mod extract;
mod installs;
pub mod kit;
pub mod mcp;
mod meta;
pub mod oauth_http;
mod redirect;
pub mod serve;
mod web;

pub use app::router;
pub use den::Den;
pub use serve::serve;
