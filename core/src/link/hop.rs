//! The client side of the Hop (`spec/PROTOCOL.md`): the bytes a host or a guest says to the relay, the
//! proof it signs for the relay's nonce and the relay's answer. Nothing here touches a socket. A
//! connection to the Hop that gets a `go` carries the link's own encrypted bytes from then on.

use crate::link::crypto::{self, Key};
use crate::link::identity::Identity;
use ed25519_dalek::{Signature, Signer, SigningKey, VerifyingKey};

/// Where a Hop is: a lower-case host name or IPv4 address and a port, written `host:port`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct HopAddress {
    pub host: String,
    pub port: u16,
}

const LONGEST: usize = 255;

/// Whether `host` is a plain lower-case host name or IPv4 address.
pub fn is_host(host: &str) -> bool {
    host.len() <= LONGEST
        && !host.is_empty()
        && host
            .split('.')
            .all(|l| !l.is_empty() && !l.starts_with('-') && !l.ends_with('-'))
        && host
            .bytes()
            .all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'-' || b == b'.')
}

impl HopAddress {
    pub fn new(host: &str, port: u16) -> Option<Self> {
        let host = host.to_lowercase();
        (port > 0 && is_host(&host)).then_some(Self { host, port })
    }

    /// Reads `host:port`. Nil for anything else: a port that is not plain digits, a bad host.
    pub fn parse(text: &str) -> Option<Self> {
        if text.len() > LONGEST {
            return None;
        }
        let (host, digits) = text.rsplit_once(':')?;
        if digits.is_empty() || digits.len() > 5 || !digits.bytes().all(|b| b.is_ascii_digit()) {
            return None;
        }
        Self::new(host, digits.parse().ok()?)
    }

    pub fn text(&self) -> String {
        format!("{}:{}", self.host, self.port)
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum HopRole {
    /// Owns the room and waits in it.
    Host = 1,
    /// Joins the room.
    Guest = 2,
}

/// The relay's answer once the proof was checked.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum HopStatus {
    /// The other side is spliced in: the link's bytes follow.
    Go = 0,
    /// Bad hello or proof: give up on the Hop for now.
    Rejected = 1,
    /// A limit was hit: back off.
    Busy = 2,
    /// Nobody came before the wait ran out, or nobody is waiting.
    Nobody = 3,
}

impl HopRole {
    fn from_byte(byte: u8) -> Option<Self> {
        match byte {
            1 => Some(Self::Host),
            2 => Some(Self::Guest),
            _ => None,
        }
    }
}

impl HopStatus {
    fn from_byte(byte: u8) -> Option<Self> {
        Some(match byte {
            0 => Self::Go,
            1 => Self::Rejected,
            2 => Self::Busy,
            3 => Self::Nobody,
            _ => return None,
        })
    }
}

const MAGIC: &[u8; 6] = b"IMPHOP";
const PROOF_TAG: &[u8] = b"imp-hop proof";
/// How long the hello is: the magic, the role, the room and the gate.
pub const HELLO_LEN: usize = 6 + 1 + 32 + 32;
pub const NONCE_LEN: usize = 32;
pub const PROOF_LEN: usize = 64;

/// The guests' signing key, the same for everyone who knows the door key.
fn gate_key(door: &Key) -> SigningKey {
    SigningKey::from_bytes(&crypto::gate_seed(door))
}

/// The public half of the guests' key at the Hop (the host vouches for it, guests sign with it).
pub fn gate(door: &Key) -> Key {
    gate_key(door).verifying_key().to_bytes()
}

/// What one side needs to speak to the relay: the room, the gate and a way to sign.
#[derive(Clone)]
pub struct HopCredentials {
    role: HopRole,
    room: Key,
    gate: Key,
    signer: SigningKey,
}

impl HopCredentials {
    /// The host: signs with its device's room key.
    pub fn host(identity: &Identity, door: &Key) -> Self {
        Self {
            role: HopRole::Host,
            room: identity.room_key(),
            gate: gate(door),
            signer: identity.room_signer(),
        }
    }

    /// A guest of `room`: signs with the gate key derived from the host's door key.
    pub fn guest(room: Key, door: &Key) -> Self {
        Self {
            role: HopRole::Guest,
            room,
            gate: gate(door),
            signer: gate_key(door),
        }
    }

    pub fn role(&self) -> HopRole {
        self.role
    }

    /// First message to the relay: "IMPHOP", the role, the room and the gate.
    pub fn hello(&self) -> Vec<u8> {
        let mut hello = Vec::with_capacity(HELLO_LEN);
        hello.extend_from_slice(MAGIC);
        hello.push(self.role as u8);
        hello.extend_from_slice(&self.room);
        hello.extend_from_slice(&self.gate);
        hello
    }

    /// The signature the relay checks. A host vouches for the gate, a guest for the room.
    pub fn proof(&self, nonce: &[u8; NONCE_LEN]) -> [u8; PROOF_LEN] {
        let named = match self.role {
            HopRole::Host => &self.gate,
            HopRole::Guest => &self.room,
        };
        self.signer
            .sign(&proof_message(self.role, nonce, named))
            .to_bytes()
    }
}

/// What a proof signs: the tag, the role, the relay's nonce and the key the signer names.
fn proof_message(role: HopRole, nonce: &[u8; NONCE_LEN], named: &Key) -> Vec<u8> {
    let mut message = Vec::with_capacity(PROOF_TAG.len() + 1 + NONCE_LEN + 32);
    message.extend_from_slice(PROOF_TAG);
    message.push(role as u8);
    message.extend_from_slice(nonce);
    message.extend_from_slice(named);
    message
}

/// A hello as the relay reads it.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct HopHello {
    pub role: HopRole,
    pub room: Key,
    pub gate: Key,
}

impl HopHello {
    /// Reads a hello. Nil when the magic or the role is wrong.
    pub fn parse(bytes: &[u8; HELLO_LEN]) -> Option<Self> {
        if &bytes[..MAGIC.len()] != MAGIC {
            return None;
        }
        Some(Self {
            role: HopRole::from_byte(bytes[MAGIC.len()])?,
            room: bytes[MAGIC.len() + 1..MAGIC.len() + 33].try_into().ok()?,
            gate: bytes[MAGIC.len() + 33..].try_into().ok()?,
        })
    }

    /// Whether `proof` answers `nonce`. A host signs with the room key and names the gate. A guest signs
    /// with the gate key and names the room.
    pub fn accepts(&self, nonce: &[u8; NONCE_LEN], proof: &[u8; PROOF_LEN]) -> bool {
        let (signer, named) = match self.role {
            HopRole::Host => (&self.room, &self.gate),
            HopRole::Guest => (&self.gate, &self.room),
        };
        VerifyingKey::from_bytes(signer).is_ok_and(|key| {
            key.verify_strict(
                &proof_message(self.role, nonce, named),
                &Signature::from_bytes(proof),
            )
            .is_ok()
        })
    }
}

/// What came of the bytes just read from the relay.
#[derive(Debug, Default, PartialEq, Eq)]
pub struct HopProgress {
    /// Bytes to send to the relay now.
    pub reply: Vec<u8>,
    /// The relay's answer, once it gave one.
    pub status: Option<HopStatus>,
    /// Bytes that followed the answer. After `go` they belong to the link.
    pub rest: Vec<u8>,
}

/// The relay did not speak the protocol.
#[derive(Debug, Clone, Copy, PartialEq, Eq, thiserror::Error)]
#[error("the Hop sent something that is not its answer")]
pub struct HopError;

/// Steps 1 to 4 of the Hop handshake: hello, nonce, proof, status. Feed it what the relay sends.
pub struct HopClient {
    credentials: HopCredentials,
    nonce: Vec<u8>,
    proved: bool,
    done: bool,
}

impl HopClient {
    pub fn new(credentials: HopCredentials) -> Self {
        Self {
            credentials,
            nonce: Vec::new(),
            proved: false,
            done: false,
        }
    }

    pub fn role(&self) -> HopRole {
        self.credentials.role
    }

    /// The hello to send as soon as the connection is up.
    pub fn hello(&self) -> Vec<u8> {
        self.credentials.hello()
    }

    pub fn feed(&mut self, data: &[u8]) -> Result<HopProgress, HopError> {
        let mut progress = HopProgress::default();
        if self.done {
            progress.rest = data.to_vec();
            return Ok(progress);
        }
        let mut data = data;
        if !self.proved {
            let want = NONCE_LEN - self.nonce.len();
            let take = want.min(data.len());
            self.nonce.extend_from_slice(&data[..take]);
            data = &data[take..];
            if self.nonce.len() < NONCE_LEN {
                return Ok(progress);
            }
            let nonce: [u8; NONCE_LEN] = self.nonce.as_slice().try_into().map_err(|_| HopError)?;
            progress.reply = self.credentials.proof(&nonce).to_vec();
            self.proved = true;
        }
        if let Some((&byte, rest)) = data.split_first() {
            progress.status = Some(HopStatus::from_byte(byte).ok_or(HopError)?);
            progress.rest = rest.to_vec();
            self.done = true;
        }
        Ok(progress)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn verify(key: &Key, message: &[u8], proof: &[u8; 64]) -> bool {
        VerifyingKey::from_bytes(key)
            .unwrap()
            .verify_strict(message, &Signature::from_bytes(proof))
            .is_ok()
    }

    #[test]
    fn addresses_are_plain_lower_case_host_and_port() {
        assert_eq!(
            HopAddress::parse("Hop.Example.com:4677").unwrap().text(),
            "hop.example.com:4677"
        );
        assert_eq!(HopAddress::parse("10.0.0.2:1").unwrap().port, 1);
        for bad in [
            "hop.example.com",
            "hop.example.com:0",
            "hop.example.com:65536",
            "hop.example.com:+80",
            "hop.example.com:",
            ":80",
            "-bad.example:80",
            "bad..example:80",
            "ba d:80",
            "a_b:80",
            "[::1]:80",
        ] {
            assert!(HopAddress::parse(bad).is_none(), "{bad}");
        }
        assert!(HopAddress::parse(&format!("{}:80", "a".repeat(260))).is_none());
    }

    #[test]
    fn a_guest_proves_the_room_with_the_gate_key_and_a_host_the_gate_with_its_own() {
        let door = [9u8; 32];
        let identity = Identity::from_seed(
            uuid::Uuid::nil(),
            "Mac",
            crate::link::LinkKind::Mac,
            [4; 32],
        );
        let host = HopCredentials::host(&identity, &door);
        let guest = HopCredentials::guest(identity.room_key(), &door);
        assert_eq!(host.hello().len(), HELLO_LEN);
        assert_eq!(&host.hello()[..7], b"IMPHOP\x01");
        assert_eq!(&guest.hello()[..7], b"IMPHOP\x02");
        assert_eq!(host.hello()[7..], guest.hello()[7..]);

        let nonce = [5u8; 32];
        let mut message = b"imp-hop proof\x01".to_vec();
        message.extend_from_slice(&nonce);
        message.extend_from_slice(&gate(&door));
        assert!(verify(&identity.room_key(), &message, &host.proof(&nonce)));

        let mut message = b"imp-hop proof\x02".to_vec();
        message.extend_from_slice(&nonce);
        message.extend_from_slice(&identity.room_key());
        assert!(verify(&gate(&door), &message, &guest.proof(&nonce)));
        // The gate key is not the room key: a guest cannot wait as host.
        assert_ne!(gate(&door), identity.room_key());
    }

    #[test]
    fn the_client_answers_the_nonce_and_reads_the_status_however_the_bytes_arrive() {
        let door = [3u8; 32];
        let guest = HopCredentials::guest([8; 32], &door);
        let expected = guest.proof(&[1; 32]).to_vec();
        let mut client = HopClient::new(guest);
        let mut wire = vec![1u8; 32];
        wire.push(0);
        wire.extend_from_slice(b"link bytes");
        let mut reply = Vec::new();
        let mut status = None;
        let mut rest = Vec::new();
        for byte in &wire {
            let p = client.feed(&[*byte]).unwrap();
            reply.extend(p.reply);
            status = status.or(p.status);
            rest.extend(p.rest);
        }
        assert_eq!(reply, expected);
        assert_eq!(status, Some(HopStatus::Go));
        assert_eq!(rest, b"link bytes");
    }

    #[test]
    fn an_unknown_status_is_not_the_relay() {
        let mut client = HopClient::new(HopCredentials::guest([8; 32], &[3; 32]));
        let mut wire = vec![1u8; 32];
        wire.push(9);
        assert_eq!(client.feed(&wire), Err(HopError));
    }

    const ROOM: &str = "ac4fd1463cca02c58a6aa7d52e0c00596adffbf557017ef4580efa3390579a29";
    const GATE: &str = "5c242cbc2235cc5fa78039ea798e51772c4055239e6d0b92db2cefb2cfa446c1";
    const HOST_PROOF: &str = "0ca1869f1bd7757b000918fcc534484f75edc5bbf212d7d8ed5773ffec4efe426e3db497dd6b5ec34547450eb4776f62353eaba3aa8ad4d4c8ad2a102b507700";
    const GUEST_PROOF: &str = "0222687b879f99dead1d566207ccce1e33718d18983ae0981a2bdf6bc740064f8ded95d04821fe64d5a87ce13366405213787f77867f4a39eea3f95419270300";

    fn hex(bytes: &[u8]) -> String {
        bytes.iter().map(|b| format!("{b:02x}")).collect()
    }

    /// Device key 00 01 .. 1f, door key 20 21 .. 3f, nonce ff fe .. e0. The expected values were also
    /// checked outside Rust (Ed25519 verification by another implementation).
    fn fixed() -> (Identity, Key, [u8; NONCE_LEN]) {
        let seed: [u8; 32] = std::array::from_fn(|i| i as u8);
        let identity =
            Identity::from_seed(uuid::Uuid::nil(), "Mac", crate::link::LinkKind::Mac, seed);
        (
            identity,
            std::array::from_fn(|i| 32 + i as u8),
            std::array::from_fn(|i| 255 - i as u8),
        )
    }

    #[test]
    fn the_room_is_the_hosts_public_key_and_the_gate_comes_from_the_door() {
        let (identity, door, _) = fixed();
        assert_eq!(hex(&identity.room_key()), ROOM);
        assert_eq!(hex(&gate(&door)), GATE);
        assert_ne!(gate(&[7; 32]), gate(&door));
        assert_ne!(gate(&door), door);
    }

    #[test]
    fn the_hello_names_the_role_the_room_and_the_gate_in_seventy_one_bytes() {
        let (identity, door, _) = fixed();
        let host = HopCredentials::host(&identity, &door);
        let guest = HopCredentials::guest(identity.room_key(), &door);
        assert_eq!(
            (host.hello().len(), guest.hello().len(), HELLO_LEN),
            (71, 71, 71)
        );
        assert_eq!(&host.hello()[..6], b"IMPHOP");
        assert_eq!((host.hello()[6], guest.hello()[6]), (1, 2));
        for hello in [host.hello(), guest.hello()] {
            assert_eq!(hex(&hello[7..39]), ROOM);
            assert_eq!(hex(&hello[39..]), GATE);
        }
    }

    #[test]
    fn proofs_match_the_fixed_vectors() {
        let (identity, door, nonce) = fixed();
        let host = HopCredentials::host(&identity, &door);
        let guest = HopCredentials::guest(identity.room_key(), &door);
        assert_eq!(hex(&host.proof(&nonce)), HOST_PROOF);
        assert_eq!(hex(&guest.proof(&nonce)), GUEST_PROOF);
    }

    #[test]
    fn each_proof_is_good_for_one_role_one_nonce_and_one_key() {
        let (identity, door, nonce) = fixed();
        let (room, gate_key) = (identity.room_key(), gate(&door));
        let message = |role: u8, tail: &Key, nonce: &[u8]| {
            let mut m = b"imp-hop proof".to_vec();
            m.push(role);
            m.extend_from_slice(nonce);
            m.extend_from_slice(tail);
            m
        };
        let unhex = |s: &str| -> [u8; 64] {
            let bytes: Vec<u8> = (0..64)
                .map(|i| u8::from_str_radix(&s[i * 2..i * 2 + 2], 16).unwrap())
                .collect();
            bytes.try_into().unwrap()
        };
        let (host, guest) = (unhex(HOST_PROOF), unhex(GUEST_PROOF));
        let host_message = message(1, &gate_key, &nonce);
        let guest_message = message(2, &room, &nonce);
        assert!(verify(&room, &host_message, &host));
        assert!(!verify(&room, &guest_message, &host));
        assert!(verify(&gate_key, &guest_message, &guest));
        assert!(!verify(&gate_key, &host_message, &guest));
        // A guest cannot sign for the room, and the room key is not the gate.
        assert!(!verify(&room, &guest_message, &guest));
        assert!(!verify(&gate_key, &host_message, &host));
        let reversed: Vec<u8> = nonce.iter().rev().copied().collect();
        assert!(!verify(&gate_key, &message(2, &room, &reversed), &guest));
    }

    #[test]
    fn the_relay_side_accepts_exactly_the_matching_proofs() {
        let (identity, door, nonce) = fixed();
        let host = HopCredentials::host(&identity, &door);
        let guest = HopCredentials::guest(identity.room_key(), &door);
        let hello = |c: &HopCredentials| HopHello::parse(&c.hello().try_into().unwrap()).unwrap();
        assert!(hello(&host).accepts(&nonce, &host.proof(&nonce)));
        assert!(hello(&guest).accepts(&nonce, &guest.proof(&nonce)));
        assert!(!hello(&host).accepts(&nonce, &guest.proof(&nonce)));
        assert!(!hello(&guest).accepts(&nonce, &host.proof(&nonce)));
        assert!(!hello(&guest).accepts(&[0; NONCE_LEN], &guest.proof(&nonce)));
    }

    #[test]
    fn a_wrong_door_gives_a_gate_the_host_did_not_vouch_for() {
        let (identity, door, _) = fixed();
        let host = HopCredentials::host(&identity, &door);
        let wrong = HopCredentials::guest(identity.room_key(), &[1; 32]);
        assert_eq!(
            host.hello()[..39],
            wrong.hello()[..39]
                .iter()
                .enumerate()
                .map(|(i, b)| if i == 6 { host.hello()[6] } else { *b })
                .collect::<Vec<u8>>()[..]
        );
        assert_ne!(host.hello()[39..], wrong.hello()[39..]);
    }
}
