//! The secure session: a Noise handshake and the encrypted stream it opens.
//!
//! The pattern is `Noise_IKpsk2_25519_ChaChaPoly_BLAKE2s` (see `docs/architecture/threat-model.md`). The
//! guest knows the host's static key, the pre-shared key comes from the door key, and the prologue names
//! the protocol, so a device that speaks something else fails the handshake cleanly.
//!
//! On the wire every handshake message and every encrypted chunk is a 2-byte big endian length and that
//! many bytes (a Noise message is at most 65 535 bytes). A frame of any size is cut into chunks.

use crate::link::crypto::Key;
use snow::{Builder, HandshakeState, TransportState};

/// The Noise protocol name.
pub const PROTOCOL: &str = "Noise_IKpsk2_25519_ChaChaPoly_BLAKE2s";
/// Mixed into the handshake hash: both sides must agree on it or the handshake fails.
const PROLOGUE: &[u8] = b"imp-link";
/// The most plaintext one chunk carries: a Noise message holds 65 535 bytes with its 16-byte tag.
pub const CHUNK: usize = 65_535 - 16;
const TAG: usize = 16;

/// Something went wrong that a hostile or an older peer can cause. The connection is closed.
#[derive(Debug, Clone, Copy, PartialEq, Eq, thiserror::Error)]
pub enum NoiseError {
    #[error("the handshake failed")]
    Handshake,
    #[error("an encrypted message did not check out")]
    Decrypt,
}

/// What a finished handshake gives.
pub struct Established {
    /// The encrypted stream.
    pub secure: Secure,
    /// Both sides derive this value and nobody else can: what the join proof covers.
    pub hash: Vec<u8>,
    /// The other side's static public key, as the handshake proved it.
    pub remote_static: Key,
}

/// The result of reading a handshake message.
pub struct Progress {
    /// A handshake message to send, already with its length.
    pub reply: Option<Vec<u8>>,
    pub established: Option<Established>,
}

pub struct Handshake {
    state: Option<HandshakeState>,
}

fn builder<'a>(secret: &'a Key, psk: &'a Key) -> Result<Builder<'a>, NoiseError> {
    let params = PROTOCOL.parse().map_err(|_| NoiseError::Handshake)?;
    Builder::new(params)
        .local_private_key(secret)
        .and_then(|b| b.psk(2, psk))
        .and_then(|b| b.prologue(PROLOGUE))
        .map_err(|_| NoiseError::Handshake)
}

fn prefixed(message: &[u8]) -> Vec<u8> {
    let mut out = Vec::with_capacity(2 + message.len());
    out.extend_from_slice(&(message.len() as u16).to_be_bytes());
    out.extend_from_slice(message);
    out
}

impl Handshake {
    /// The guest's side: returns the first message to send.
    pub fn initiator(secret: &Key, host: &Key, psk: &Key) -> Result<(Self, Vec<u8>), NoiseError> {
        Self::initiator_with(builder(secret, psk)?, host)
    }

    fn initiator_with(builder: Builder<'_>, host: &Key) -> Result<(Self, Vec<u8>), NoiseError> {
        let mut state = builder
            .remote_public_key(host)
            .map_err(|_| NoiseError::Handshake)?
            .build_initiator()
            .map_err(|_| NoiseError::Handshake)?;
        let mut message = [0u8; 256];
        let n = state
            .write_message(&[], &mut message)
            .map_err(|_| NoiseError::Handshake)?;
        Ok((Self { state: Some(state) }, prefixed(&message[..n])))
    }

    /// The host's side.
    pub fn responder(secret: &Key, psk: &Key) -> Result<Self, NoiseError> {
        let state = builder(secret, psk)?
            .build_responder()
            .map_err(|_| NoiseError::Handshake)?;
        Ok(Self { state: Some(state) })
    }

    /// Reads the next handshake message (without its length).
    pub fn read(&mut self, message: &[u8]) -> Result<Progress, NoiseError> {
        let mut state = self.state.take().ok_or(NoiseError::Handshake)?;
        let mut sink = [0u8; 256];
        state
            .read_message(message, &mut sink)
            .map_err(|_| NoiseError::Handshake)?;
        let mut reply = None;
        if !state.is_handshake_finished() {
            let mut out = [0u8; 256];
            let n = state
                .write_message(&[], &mut out)
                .map_err(|_| NoiseError::Handshake)?;
            reply = Some(prefixed(&out[..n]));
        }
        if !state.is_handshake_finished() {
            self.state = Some(state);
            return Ok(Progress {
                reply,
                established: None,
            });
        }
        let hash = state.get_handshake_hash().to_vec();
        let remote_static: Key = state
            .get_remote_static()
            .and_then(|k| k.try_into().ok())
            .ok_or(NoiseError::Handshake)?;
        let transport = state
            .into_transport_mode()
            .map_err(|_| NoiseError::Handshake)?;
        Ok(Progress {
            reply,
            established: Some(Established {
                secure: Secure { transport },
                hash,
                remote_static,
            }),
        })
    }
}

/// The encrypted stream after the handshake.
pub struct Secure {
    transport: TransportState,
}

impl Secure {
    /// Encrypts `plaintext` into as many chunks as it needs, each with its length. Send the result as is.
    pub fn seal(&mut self, plaintext: &[u8]) -> Result<Vec<u8>, NoiseError> {
        let mut out =
            Vec::with_capacity(plaintext.len() + plaintext.len() / CHUNK * (TAG + 2) + TAG + 2);
        let mut buffer = vec![0u8; CHUNK + TAG];
        for part in plaintext.chunks(CHUNK) {
            let n = self
                .transport
                .write_message(part, &mut buffer)
                .map_err(|_| NoiseError::Decrypt)?;
            out.extend_from_slice(&prefixed(&buffer[..n]));
        }
        Ok(out)
    }

    /// Decrypts one chunk (without its length).
    pub fn open(&mut self, chunk: &[u8]) -> Result<Vec<u8>, NoiseError> {
        if chunk.len() < TAG {
            return Err(NoiseError::Decrypt);
        }
        let mut out = vec![0u8; chunk.len()];
        let n = self
            .transport
            .read_message(chunk, &mut out)
            .map_err(|_| NoiseError::Decrypt)?;
        out.truncate(n);
        Ok(out)
    }
}

/// Collects the raw bytes of a connection and hands back whole messages (without their length).
#[derive(Debug, Default)]
pub struct ChunkReader {
    buffer: Vec<u8>,
}

impl ChunkReader {
    pub fn feed(&mut self, data: &[u8]) -> Vec<Vec<u8>> {
        self.buffer.extend_from_slice(data);
        let mut messages = Vec::new();
        let mut start = 0;
        while self.buffer.len() - start >= 2 {
            let length = usize::from(u16::from_be_bytes([
                self.buffer[start],
                self.buffer[start + 1],
            ]));
            if self.buffer.len() - start < 2 + length {
                break;
            }
            messages.push(self.buffer[start + 2..start + 2 + length].to_vec());
            start += 2 + length;
        }
        self.buffer.drain(..start);
        messages
    }

    /// Bytes that arrived after the last whole message.
    pub fn pending(&self) -> usize {
        self.buffer.len()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::link::card::LinkKind;
    use crate::link::crypto::{psk, random_key};
    use crate::link::identity::Identity;
    use uuid::Uuid;

    fn pair() -> (Identity, Identity) {
        (
            Identity::from_seed(Uuid::from_u128(1), "Host", LinkKind::Mac, [1; 32]),
            Identity::from_seed(Uuid::from_u128(2), "Guest", LinkKind::Phone, [2; 32]),
        )
    }

    fn connect(
        host: &Identity,
        guest: &Identity,
        door: &Key,
        guest_door: &Key,
    ) -> Result<(Established, Established), NoiseError> {
        let (mut g, first) =
            Handshake::initiator(&guest.noise_secret(), &host.key(), &psk(guest_door))?;
        let mut h = Handshake::responder(&host.noise_secret(), &psk(door))?;
        let mut reader = ChunkReader::default();
        let message = reader.feed(&first).remove(0);
        let host_side = h.read(&message)?;
        let mut reader = ChunkReader::default();
        let message = reader.feed(&host_side.reply.unwrap()).remove(0);
        let guest_side = g.read(&message)?;
        Ok((
            host_side.established.unwrap(),
            guest_side.established.unwrap(),
        ))
    }

    #[test]
    fn both_sides_learn_the_same_hash_and_each_others_keys() {
        let (host, guest) = pair();
        let door = random_key();
        let (h, g) = connect(&host, &guest, &door, &door).unwrap();
        assert_eq!(h.hash, g.hash);
        assert_eq!(h.remote_static, guest.key());
        assert_eq!(g.remote_static, host.key());
    }

    #[test]
    fn a_wrong_door_key_fails_the_handshake() {
        let (host, guest) = pair();
        assert!(connect(&host, &guest, &random_key(), &random_key()).is_err());
    }

    #[test]
    fn the_wrong_host_key_fails_the_handshake() {
        let (host, guest) = pair();
        let impostor = Identity::from_seed(Uuid::from_u128(1), "Host", LinkKind::Mac, [9; 32]);
        let door = random_key();
        let (_, first) =
            Handshake::initiator(&guest.noise_secret(), &host.key(), &psk(&door)).unwrap();
        let mut h = Handshake::responder(&impostor.noise_secret(), &psk(&door)).unwrap();
        let message = ChunkReader::default().feed(&first).remove(0);
        assert!(h.read(&message).is_err());
    }

    #[test]
    fn frames_of_any_size_cross_in_chunks_and_replays_fail() {
        let (host, guest) = pair();
        let door = random_key();
        let (mut h, mut g) = connect(&host, &guest, &door, &door).unwrap();
        let big: Vec<u8> = (0..200_000u32).map(|n| (n % 251) as u8).collect();
        let wire = g.secure.seal(&big).unwrap();
        let mut reader = ChunkReader::default();
        let mut got = Vec::new();
        let mut chunks = Vec::new();
        for piece in wire.chunks(777) {
            chunks.extend(reader.feed(piece));
        }
        assert_eq!(chunks.len(), 4);
        for chunk in &chunks {
            got.extend(h.secure.open(chunk).unwrap());
        }
        assert_eq!(got, big);
        // The same chunk again, and a changed chunk, do not open.
        assert!(h.secure.open(&chunks[0]).is_err());
        let wire = g.secure.seal(b"hello").unwrap();
        let mut chunk = ChunkReader::default().feed(&wire).remove(0);
        chunk[3] ^= 1;
        assert!(h.secure.open(&chunk).is_err());
        assert!(h.secure.open(&[1, 2, 3]).is_err());
    }

    #[test]
    fn nothing_flows_in_the_clear() {
        let (host, guest) = pair();
        let door = random_key();
        let (_, mut g) = connect(&host, &guest, &door, &door).unwrap();
        let wire = g.secure.seal(b"a secret question").unwrap();
        assert!(!wire.windows(6).any(|w| w == b"secret"));
    }

    #[test]
    fn another_protocol_name_would_not_complete() {
        // The protocol name and the prologue are mixed into the hash: a device with other labels fails.
        let (host, guest) = pair();
        let door = random_key();
        let params = "Noise_IKpsk2_25519_ChaChaPoly_BLAKE2b".parse().unwrap();
        let secret = guest.noise_secret();
        let key = psk(&door);
        let (_, first) = Handshake::initiator_with(
            Builder::new(params)
                .local_private_key(&secret)
                .unwrap()
                .psk(2, &key)
                .unwrap()
                .prologue(PROLOGUE)
                .unwrap(),
            &host.key(),
        )
        .unwrap();
        let mut h = Handshake::responder(&host.noise_secret(), &psk(&door)).unwrap();
        assert!(
            h.read(&ChunkReader::default().feed(&first).remove(0))
                .is_err()
        );
    }

    #[test]
    fn the_chunk_reader_waits_for_whole_messages() {
        let mut reader = ChunkReader::default();
        assert!(reader.feed(&[0]).is_empty());
        assert!(reader.feed(&[3, 1, 2]).is_empty());
        assert_eq!(reader.feed(&[3, 0, 0]), vec![vec![1, 2, 3], vec![]]);
        assert_eq!(reader.pending(), 0);
    }
}
