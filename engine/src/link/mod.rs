//! Imp Link: how devices find each other, pair and talk (`docs/connecting/link.md`).
//!
//! Everything here is sans-IO: it takes bytes in and gives bytes and events out. There are no sockets, no
//! clocks of its own beyond a `Clock` the node is given, and no async runtime, so it builds without the
//! `io` feature and the apps call it through `imp-ffi`. The adapters (the system's TCP, Bonjour and secure
//! storage) only move bytes and keep the book.

pub mod access;
pub mod book;
pub mod card;
pub mod crypto;
pub mod doors;
pub mod files;
pub mod frames;
pub mod hop;
pub mod identity;
pub mod invite;
pub mod lanes;
pub mod ledger;
pub mod map;
pub mod messages;
pub mod node;
pub mod noise;
pub mod shake;
pub mod talks;
pub mod toss;
pub mod transfers;
pub mod uploads;
pub mod visits;

pub use card::{LinkCard, LinkDevice, LinkKind, LinkRoutes};
pub use frames::{FrameError, FrameReader, MAX_FRAME, encode_frame};
pub use hop::HopAddress;
pub use identity::Identity;
pub use invite::LinkInvite;
pub use messages::*;

/// Bonjour service type devices advertise.
pub const SERVICE_TYPE: &str = "_imp-link._tcp";
/// A device listens here when it can, so another can reach it by address (another network, a VPN).
pub const PORT: u16 = 47_824;
/// Each side pings this often (seconds).
pub const PING_INTERVAL: f64 = 20.0;
/// A connection that has not heard a thing for this long (seconds) is dead: both sides close it.
pub const SILENCE_LIMIT: f64 = 45.0;
/// A visitor without a valid claim is closed after this long (seconds).
pub const VISITOR_GRACE: f64 = 15.0;
/// An invite works this long (seconds) after its code was last on screen.
pub const INVITE_LIFE: f64 = 15.0 * 60.0;
/// The most links a device keeps.
pub const MAX_LINKS: usize = 16;
/// The most connections a device has open at once.
pub const MAX_CONNECTIONS: usize = 32;
