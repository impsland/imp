//! The small constructions the link is made of: keys derived with HMAC-SHA256 and a label, the join
//! proof, ticket hashes and comparisons that take the same time whatever they find.

use hmac::{Hmac, KeyInit, Mac};
use sha2::{Digest, Sha256};

/// The size of every key, door, invite and ticket in bytes.
pub const KEY_BYTES: usize = 32;

/// 32 bytes of key material.
pub type Key = [u8; KEY_BYTES];

/// 32 random bytes: a seed, a door key, an invite key or a ticket.
pub fn random_key() -> Key {
    rand::random()
}

/// A random id for a device, an Imp's transfer or a question.
pub fn new_id() -> uuid::Uuid {
    uuid::Builder::from_random_bytes(rand::random()).into_uuid()
}

fn mac(key: &[u8], parts: &[&[u8]]) -> Hmac<Sha256> {
    let mut mac = <Hmac<Sha256> as KeyInit>::new_from_slice(key).expect("HMAC takes any key size");
    for part in parts {
        mac.update(part);
    }
    mac
}

fn tag(key: &[u8], parts: &[&[u8]]) -> Key {
    mac(key, parts).finalize().into_bytes().into()
}

/// The Noise pre-shared key: derived from the door key, never the door key itself.
pub fn psk(door: &Key) -> Key {
    tag(door, &[b"imp-link psk"])
}

/// The seed of the key every guest derives from the door key to sign at the Hop.
pub fn gate_seed(door: &Key) -> Key {
    tag(door, &[b"imp-hop gate"])
}

/// The secret of the device's Noise static key, derived from its seed.
pub(crate) fn noise_secret(seed: &Key) -> Key {
    tag(seed, &[b"imp-link noise static"])
}

/// The seed of the device's Hop signing key, derived from its seed.
pub(crate) fn room_seed(seed: &Key) -> Key {
    tag(seed, &[b"imp-link hop room"])
}

/// The guest's proof that it holds a fresh invite. It covers the handshake hash, so it is only good on
/// the connection it was made on.
pub fn join_proof(invite: &Key, handshake_hash: &[u8]) -> Key {
    tag(invite, &[b"imp-link join", handshake_hash])
}

/// Whether `proof` is the join proof for `invite` on the connection with this handshake hash.
pub fn is_valid_join(proof: &[u8], invite: &Key, handshake_hash: &[u8]) -> bool {
    mac(invite, &[b"imp-link join", handshake_hash])
        .verify_slice(proof)
        .is_ok()
}

/// What the home keeps of a ticket, so a stolen book does not hold working tickets.
pub fn ticket_hash(ticket: &[u8]) -> Key {
    let mut hash = Sha256::new();
    hash.update(b"imp-link ticket");
    hash.update(ticket);
    hash.finalize().into()
}

/// Whether `ticket` is the one `hash` stands for.
pub fn ticket_matches(ticket: &[u8], hash: &[u8]) -> bool {
    equal(&ticket_hash(ticket), hash)
}

/// Compares secrets without stopping at the first difference.
pub fn equal(a: &[u8], b: &[u8]) -> bool {
    a.len() == b.len() && a.iter().zip(b).fold(0u8, |d, (x, y)| d | (x ^ y)) == 0
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn labels_keep_every_derived_key_apart() {
        let k = [7u8; 32];
        let all = [
            psk(&k),
            gate_seed(&k),
            noise_secret(&k),
            room_seed(&k),
            join_proof(&k, b"h"),
            ticket_hash(&k),
        ];
        for (i, a) in all.iter().enumerate() {
            for b in &all[i + 1..] {
                assert_ne!(a, b);
            }
        }
    }

    #[test]
    fn join_proofs_are_bound_to_the_invite_and_the_connection() {
        let invite = [1u8; 32];
        let proof = join_proof(&invite, b"hash one");
        assert!(is_valid_join(&proof, &invite, b"hash one"));
        assert!(!is_valid_join(&proof, &invite, b"hash two"));
        assert!(!is_valid_join(&proof, &[2u8; 32], b"hash one"));
        assert!(!is_valid_join(&proof[..31], &invite, b"hash one"));
    }

    #[test]
    fn tickets_are_stored_as_hashes() {
        let ticket = random_key();
        let hash = ticket_hash(&ticket);
        assert_ne!(ticket, hash);
        assert!(ticket_matches(&ticket, &hash));
        assert!(!ticket_matches(&random_key(), &hash));
        assert!(!equal(b"ab", b"abc"));
        assert!(equal(b"", b""));
    }
}
