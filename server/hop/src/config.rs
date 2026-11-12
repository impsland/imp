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
    pub host_wait: Duration,
    pub guest_wait: Duration,
    pub room_sessions: usize,
}

impl Default for Config {
    fn default() -> Self {
        Self {
            addr: SocketAddr::from(([0, 0, 0, 0], 4677)),
            handshake: Duration::from_secs(10),
            per_ip_connections: 64,
            per_ip_per_minute: 120,
            max_connections: 20_000,
            idle: Duration::from_secs(120),
            bytes_per_second: 4 * 1024 * 1024,
            host_wait: Duration::from_secs(300),
            guest_wait: Duration::from_secs(15),
            room_sessions: 16,
        }
    }
}

impl Config {
    pub fn from_env() -> Result<Self, ConfigError> {
        let d = Self::default();
        let secs =
            |name, default: Duration| env_parse(name, default.as_secs()).map(Duration::from_secs);
        Self {
            addr: env_parse("HOP_ADDR", d.addr)?,
            handshake: secs("HOP_HANDSHAKE_SECS", d.handshake)?,
            per_ip_connections: env_parse("HOP_PER_IP_CONNECTIONS", d.per_ip_connections)?,
            per_ip_per_minute: env_parse("HOP_PER_IP_PER_MINUTE", d.per_ip_per_minute)?,
            max_connections: env_parse("HOP_MAX_CONNECTIONS", d.max_connections)?,
            idle: secs("HOP_IDLE_SECS", d.idle)?,
            bytes_per_second: env_parse("HOP_BYTES_PER_SECOND", d.bytes_per_second)?,
            host_wait: secs("HOP_HOST_WAIT_SECS", d.host_wait)?,
            guest_wait: secs("HOP_GUEST_WAIT_SECS", d.guest_wait)?,
            room_sessions: env_parse("HOP_ROOM_SESSIONS", d.room_sessions)?,
        }
        .validated()
    }

    /// Every limit must allow something: a zero would refuse all traffic or never time out.
    pub fn validated(self) -> Result<Self, ConfigError> {
        let positive = [
            ("HOP_HANDSHAKE_SECS", self.handshake.as_secs()),
            ("HOP_PER_IP_CONNECTIONS", self.per_ip_connections as u64),
            ("HOP_PER_IP_PER_MINUTE", u64::from(self.per_ip_per_minute)),
            ("HOP_MAX_CONNECTIONS", self.max_connections as u64),
            ("HOP_IDLE_SECS", self.idle.as_secs()),
            ("HOP_BYTES_PER_SECOND", self.bytes_per_second),
            ("HOP_HOST_WAIT_SECS", self.host_wait.as_secs()),
            ("HOP_GUEST_WAIT_SECS", self.guest_wait.as_secs()),
            ("HOP_ROOM_SESSIONS", self.room_sessions as u64),
        ];
        match positive.into_iter().find(|(_, value)| *value == 0) {
            Some((name, _)) => Err(ConfigError::Invalid {
                name,
                reason: "must be at least 1".to_owned(),
            }),
            None => Ok(self),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn defaults_are_valid() {
        assert!(Config::default().validated().is_ok());
    }

    #[test]
    fn zero_limits_are_refused() {
        type Break = fn(&mut Config);
        let cases: [(&str, Break); 4] = [
            ("HOP_BYTES_PER_SECOND", |c| c.bytes_per_second = 0),
            ("HOP_HANDSHAKE_SECS", |c| c.handshake = Duration::ZERO),
            ("HOP_MAX_CONNECTIONS", |c| c.max_connections = 0),
            ("HOP_ROOM_SESSIONS", |c| c.room_sessions = 0),
        ];
        for (name, break_it) in cases {
            let mut config = Config::default();
            break_it(&mut config);
            match config.validated() {
                Err(ConfigError::Invalid { name: got, .. }) => assert_eq!(got, name),
                other => panic!("{name} accepted: {other:?}"),
            }
        }
    }
}
