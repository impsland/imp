//! The Imp Den: accounts and shared kits. See PROTOCOL.md.
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
mod web;

pub use app::router;
pub use den::Den;
