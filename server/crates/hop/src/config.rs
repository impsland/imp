use std::net::SocketAddr;
use std::time::Duration;

use imp_shared::config::{ConfigError, env_parse};

/// The Hop's limits. Defaults are the table in PROTOCOL.md.
#[derive(Debug, Clone)]
pub struct Config {
    pub addr: SocketAddr,
    pub handshake: Duration,
    pub per_ip_connections: usize,
    pub per_ip_per_minute: u32,
    pub max_connections: usize,
    pub idle: Duration,
    pub bytes_per_second: u64,
    pub mac_wait: Duration,
    pub phone_wait: Duration,
    pub room_sessions: usize,
}

impl Default for Config {
    fn default() -> Self {
        Self {
            addr: SocketAddr::from(([0, 0, 0, 0], 4677)),
            handshake: Duration::from_secs(10),
            per_ip_connections: 16,
            per_ip_per_minute: 30,
            max_connections: 20_000,
            idle: Duration::from_secs(120),
            bytes_per_second: 4 * 1024 * 1024,
            mac_wait: Duration::from_secs(300),
            phone_wait: Duration::from_secs(15),
            room_sessions: 4,
        }
    }
}

impl Config {
    pub fn from_env() -> Result<Self, ConfigError> {
        let d = Self::default();
        let secs =
            |name, default: Duration| env_parse(name, default.as_secs()).map(Duration::from_secs);
        Ok(Self {
            addr: env_parse("HOP_ADDR", d.addr)?,
            handshake: secs("HOP_HANDSHAKE_SECS", d.handshake)?,
            per_ip_connections: env_parse("HOP_PER_IP_CONNECTIONS", d.per_ip_connections)?,
            per_ip_per_minute: env_parse("HOP_PER_IP_PER_MINUTE", d.per_ip_per_minute)?,
            max_connections: env_parse("HOP_MAX_CONNECTIONS", d.max_connections)?,
            idle: secs("HOP_IDLE_SECS", d.idle)?,
            bytes_per_second: env_parse("HOP_BYTES_PER_SECOND", d.bytes_per_second)?.max(1),
            mac_wait: secs("HOP_MAC_WAIT_SECS", d.mac_wait)?,
            phone_wait: secs("HOP_PHONE_WAIT_SECS", d.phone_wait)?,
            room_sessions: env_parse("HOP_ROOM_SESSIONS", d.room_sessions)?,
        })
    }
}
