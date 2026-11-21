//! The Imp Hop: a blind relay that splices two streams, a guest and the host it joins: TCP, or a
//! WebSocket from a browser (`ws`). See PROTOCOL.md.
#![forbid(unsafe_code)]

mod config;
mod handshake;
mod limits;
mod relay;
mod rooms;
mod server;
mod ws;

pub use config::Config;
pub use server::run;
