//! What a device needs to join another and prove it was invited: the inviting device (the host), its
//! keys and addresses. The host shows it as a QR code (`implink://join?...`) and the guest's camera
//! opens it in Imp. The door key and the invite key never cross the network in the clear. Never log it.

use crate::link::card::{LinkCard, LinkDevice, LinkKind, LinkRoutes};
use crate::link::messages::Bytes;
use base64::Engine as _;
use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use std::collections::HashMap;
use uuid::Uuid;

const SCHEME: &str = "implink://";
const LONGEST: usize = 2_000;

#[derive(Clone, PartialEq)]
pub struct LinkInvite {
    pub device: LinkDevice,
    /// Opens the host's session (`crypto::psk`). Stays the same until the host forgets everyone.
    pub door: Bytes,
    /// Lets a guest become a linked peer. New every time the host shows a code.
    pub invite: Bytes,
    pub routes: LinkRoutes,
}

impl LinkInvite {
    /// The host's visiting card, which is what a guest keeps of it.
    pub fn card(&self) -> LinkCard {
        LinkCard {
            device: self.device.clone(),
            door: self.door.clone(),
            routes: self.routes.clone(),
        }
    }

    /// The link the QR code holds.
    pub fn url(&self) -> String {
        let kind = match self.device.kind {
            LinkKind::Mac => "mac",
            LinkKind::Phone => "phone",
        };
        let mut url = format!(
            "{SCHEME}join?d={}&n={}&t={kind}&k={}&r={}&door={}&inv={}",
            self.device.id.hyphenated().to_string().to_uppercase(),
            escape(&self.device.name, ""),
            URL_SAFE_NO_PAD.encode(&self.device.key.0),
            URL_SAFE_NO_PAD.encode(&self.device.room.0),
            URL_SAFE_NO_PAD.encode(&self.door.0),
            URL_SAFE_NO_PAD.encode(&self.invite.0),
        );
        if !self.routes.hosts.is_empty() {
            url.push_str("&h=");
            url.push_str(&escape(&self.routes.hosts.join(","), ",:"));
        }
        if self.routes.port != crate::link::PORT {
            url.push_str(&format!("&p={}", self.routes.port));
        }
        if let Some(hop) = &self.routes.hop {
            url.push_str("&hop=");
            url.push_str(&escape(hop, ":"));
        }
        url
    }

    /// Reads an invite pasted or scanned (whitespace around it is fine). None unless it is whole and
    /// every value is what it should be: an id, full-length keys in base64url, a short name, a few
    /// valid hosts and a port.
    pub fn parse(text: &str) -> Option<Self> {
        let text = text.trim();
        if text.len() > LONGEST || text.chars().any(|c| c.is_whitespace() || c.is_control()) {
            return None;
        }
        let (scheme, rest) = text.split_at_checked(SCHEME.len())?;
        if !scheme.eq_ignore_ascii_case(SCHEME) {
            return None;
        }
        let rest = rest.split('#').next()?;
        let (host, query) = rest.split_once('?')?;
        if !host.eq_ignore_ascii_case("join") {
            return None;
        }
        let mut values: HashMap<&str, String> = HashMap::new();
        for item in query.split('&') {
            let (name, value) = item.split_once('=')?;
            // A repeated name is ambiguous: refuse rather than guess which one counts.
            if values.insert(name, unescape(value)?).is_some() {
                return None;
            }
        }
        let key = |name: &str| -> Option<Bytes> {
            let bytes = base64url(values.get(name)?)?;
            (bytes.len() == 32).then_some(Bytes(bytes))
        };
        let id = Uuid::parse_str(values.get("d")?).ok()?;
        let kind = match values.get("t")?.as_str() {
            "mac" => LinkKind::Mac,
            "phone" => LinkKind::Phone,
            _ => return None,
        };
        let (key, room, door, invite) = (key("k")?, key("r")?, key("door")?, key("inv")?);
        let hosts: Vec<String> = match values.get("h") {
            Some(h) => h.split(',').map(str::to_owned).collect(),
            None => Vec::new(),
        };
        let port = match values.get("p") {
            Some(p) => {
                if p.len() > 5 || !p.bytes().all(|b| b.is_ascii_digit()) {
                    return None;
                }
                p.parse::<u16>().ok().filter(|p| *p > 0)?
            }
            None => crate::link::PORT,
        };
        let routes = LinkRoutes::checked(&hosts, port, values.get("hop").map(String::as_str))?;
        let name = values.get("n").map_or("", String::as_str);
        Some(Self {
            device: LinkDevice {
                id,
                name: LinkDevice::cleaned(name, kind),
                kind,
                key,
                room,
            },
            door,
            invite,
            routes,
        })
    }
}

/// Keys stay out of logs and debug output.
impl std::fmt::Debug for LinkInvite {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("LinkInvite")
            .field("device", &self.device.id)
            .field("name", &self.device.name)
            .finish_non_exhaustive()
    }
}

/// Strict: only the base64url alphabet, no padding, and nothing a decoder would have to guess at.
fn base64url(text: &str) -> Option<Vec<u8>> {
    URL_SAFE_NO_PAD.decode(text).ok()
}

/// Percent-encodes everything but letters, digits, `-._~` and the characters in `keep`.
fn escape(text: &str, keep: &str) -> String {
    let mut out = String::new();
    for byte in text.bytes() {
        if byte.is_ascii_alphanumeric()
            || b"-._~".contains(&byte)
            || keep.as_bytes().contains(&byte)
        {
            out.push(char::from(byte));
        } else {
            out.push_str(&format!("%{byte:02X}"));
        }
    }
    out
}

fn unescape(text: &str) -> Option<String> {
    let bytes = text.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'%' {
            let hex = text.get(i + 1..i + 3)?;
            out.push(
                u8::from_str_radix(hex, 16)
                    .ok()
                    .filter(|_| hex.bytes().all(|b| b.is_ascii_hexdigit()))?,
            );
            i += 3;
        } else {
            out.push(bytes[i]);
            i += 1;
        }
    }
    String::from_utf8(out).ok()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::link::identity::Identity;

    fn host() -> Identity {
        Identity::from_seed(
            Uuid::from_u128(1),
            "Art\u{2019}s MacBook Pro",
            LinkKind::Mac,
            [1; 32],
        )
    }

    fn door() -> Bytes {
        Bytes((0..32).collect())
    }

    fn secret() -> Bytes {
        Bytes((100..132).collect())
    }

    fn invite_with(hosts: &[&str], port: u16, hop: Option<&str>) -> LinkInvite {
        let hosts: Vec<String> = hosts.iter().map(|h| h.to_string()).collect();
        LinkInvite {
            device: host().device(),
            door: door(),
            invite: secret(),
            routes: LinkRoutes::checked(&hosts, port, hop).unwrap(),
        }
    }

    fn invite() -> LinkInvite {
        invite_with(
            &["art.local", "192.168.1.7"],
            crate::link::PORT,
            Some("imp.example.org:4677"),
        )
    }

    /// The code with one query item replaced, dropped (None value) or added.
    fn tweak(name: &str, value: Option<&str>) -> String {
        let url = invite().url();
        let (head, query) = url.split_once('?').unwrap();
        let mut items: Vec<String> = query
            .split('&')
            .filter(|i| i.split('=').next() != Some(name))
            .map(str::to_owned)
            .collect();
        if let Some(value) = value {
            items.push(format!("{name}={value}"));
        }
        format!("{head}?{}", items.join("&"))
    }

    fn b64(bytes: &[u8]) -> String {
        URL_SAFE_NO_PAD.encode(bytes)
    }

    #[test]
    fn round_trips() {
        let i = invite();
        let url = i.url();
        assert!(url.starts_with("implink://join?"));
        assert_eq!(LinkInvite::parse(&url), Some(i.clone()));
        assert_eq!(LinkInvite::parse(&format!("  {url}\n")), Some(i));
        // The port is only written when it is not the usual one.
        assert!(!url.contains("&p="));
        let odd = invite_with(&["art.local"], 50_001, None);
        assert_eq!(LinkInvite::parse(&odd.url()).unwrap().routes.port, 50_001);
        // No hosts, no hop: just the keys.
        let bare = invite_with(&[], crate::link::PORT, None);
        assert_eq!(LinkInvite::parse(&bare.url()), Some(bare.clone()));
        assert!(!bare.url().contains("h=") && !bare.url().contains("hop="));
    }

    #[test]
    fn the_code_holds_the_specified_fields_and_no_version() {
        let url = invite().url();
        let items: HashMap<&str, &str> = url
            .split_once('?')
            .unwrap()
            .1
            .split('&')
            .map(|i| i.split_once('=').unwrap())
            .collect();
        let h = host();
        assert_eq!(items["d"], "00000000-0000-0000-0000-000000000001");
        assert_eq!(items["t"], "mac");
        assert_eq!(items["k"], b64(&h.key()));
        assert_eq!(items["r"], b64(&h.room_key()));
        assert_eq!(items["door"], b64(&door().0));
        assert_eq!(items["inv"], b64(&secret().0));
        assert_eq!(items["h"], "art.local,192.168.1.7");
        assert_eq!(items["hop"], "imp.example.org:4677");
        assert!(!items.contains_key("v"));
        assert!(!items["k"].contains('=') && !items["door"].contains('+'));
    }

    #[test]
    fn names_survive_any_characters() {
        for name in [
            "Art\u{2019}s Mac & friends",
            "a=b+c%20d",
            "日本語 🧡",
            "x?y#z/w",
        ] {
            let mut i = invite();
            i.device.name = name.into();
            assert_eq!(
                LinkInvite::parse(&i.url()).unwrap().device.name,
                name,
                "{name}"
            );
        }
        assert_eq!(
            LinkInvite::parse(&tweak("n", Some("")))
                .unwrap()
                .device
                .name,
            "Mac"
        );
        assert_eq!(
            LinkInvite::parse(&tweak("n", None)).unwrap().device.name,
            "Mac"
        );
        let long = "n".repeat(500);
        assert_eq!(
            LinkInvite::parse(&tweak("n", Some(&long)))
                .unwrap()
                .device
                .name
                .chars()
                .count(),
            80
        );
    }

    #[test]
    fn rejects_what_is_not_whole() {
        assert!(
            LinkInvite::parse(&tweak("d", Some("00000000-0000-0000-0000-000000000001"))).is_some()
        );
        let k31 = b64(&[1; 31]);
        let k33 = b64(&[1; 33]);
        let padded = format!("{}=", b64(&[1; 32]));
        let plus = "+".repeat(43);
        let slash = "/".repeat(43);
        let spaced = format!(" {}", b64(&secret().0));
        let nine = (0..9)
            .map(|n| format!("h{n}.local"))
            .collect::<Vec<_>>()
            .join(",");
        let cases: Vec<(&str, Option<&str>)> = vec![
            ("d", Some("nope")),
            ("d", None),
            ("t", Some("tablet")),
            ("t", None),
            ("k", Some("c2hvcnQ")),
            ("k", None),
            ("r", None),
            ("r", Some(&k31)),
            ("door", None),
            ("inv", None),
            ("door", Some(&k31)),
            ("inv", Some(&k33)),
            ("k", Some(&padded)),
            ("door", Some(&plus)),
            ("inv", Some(&slash)),
            ("inv", Some(&spaced)),
            ("h", Some("a%20b")),
            ("h", Some("A.local,")),
            ("h", Some(",a.local")),
            ("h", Some("x/y")),
            ("h", Some("a..b")),
            ("h", Some("-a.local")),
            ("h", Some(&nine)),
            ("p", Some("0")),
            ("p", Some("65536")),
            ("p", Some("+80")),
            ("p", Some("-1")),
            ("p", Some("８０")),
            ("p", Some("80a")),
            ("p", Some("")),
            ("hop", Some("host")),
            ("hop", Some("host:0")),
            ("hop", Some("a%20b:80")),
            ("hop", Some("host:99999")),
            ("n", Some("%ff")),
            ("n", Some("%zz")),
            ("n", Some("%4")),
        ];
        for (name, value) in cases {
            assert_eq!(
                LinkInvite::parse(&tweak(name, value)),
                None,
                "{name}={value:?}"
            );
        }
    }

    #[test]
    fn strict_base64_only_has_one_spelling() {
        // The last character of a 32-byte key has only 4 meaningful bits: another spelling of the same key is no key.
        let good = b64(&secret().0);
        let last = good.chars().last().unwrap();
        let alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";
        let head = &good[..good.len() - 1];
        let sibling = alphabet
            .chars()
            .find(|c| *c != last && base64url(&format!("{head}{c}")) == Some(secret().0));
        assert_eq!(sibling, None);
        assert_eq!(base64url(&good), Some(secret().0));
        assert_eq!(base64url(""), Some(vec![]));
        assert_eq!(base64url("a"), None);
    }

    #[test]
    fn rejects_broken_addresses_and_oversized_links() {
        let id = crate::link::crypto::new_id();
        assert_eq!(LinkInvite::parse(&format!("implink://join?d={id}")), None);
        assert_eq!(LinkInvite::parse("https://join?d=1"), None);
        assert_eq!(LinkInvite::parse("implink://pair?d=1"), None);
        assert_eq!(LinkInvite::parse(""), None);
        assert_eq!(LinkInvite::parse("not a url"), None);
        // A repeated name is ambiguous.
        let doubled = format!("{}&inv={}", invite().url(), b64(&[5; 32]));
        assert_eq!(LinkInvite::parse(&doubled), None);
        // Far too long, even if it starts like a code.
        let huge = format!("{}&x={}", invite().url(), "a".repeat(3_000));
        assert_eq!(LinkInvite::parse(&huge), None);
        // A valueless item is no value.
        assert_eq!(LinkInvite::parse(&format!("{}&flag", invite().url())), None);
        // Unknown names are fine: a newer app may add some.
        assert_eq!(
            LinkInvite::parse(&format!("{}&future=1", invite().url())),
            Some(invite())
        );
        // A scheme and host in any case, a fragment ignored.
        let shouty = invite()
            .url()
            .replacen("implink://join", "IMPLINK://Join", 1);
        assert_eq!(LinkInvite::parse(&format!("{shouty}#frag")), Some(invite()));
        // Never panics on the edge of a multi-byte character.
        assert_eq!(LinkInvite::parse("implink:/é"), None);
    }

    #[test]
    fn debug_output_keeps_secrets_out() {
        let i = invite();
        let text = format!("{i:?} {:?}", i.card());
        for secret in [b64(&door().0), b64(&secret().0), b64(&host().key())] {
            assert!(!text.contains(&secret));
        }
    }

    #[test]
    fn routes_are_checked_and_tidied() {
        let s = |v: &[&str]| v.iter().map(|x| x.to_string()).collect::<Vec<_>>();
        assert_eq!(
            LinkRoutes::checked(&s(&["A.Local", "a.local", " B.local "]), 1, None)
                .unwrap()
                .hosts,
            ["a.local", "b.local"]
        );
        assert!(LinkRoutes::checked(&[], 0, None).is_none());
        assert!(LinkRoutes::checked(&s(&["bad host"]), 1, None).is_none());
        // Routes a device builds itself keep what is good.
        let own = LinkRoutes::lenient(
            &s(&["ok.local", "not ok", "OK.local", "10.0.0.2"]),
            0,
            Some("nope"),
        );
        assert_eq!(own.hosts, ["ok.local", "10.0.0.2"]);
        assert_eq!(own.port, crate::link::PORT);
        assert_eq!(own.hop, None);
        let many: Vec<String> = (0..20).map(|n| format!("h{n}.local")).collect();
        assert_eq!(LinkRoutes::lenient(&many, 1, None).hosts.len(), 8);
    }
}
