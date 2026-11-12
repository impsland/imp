//! This device: its id, name and kind, and the one secret seed that never leaves it. Two keys come
//! from the seed, each with its own label: the Noise static key other devices pin, and the Ed25519 key
//! that names the device's room at the Hop.

use crate::link::card::{LinkDevice, LinkKind};
use crate::link::crypto::{self, Key};
use ed25519_dalek::SigningKey;
use snow::params::DHChoice;
use snow::resolvers::{CryptoResolver, DefaultResolver};
use uuid::Uuid;

pub struct Identity {
    id: Uuid,
    name: String,
    kind: LinkKind,
    seed: Key,
    noise_public: Key,
}

impl Identity {
    /// A new identity with a fresh seed.
    pub fn new(id: Uuid, name: &str, kind: LinkKind) -> Self {
        Self::from_seed(id, name, kind, crypto::random_key())
    }

    /// Rebuilds an identity from its seed.
    pub fn from_seed(id: Uuid, name: &str, kind: LinkKind, seed: Key) -> Self {
        let mut dh = DefaultResolver
            .resolve_dh(&DHChoice::Curve25519)
            .expect("the default resolver has X25519");
        dh.set(&crypto::noise_secret(&seed));
        let mut noise_public = [0u8; 32];
        noise_public.copy_from_slice(dh.pubkey());
        Self {
            id,
            name: LinkDevice::cleaned(name, kind),
            kind,
            seed,
            noise_public,
        }
    }

    pub fn id(&self) -> Uuid {
        self.id
    }

    pub fn name(&self) -> &str {
        &self.name
    }

    pub fn kind(&self) -> LinkKind {
        self.kind
    }

    pub fn rename(&mut self, name: &str) {
        self.name = LinkDevice::cleaned(name, self.kind);
    }

    /// The seed's bytes, for the book. Never log them.
    pub(crate) fn seed(&self) -> &Key {
        &self.seed
    }

    /// The Noise static secret.
    pub(crate) fn noise_secret(&self) -> Key {
        crypto::noise_secret(&self.seed)
    }

    /// The Noise static public key other devices pin.
    pub fn key(&self) -> Key {
        self.noise_public
    }

    pub(crate) fn room_signer(&self) -> SigningKey {
        SigningKey::from_bytes(&crypto::room_seed(&self.seed))
    }

    /// The Ed25519 public key that names this device's room at the Hop.
    pub fn room_key(&self) -> Key {
        self.room_signer().verifying_key().to_bytes()
    }

    /// This device as others see it. Public things only.
    pub fn device(&self) -> LinkDevice {
        LinkDevice {
            id: self.id,
            name: self.name.clone(),
            kind: self.kind,
            key: self.noise_public.to_vec().into(),
            room: self.room_key().to_vec().into(),
        }
    }
}

impl std::fmt::Debug for Identity {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Identity")
            .field("id", &self.id)
            .field("name", &self.name)
            .field("kind", &self.kind)
            .finish_non_exhaustive()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn one_seed_makes_two_different_keys_and_the_same_ones_every_time() {
        let a = Identity::from_seed(Uuid::nil(), "Mac", LinkKind::Mac, [1; 32]);
        let b = Identity::from_seed(Uuid::nil(), "Mac", LinkKind::Mac, [1; 32]);
        assert_eq!(a.key(), b.key());
        assert_eq!(a.room_key(), b.room_key());
        assert_ne!(a.key(), a.room_key());
        assert_ne!(
            a.key(),
            Identity::from_seed(Uuid::nil(), "Mac", LinkKind::Mac, [2; 32]).key()
        );
    }

    #[test]
    fn names_are_cleaned_and_never_empty() {
        let id = Uuid::nil();
        assert_eq!(Identity::new(id, "   ", LinkKind::Mac).name(), "Mac");
        assert_eq!(Identity::new(id, "", LinkKind::Phone).name(), "iPhone");
        assert_eq!(
            Identity::new(id, &"x".repeat(200), LinkKind::Mac)
                .name()
                .chars()
                .count(),
            80
        );
        assert_eq!(
            Identity::new(id, "  Art's Mac \n", LinkKind::Mac).name(),
            "Art's Mac"
        );
    }

    #[test]
    fn debug_hides_the_seed() {
        let shown = format!(
            "{:?}",
            Identity::from_seed(Uuid::nil(), "Mac", LinkKind::Mac, [1; 32])
        );
        assert!(!shown.contains("seed"));
    }
}
