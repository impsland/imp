//! What the Den and the Hop have in common: configuration, client addresses, rate limits, logging,
//! shutdown and the health check.
#![forbid(unsafe_code)]

pub mod config;
pub mod health;
pub mod ip;
pub mod limit;
pub mod shutdown;
pub mod telemetry;
