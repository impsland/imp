//! Client addresses: who is really connecting, and the key they are limited by.

use std::fmt;
use std::net::{IpAddr, Ipv4Addr, Ipv6Addr};
use std::str::FromStr;
use std::sync::OnceLock;

use sha2::{Digest, Sha256};

/// What a client is limited by: an IPv4 address, or an IPv6 /64 (one network, many addresses).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum IpKey {
    V4(Ipv4Addr),
    V6([u8; 8]),
}

impl From<IpAddr> for IpKey {
    fn from(ip: IpAddr) -> Self {
        match ip.to_canonical() {
            IpAddr::V4(v4) => IpKey::V4(v4),
            IpAddr::V6(v6) => {
                let o = v6.octets();
                IpKey::V6([o[0], o[1], o[2], o[3], o[4], o[5], o[6], o[7]])
            }
        }
    }
}

impl fmt::Display for IpKey {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            IpKey::V4(v4) => write!(f, "{v4}"),
            IpKey::V6(p) => {
                let mut o = [0u8; 16];
                o[..8].copy_from_slice(p);
                write!(f, "{}/64", Ipv6Addr::from(o))
            }
        }
    }
}

impl IpKey {
    /// A short tag for logs that doesn't reveal the address: the first bytes of a salted hash.
    /// The salt is random per process, so tags correlate lines within one run and nothing more.
    pub fn log_tag(&self) -> String {
        static SALT: OnceLock<[u8; 16]> = OnceLock::new();
        let salt = SALT.get_or_init(rand::random);
        let mut h = Sha256::new();
        h.update(salt);
        h.update(self.to_string().as_bytes());
        hex::encode(&h.finalize()[..4])
    }
}

/// A network in CIDR notation.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Cidr {
    network: IpAddr,
    bits: u8,
}

#[derive(Debug, thiserror::Error)]
#[error("{0:?} is not an address or CIDR network")]
pub struct CidrError(String);

impl FromStr for Cidr {
    type Err = CidrError;

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        let s = s.trim();
        let bad = || CidrError(s.to_owned());
        let (addr, bits) = match s.split_once('/') {
            Some((a, b)) => (a, Some(b.parse::<u8>().map_err(|_| bad())?)),
            None => (s, None),
        };
        let ip = IpAddr::from_str(addr).map_err(|_| bad())?.to_canonical();
        let max = if ip.is_ipv4() { 32 } else { 128 };
        let bits = bits.unwrap_or(max);
        if bits > max {
            return Err(bad());
        }
        Ok(Cidr { network: ip, bits })
    }
}

impl Cidr {
    pub fn contains(&self, ip: IpAddr) -> bool {
        match (self.network, ip.to_canonical()) {
            (IpAddr::V4(n), IpAddr::V4(a)) => {
                masked(u32::from(n).into(), u32::from(a).into(), self.bits, 32)
            }
            (IpAddr::V6(n), IpAddr::V6(a)) => masked(u128::from(n), u128::from(a), self.bits, 128),
            _ => false,
        }
    }
}

fn masked(network: u128, addr: u128, bits: u8, width: u32) -> bool {
    if bits == 0 {
        return true;
    }
    let shift = width - u32::from(bits);
    (network >> shift) == (addr >> shift)
}

/// The proxies allowed to say who the client is with `X-Forwarded-For`.
#[derive(Debug, Clone, Default)]
pub struct TrustedProxies(Vec<Cidr>);

impl FromStr for TrustedProxies {
    type Err = CidrError;

    /// Comma-separated addresses or CIDR networks. Empty means no proxy is trusted.
    fn from_str(s: &str) -> Result<Self, Self::Err> {
        s.split(',')
            .map(str::trim)
            .filter(|p| !p.is_empty())
            .map(Cidr::from_str)
            .collect::<Result<Vec<_>, _>>()
            .map(TrustedProxies)
    }
}

impl TrustedProxies {
    pub fn is_trusted(&self, ip: IpAddr) -> bool {
        self.0.iter().any(|c| c.contains(ip))
    }

    /// The client's address. `X-Forwarded-For` counts only when the TCP peer is a trusted proxy,
    /// and then the rightmost hop that isn't a trusted proxy is the client. Everything left of it
    /// is whatever the client chose to claim, so it is never used.
    pub fn client_ip<'a>(
        &self,
        peer: IpAddr,
        forwarded_for: impl IntoIterator<Item = &'a str>,
    ) -> IpAddr {
        let peer = peer.to_canonical();
        if !self.is_trusted(peer) {
            return peer;
        }
        let hops: Vec<&str> = forwarded_for
            .into_iter()
            .flat_map(|v| v.split(','))
            .map(str::trim)
            .collect();
        let mut current = peer;
        for hop in hops.iter().rev() {
            match IpAddr::from_str(hop) {
                Ok(ip) if self.is_trusted(ip) => current = ip.to_canonical(),
                Ok(ip) => return ip.to_canonical(),
                Err(_) => return current,
            }
        }
        current
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn ip(s: &str) -> IpAddr {
        s.parse().expect("test address")
    }

    #[test]
    fn keys_group_ipv6_by_64() {
        assert_eq!(
            IpKey::from(ip("2001:db8:1:2::1")),
            IpKey::from(ip("2001:db8:1:2:ffff::9"))
        );
        assert_ne!(
            IpKey::from(ip("2001:db8:1:2::1")),
            IpKey::from(ip("2001:db8:1:3::1"))
        );
        assert_eq!(
            IpKey::from(ip("::ffff:10.1.2.3")),
            IpKey::from(ip("10.1.2.3"))
        );
    }

    #[test]
    fn forwarded_for_only_from_trusted_peers() {
        let proxies: TrustedProxies = "10.0.0.0/8, 192.168.1.1".parse().expect("proxies");
        assert_eq!(
            proxies.client_ip(ip("203.0.113.9"), ["1.2.3.4"]),
            ip("203.0.113.9")
        );
        assert_eq!(
            proxies.client_ip(ip("10.0.0.2"), ["1.2.3.4"]),
            ip("1.2.3.4")
        );
        assert_eq!(
            proxies.client_ip(ip("10.0.0.2"), ["6.6.6.6, 1.2.3.4, 10.0.0.9"]),
            ip("1.2.3.4")
        );
        assert_eq!(
            proxies.client_ip(ip("10.0.0.2"), ["6.6.6.6", "1.2.3.4"]),
            ip("1.2.3.4")
        );
        assert_eq!(proxies.client_ip(ip("10.0.0.2"), []), ip("10.0.0.2"));
        assert_eq!(
            proxies.client_ip(ip("10.0.0.2"), ["nonsense"]),
            ip("10.0.0.2")
        );
    }

    #[test]
    fn cidr_rejects_nonsense() {
        assert!("10.0.0.0/33".parse::<Cidr>().is_err());
        assert!("hello".parse::<Cidr>().is_err());
        assert!("fd00::/8".parse::<Cidr>().is_ok());
    }
}
