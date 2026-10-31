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

/// Roles, statuses and framing, as in PROTOCOL.md.
pub mod wire {
    pub const MAGIC: &[u8; 6] = b"IMPHOP";
    pub const VERSION: u8 = 2;
    pub const PROOF_PREFIX: &[u8; 9] = b"imp-hop/2";
    pub const HELLO_LEN: usize = 72;
    pub const NONCE_LEN: usize = 32;
    pub const PROOF_LEN: usize = 64;

    pub const HOST: u8 = 0x01;
    pub const GUEST: u8 = 0x02;

    pub const GO: u8 = 0x00;
    pub const REJECTED: u8 = 0x01;
    pub const BUSY: u8 = 0x02;
    pub const NOBODY_CAME: u8 = 0x03;
}
