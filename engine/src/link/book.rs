//! Everything a device remembers about its links: its identity seed, its door key, the invite on show,
//! its links, the Imps visiting it and the Imps of its own that are away. It holds secrets, so the adapter
//! keeps it where only this user can read it (a file with private permissions, the Keychain) and never
//! logs it. It is written as JSON.

use crate::link::card::{LinkCard, LinkDevice, LinkRoutes};
use crate::link::crypto::KEY_BYTES;
use crate::link::ledger::AwayLedger;
use crate::link::messages::{Bytes, LinkWho};
use crate::link::visits::Visits;
use serde::{Deserialize, Serialize};
use uuid::Uuid;

/// A device this one has a link with: who it is (its key is pinned) and how to dial it.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct LinkRecord {
    pub device: LinkDevice,
    /// Its door key, which opens its handshake. Unknown until it tells us (a device that scanned our code).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub door: Option<Bytes>,
    pub routes: LinkRoutes,
    /// Seconds since 1970.
    pub since: f64,
    /// One of the owner's own devices. Never by default.
    #[serde(default)]
    pub trusted: bool,
}

impl LinkRecord {
    pub fn id(&self) -> Uuid {
        self.device.id
    }

    /// What it takes to dial this device, if we know its door key.
    pub fn card(&self) -> Option<LinkCard> {
        let door = self.door.clone()?;
        Some(LinkCard {
            device: self.device.clone(),
            door,
            routes: self.routes.clone(),
        })
    }
}

/// A throw of an Imp of this device, sent and not answered.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Passing {
    pub transfer: Uuid,
    pub imp: Uuid,
    pub to: Uuid,
}

/// A visiting Imp this device passed on, whose home has not heard yet (`moved`).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Handed {
    pub imp: Uuid,
    pub home: Uuid,
    pub to: LinkWho,
}

/// The most hand-overs kept waiting for their homes.
pub const MAX_HANDED: usize = 64;

#[derive(Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct LinkBook {
    pub device: Uuid,
    /// The identity seed's raw bytes.
    pub seed: Bytes,
    /// Opens this device's handshakes. New when it forgets everyone.
    pub door: Bytes,
    /// The invite key on show, and when the code was last on screen (seconds since 1970).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub invite: Option<Bytes>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub invite_shown: Option<f64>,
    pub links: Vec<LinkRecord>,
    pub visits: Visits,
    pub away: AwayLedger,
    /// Throws of this device's own Imps that no answer came for yet: after a restart they are called
    /// home, so a receiver that did take one hears `gone` when it claims.
    #[serde(default)]
    pub passing: Vec<Passing>,
    /// Visiting Imps passed on that their homes have not been told about yet.
    pub handed: Vec<Handed>,
}

/// The book cannot be read.
#[derive(Debug, Clone, Copy, PartialEq, Eq, thiserror::Error)]
#[error("the link book is damaged")]
pub struct BookError;

impl LinkBook {
    pub fn new(device: Uuid, seed: [u8; KEY_BYTES], door: [u8; KEY_BYTES]) -> Self {
        Self {
            device,
            seed: seed.to_vec().into(),
            door: door.to_vec().into(),
            invite: None,
            invite_shown: None,
            links: Vec::new(),
            visits: Visits::default(),
            away: AwayLedger::default(),
            passing: Vec::new(),
            handed: Vec::new(),
        }
    }

    /// Reads a saved book. The keys must be whole.
    pub fn read(bytes: &[u8]) -> Result<Self, BookError> {
        let book: Self = serde_json::from_slice(bytes).map_err(|_| BookError)?;
        let whole = book.seed.is_key()
            && book.door.is_key()
            && book.invite.as_ref().is_none_or(Bytes::is_key)
            && book
                .links
                .iter()
                .all(|l| l.door.as_ref().is_none_or(Bytes::is_key));
        whole.then_some(book).ok_or(BookError)
    }

    pub fn write(&self) -> Vec<u8> {
        serde_json::to_vec(self).unwrap_or_default()
    }
}

impl std::fmt::Debug for LinkBook {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(
            f,
            "LinkBook({} links, {} visits, {} away)",
            self.links.len(),
            self.visits.visits().len(),
            self.away.entries().len()
        )
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::link::visits::tests::{card, imp};

    #[test]
    fn a_book_round_trips_with_everything_in_it() {
        let mut book = LinkBook::new(Uuid::from_u128(1), [1; 32], [2; 32]);
        book.invite = Some(vec![3; 32].into());
        book.invite_shown = Some(1_700_000_000.5);
        book.links.push(LinkRecord {
            device: card(10, 4).device,
            door: Some(vec![5; 32].into()),
            routes: LinkRoutes::none(),
            since: 1.0,
            trusted: true,
        });
        book.visits.arrive(
            &imp(7),
            &crate::link::messages::LinkEntry::new(crate::link::messages::LinkSide::Left, 0.5, 0.0),
            Uuid::from_u128(10),
            &card(10, 4),
            &[9; 32],
        );
        book.away.mint(Uuid::from_u128(8), Uuid::from_u128(10));
        book.passing.push(Passing {
            transfer: Uuid::from_u128(20),
            imp: Uuid::from_u128(8),
            to: Uuid::from_u128(10),
        });
        assert_eq!(LinkBook::read(&book.write()), Ok(book));
    }

    #[test]
    fn a_damaged_book_is_refused_not_trusted() {
        let book = LinkBook::new(Uuid::nil(), [1; 32], [2; 32]);
        assert!(LinkBook::read(&book.write()).is_ok());
        assert!(LinkBook::read(b"nope").is_err());
        assert!(LinkBook::read(b"{}").is_err());
        let mut short = book.clone();
        short.seed = vec![1; 5].into();
        assert!(LinkBook::read(&short.write()).is_err());
        let mut short = book;
        short.invite = Some(vec![1; 5].into());
        assert!(LinkBook::read(&short.write()).is_err());
    }

    #[test]
    fn a_record_without_trust_is_untrusted_and_the_book_never_prints_secrets() {
        let json = serde_json::json!({
            "device": serde_json::to_value(card(10, 4).device).unwrap(),
            "routes": {"hosts": [], "port": 47824},
            "since": 5.0
        });
        let record: LinkRecord = serde_json::from_value(json).unwrap();
        assert!(!record.trusted && record.door.is_none() && record.card().is_none());
        let book = LinkBook::new(Uuid::nil(), [1; 32], [2; 32]);
        assert_eq!(format!("{book:?}"), "LinkBook(0 links, 0 visits, 0 away)");
    }
}
