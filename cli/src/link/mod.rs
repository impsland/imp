//! The link: this computer as one of the person's devices, next to their Macs and iPhones.
//!
//! - `book` keeps the links in a private file and the device's secret in the system key store.
//! - `net` finds the addresses other devices can reach this computer at.
//! - `runner` drives a `Node` from `imp-core` on sockets. The core decides everything, the runner moves bytes.
//! - `device` is what the apps do on top of the node: it sends Imps to other devices and is their home
//!   while they are away, holds the Imps other devices send here, and carries messages between Imps.

mod book;
pub mod device;
mod net;
mod runner;

pub use book::{BookFile, SeedStore, SystemSeedStore, new_device_id};
pub use net::{NetworkAddress, local_hosts, order_hosts};
pub use runner::{NodeHandle, Runner, now};
