//! Who a device is, how to reach it, and the visiting card an Imp carries so its holder can find its
//! home again. Everything here is checked when it is built or read, so what is held is always valid.

use crate::link::crypto::KEY_BYTES;
use crate::link::hop::{HopAddress, is_host};
use crate::link::messages::Bytes;
use serde::{Deserialize, Serialize};
use uuid::Uuid;

/// The longest device name in characters.
pub const LONGEST_NAME: usize = 80;
/// The most hosts in a set of routes.
pub const MOST_HOSTS: usize = 8;

/// What kind of device this is.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum LinkKind {
    Mac,
    Phone,
}

/// Who a device says it is, as other devices know it. Public things only.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(try_from = "RawDevice")]
pub struct LinkDevice {
    pub id: Uuid,
    pub name: String,
    pub kind: LinkKind,
    /// The Noise static public key (32 bytes) other devices pin.
    pub key: Bytes,
    /// The Ed25519 public key (32 bytes) that names the device's room at the Hop.
    pub room: Bytes,
}

#[derive(Deserialize)]
struct RawDevice {
    id: Uuid,
    name: String,
    kind: LinkKind,
    key: Bytes,
    room: Bytes,
}

impl TryFrom<RawDevice> for LinkDevice {
    type Error = String;

    /// Names are cleaned and keys must be whole, wherever the device came from.
    fn try_from(raw: RawDevice) -> Result<Self, String> {
        if raw.key.is_key() && raw.room.is_key() {
            Ok(Self {
                id: raw.id,
                name: Self::cleaned(&raw.name, raw.kind),
                kind: raw.kind,
                key: raw.key,
                room: raw.room,
            })
        } else {
            Err("bad key".into())
        }
    }
}

impl LinkDevice {
    /// A name people recognise: trimmed, capped, never empty.
    pub fn cleaned(name: &str, kind: LinkKind) -> String {
        let trimmed = name.trim();
        if trimmed.is_empty() {
            match kind {
                LinkKind::Mac => "Mac".into(),
                LinkKind::Phone => "iPhone".into(),
            }
        } else {
            trimmed.chars().take(LONGEST_NAME).collect()
        }
    }
}

/// Where a device can be reached besides Bonjour: host names or addresses on a network the other side
/// shares or can route to (Wi-Fi, a VPN), the port, and the Hop it waits at.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(try_from = "RawRoutes")]
pub struct LinkRoutes {
    pub hosts: Vec<String>,
    pub port: u16,
    /// The Hop this device waits at (`host:port`), none if it has no server.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub hop: Option<String>,
}

#[derive(Deserialize)]
struct RawRoutes {
    hosts: Vec<String>,
    port: u16,
    #[serde(default)]
    hop: Option<String>,
}

impl TryFrom<RawRoutes> for LinkRoutes {
    type Error = String;

    fn try_from(raw: RawRoutes) -> Result<Self, String> {
        Self::checked(&raw.hosts, raw.port, raw.hop.as_deref()).ok_or_else(|| "bad routes".into())
    }
}

impl LinkRoutes {
    /// No way to be reached but Bonjour.
    pub fn none() -> Self {
        Self {
            hosts: Vec::new(),
            port: crate::link::PORT,
            hop: None,
        }
    }

    /// None unless every piece is valid. Hosts are lower-cased and de-duplicated.
    pub fn checked(hosts: &[String], port: u16, hop: Option<&str>) -> Option<Self> {
        let mut seen = Vec::<String>::new();
        for host in hosts {
            let host = host.trim().to_lowercase();
            if !seen.contains(&host) {
                seen.push(host);
            }
        }
        let hop = match hop {
            Some(text) => Some(HopAddress::parse(text)?.text()),
            None => None,
        };
        (port > 0 && seen.len() <= MOST_HOSTS && seen.iter().all(|h| is_host(h))).then_some(Self {
            hosts: seen,
            port,
            hop,
        })
    }

    /// Keeps what is valid of `hosts` (up to the most there can be), for routes this device builds itself.
    pub fn lenient(hosts: &[String], port: u16, hop: Option<&str>) -> Self {
        let mut kept = Vec::<String>::new();
        for host in hosts {
            let host = host.to_lowercase();
            if is_host(&host) && !kept.contains(&host) {
                kept.push(host);
            }
        }
        kept.truncate(MOST_HOSTS);
        Self {
            port: if port > 0 { port } else { crate::link::PORT },
            hop: hop
                .and_then(HopAddress::parse)
                .and_then(|a| Self::reachable(a, &kept))
                .map(|a| a.text()),
            hosts: kept,
        }
    }

    /// A Hop on this device's own loopback (`localhost:4677`, a Hop the person runs here) means nothing
    /// to the device that reads the card: there it is that device itself. So it is given out under this
    /// device's own first host instead, and left out when this device has no host to give.
    fn reachable(hop: HopAddress, hosts: &[String]) -> Option<HopAddress> {
        if !is_loopback(&hop.host) {
            return Some(hop);
        }
        let host = hosts.iter().find(|h| !is_loopback(h))?;
        HopAddress::new(host, hop.port)
    }

    pub fn hop_address(&self) -> Option<HopAddress> {
        self.hop.as_deref().and_then(HopAddress::parse)
    }
}

/// Whether `host` only ever means the device it is written on.
fn is_loopback(host: &str) -> bool {
    host == "localhost" || host.ends_with(".localhost") || host.starts_with("127.")
}

/// A device's visiting card: who it is and how to reach it. An Imp carries its home's card when it
/// travels. It holds the home's door key, so a card is a secret and must not be logged.
#[derive(Clone, PartialEq, Serialize, Deserialize)]
#[serde(try_from = "RawCard")]
pub struct LinkCard {
    pub device: LinkDevice,
    pub door: Bytes,
    pub routes: LinkRoutes,
}

#[derive(Deserialize)]
struct RawCard {
    device: LinkDevice,
    door: Bytes,
    routes: LinkRoutes,
}

impl TryFrom<RawCard> for LinkCard {
    type Error = String;

    fn try_from(raw: RawCard) -> Result<Self, String> {
        if raw.door.0.len() == KEY_BYTES {
            Ok(Self {
                device: raw.device,
                door: raw.door,
                routes: raw.routes,
            })
        } else {
            Err("bad card".into())
        }
    }
}

impl LinkCard {
    pub fn id(&self) -> Uuid {
        self.device.id
    }
}

impl std::fmt::Debug for LinkCard {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("LinkCard")
            .field("device", &self.device.id)
            .field("door", &"<hidden>")
            .finish_non_exhaustive()
    }
}
