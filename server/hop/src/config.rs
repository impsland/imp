use std::net::{IpAddr, SocketAddr};
use std::str::FromStr;
use std::time::Duration;

use imp_shared::config::{ConfigError, env_opt, env_parse};

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
    /// Proxies whose `X-Forwarded-For` names the browser behind a WebSocket (`HOP_FORWARDED_FROM`: a
    /// comma-separated list of addresses or prefixes, such as `172.16.0.0/12`). Empty: nobody's. A
    /// browser's limits then count against the proxy's own address.
    pub forwarded_from: Vec<Prefix>,
}

/// An address or a prefix of addresses, such as `10.0.0.0/8` or `::1`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Prefix {
    addr: IpAddr,
    bits: u8,
}

impl Prefix {
    pub fn contains(&self, ip: IpAddr) -> bool {
        let ip = match ip {
            IpAddr::V6(v6) => v6.to_ipv4_mapped().map_or(ip, IpAddr::V4),
            v4 => v4,
        };
        match (self.addr, ip) {
            (IpAddr::V4(net), IpAddr::V4(ip)) => {
                let mask = u32::MAX.checked_shl(32 - u32::from(self.bits)).unwrap_or(0);
                u32::from(net) & mask == u32::from(ip) & mask
            }
            (IpAddr::V6(net), IpAddr::V6(ip)) => {
                let mask = u128::MAX
                    .checked_shl(128 - u32::from(self.bits))
                    .unwrap_or(0);
                u128::from(net) & mask == u128::from(ip) & mask
            }
            _ => false,
        }
    }
}

impl FromStr for Prefix {
    type Err = String;

    fn from_str(text: &str) -> Result<Self, Self::Err> {
        let (addr, bits) = match text.split_once('/') {
            Some((addr, bits)) => (addr, Some(bits)),
            None => (text, None),
        };
        let addr: IpAddr = addr
            .trim()
            .parse()
            .map_err(|_| format!("{text} is not an address"))?;
        let most = if addr.is_ipv4() { 32 } else { 128 };
        let bits = match bits {
            Some(bits) => bits
                .trim()
                .parse::<u8>()
                .ok()
                .filter(|b| *b <= most)
                .ok_or_else(|| format!("{text} has a bad prefix length"))?,
            None => most,
        };
        Ok(Self { addr, bits })
    }
}

/// Reads a comma-separated list of prefixes. Empty or missing: none.
fn prefixes(name: &'static str) -> Result<Vec<Prefix>, ConfigError> {
    let Some(text) = env_opt(name) else {
        return Ok(Vec::new());
    };
    text.split(',')
        .map(str::trim)
        .filter(|part| !part.is_empty())
        .map(|part| {
            part.parse()
                .map_err(|reason| ConfigError::Invalid { name, reason })
        })
        .collect()
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
            forwarded_from: Vec::new(),
        }
    }
}

impl Config {
    /// Reads each `HOP_` limit from the environment, falling back to the defaults, then validates them.
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
            forwarded_from: prefixes("HOP_FORWARDED_FROM")?,
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
    fn prefixes_match_their_addresses() {
        let docker: Prefix = "172.16.0.0/12".parse().unwrap();
        assert!(docker.contains("172.18.0.5".parse().unwrap()));
        assert!(docker.contains("::ffff:172.18.0.5".parse().unwrap()));
        assert!(!docker.contains("172.32.0.1".parse().unwrap()));
        let one: Prefix = "::1".parse().unwrap();
        assert!(one.contains("::1".parse().unwrap()));
        assert!(!one.contains("127.0.0.1".parse().unwrap()));
        let all: Prefix = "0.0.0.0/0".parse().unwrap();
        assert!(all.contains("8.8.8.8".parse().unwrap()));
        assert!("10.0.0.0/33".parse::<Prefix>().is_err());
        assert!("proxy".parse::<Prefix>().is_err());
    }

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
