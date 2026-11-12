//! The Imp Hop: a blind relay that splices two TCP streams, a guest and the host it joins. See PROTOCOL.md.
#![forbid(unsafe_code)]

mod config;
mod handshake;
mod limits;
mod relay;
mod rooms;
mod server;

pub use config::Config;
pub use server::run;
