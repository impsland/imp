//! The home's record of its Imps that are away (`docs/connecting/link.md`, "Tickets"): who holds each one
//! and a hash of its current ticket. The home is the source of truth: a holder is only a holder while
//! this says so. Pure, so the races can be tested without a network.

use crate::link::card::{LinkDevice, LinkKind};
use crate::link::crypto::{self, Key};
use crate::link::messages::Bytes;
use serde::{Deserialize, Serialize};
use uuid::Uuid;

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct AwayEntry {
    pub imp: Uuid,
    pub holder: Uuid,
    /// `crypto::ticket_hash` of the current ticket.
    pub ticket: Bytes,
    /// Counts every new holder or ticket, so a stale answer can be told from a fresh one.
    pub generation: u64,
    /// The hash of the ticket the holder had before its last claim. A `claimed` lost when a connection
    /// drops leaves the holder with that one, so it is still good from the same holder, until the next
    /// claim proves the new ticket arrived. Not written while there is none.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub previous: Option<Bytes>,
    /// Who the holder is, when it is a device this one is not linked with: the holder told us it handed the
    /// Imp on (`moved`). Gone with the next claim, which the new holder makes itself.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub elsewhere: Option<Elsewhere>,
}

/// A holder this device only knows through the device that passed the Imp on to it.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Elsewhere {
    pub name: String,
    pub kind: LinkKind,
    /// The device that said so: it held the Imp before.
    pub via: Uuid,
}

impl AwayEntry {
    /// Whether `device` claims again with the ticket it had before its last claim.
    fn retries(&self, ticket: &[u8], device: Uuid) -> bool {
        device == self.holder
            && self
                .previous
                .as_ref()
                .is_some_and(|p| crypto::ticket_matches(ticket, &p.0))
    }
}

/// A holder to be told `gone` when it next connects.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Notice {
    pub device: Uuid,
    pub imp: Uuid,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Claim {
    /// The claimant is the holder now, with this new ticket. `previous` (if any) is to be told `gone`.
    Granted { ticket: Key, previous: Option<Uuid> },
    /// Not the current ticket (stale, wrong, or the Imp is not away): the claimant's body must go.
    Refused,
}

#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
pub struct AwayLedger {
    entries: Vec<AwayEntry>,
    notices: Vec<Notice>,
}

impl AwayLedger {
    pub fn entries(&self) -> &[AwayEntry] {
        &self.entries
    }

    pub fn notices(&self) -> &[Notice] {
        &self.notices
    }

    pub fn entry(&self, imp: Uuid) -> Option<&AwayEntry> {
        self.entries.iter().find(|e| e.imp == imp)
    }

    pub fn holder(&self, imp: Uuid) -> Option<Uuid> {
        self.entry(imp).map(|e| e.holder)
    }

    pub fn is_away(&self, imp: Uuid) -> bool {
        self.entry(imp).is_some()
    }

    /// The Imps `device` holds.
    pub fn held_by(&self, device: Uuid) -> Vec<Uuid> {
        self.entries
            .iter()
            .filter(|e| e.holder == device)
            .map(|e| e.imp)
            .collect()
    }

    /// Whether `device` may act for `imp` (ask, stop, fetch files): only its current holder.
    pub fn authorises(&self, device: Uuid, imp: Uuid) -> bool {
        self.holder(imp) == Some(device)
    }

    /// The home passes its own Imp to `holder`: a new ticket, and the receiver is the holder.
    pub fn mint(&mut self, imp: Uuid, holder: Uuid) -> Key {
        let ticket = crypto::random_key();
        let generation = self.entry(imp).map_or(0, |e| e.generation) + 1;
        if let Some(previous) = self.holder(imp).filter(|p| *p != holder) {
            self.tell(previous, imp);
        }
        self.entries.retain(|e| e.imp != imp);
        self.entries.push(AwayEntry {
            imp,
            holder,
            ticket: crypto::ticket_hash(&ticket).to_vec().into(),
            generation,
            previous: None,
            elsewhere: None,
        });
        ticket
    }

    /// The holder `from` says it handed the Imp on to `to`. Heard only from the current holder. The ticket
    /// went along with the Imp, so it stays. The previous holder has nothing to be told. True if it changed.
    pub fn moved(&mut self, imp: Uuid, from: Uuid, to: Uuid, name: &str, kind: LinkKind) -> bool {
        let Some(entry) = self
            .entries
            .iter_mut()
            .find(|e| e.imp == imp && e.holder == from)
        else {
            return false;
        };
        if to == from {
            return false;
        }
        entry.holder = to;
        entry.previous = None;
        entry.elsewhere = Some(Elsewhere {
            name: LinkDevice::cleaned(name, kind),
            kind,
            via: from,
        });
        true
    }

    /// A holder says it has the Imp, with the ticket it was given. A good claim makes it the holder,
    /// rotates the ticket, and queues `gone` for the previous holder. The holder itself may also claim
    /// with the ticket it had before its last claim, in case the `claimed` with the new one was lost.
    pub fn claim(&mut self, imp: Uuid, ticket: &[u8], device: Uuid) -> Claim {
        let Some(i) = self.entries.iter().position(|e| e.imp == imp) else {
            return Claim::Refused;
        };
        let current = crypto::ticket_matches(ticket, &self.entries[i].ticket.0);
        if !current && !self.entries[i].retries(ticket, device) {
            return Claim::Refused;
        }
        let previous = Some(self.entries[i].holder).filter(|p| *p != device);
        let fresh = crypto::random_key();
        let entry = &mut self.entries[i];
        // What the holder has stays good for it until it claims with the newest: the ticket being
        // replaced, or (when it claimed with an older one) that older one still.
        entry.previous = match (previous.is_none(), current) {
            (true, true) => Some(entry.ticket.clone()),
            (true, false) => entry.previous.clone(),
            (false, _) => None,
        };
        entry.holder = device;
        entry.elsewhere = None;
        entry.ticket = crypto::ticket_hash(&fresh).to_vec().into();
        entry.generation += 1;
        if let Some(previous) = previous {
            self.tell(previous, imp);
        }
        Claim::Granted {
            ticket: fresh,
            previous,
        }
    }

    /// A holder sends the Imp home with its ticket (or the one before, see [`AwayLedger::claim`]). True
    /// if the ticket was good (the Imp is home now).
    pub fn release(&mut self, imp: Uuid, ticket: &[u8]) -> bool {
        let good = self.entry(imp).is_some_and(|e| {
            crypto::ticket_matches(ticket, &e.ticket.0) || e.retries(ticket, e.holder)
        });
        if good {
            self.entries.retain(|e| e.imp != imp);
        }
        good
    }

    /// The home takes its Imp back at any time: the ticket dies and the holder is told `gone`.
    /// Returns the holder, if it was away.
    pub fn call_home(&mut self, imp: Uuid) -> Option<Uuid> {
        let holder = self.holder(imp)?;
        self.entries.retain(|e| e.imp != imp);
        self.tell(holder, imp);
        Some(holder)
    }

    /// Takes back every Imp `device` holds (it was forgotten). Returns them.
    pub fn call_home_from(&mut self, device: Uuid) -> Vec<Uuid> {
        self.held_by(device)
            .into_iter()
            .filter(|imp| self.call_home(*imp).is_some())
            .collect()
    }

    /// The Imp came home by itself: its ticket dies and nobody is told.
    pub fn came_home(&mut self, imp: Uuid) {
        self.entries.retain(|e| e.imp != imp);
    }

    /// What `device` has to be told, now that it is connected. Taken once.
    pub fn take_notices(&mut self, device: Uuid) -> Vec<Uuid> {
        let mine = self
            .notices
            .iter()
            .filter(|n| n.device == device)
            .map(|n| n.imp)
            .collect();
        self.notices.retain(|n| n.device != device);
        mine
    }

    /// Stops owing `device` any news (it was forgotten).
    pub fn drop_notices(&mut self, device: Uuid) {
        self.notices.retain(|n| n.device != device);
    }

    fn tell(&mut self, device: Uuid, imp: Uuid) {
        let notice = Notice { device, imp };
        if !self.notices.contains(&notice) {
            self.notices.push(notice);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn id(n: u128) -> Uuid {
        Uuid::from_u128(n)
    }

    #[test]
    fn minting_makes_the_receiver_the_holder_and_stores_only_a_hash() {
        let mut ledger = AwayLedger::default();
        let ticket = ledger.mint(id(1), id(10));
        assert!(ledger.authorises(id(10), id(1)));
        assert!(!ledger.authorises(id(11), id(1)));
        assert_eq!(ledger.held_by(id(10)), vec![id(1)]);
        assert_ne!(ledger.entry(id(1)).unwrap().ticket.0, ticket.to_vec());
        assert_eq!(ledger.entry(id(1)).unwrap().generation, 1);
        // Passed again to another device: the first is told.
        ledger.mint(id(1), id(11));
        assert_eq!(ledger.entry(id(1)).unwrap().generation, 2);
        assert_eq!(ledger.take_notices(id(10)), vec![id(1)]);
        assert!(ledger.take_notices(id(10)).is_empty());
    }

    #[test]
    fn a_good_claim_rotates_the_ticket_and_a_stale_one_is_refused() {
        let mut ledger = AwayLedger::default();
        let first = ledger.mint(id(1), id(10));
        let Claim::Granted {
            ticket: second,
            previous,
        } = ledger.claim(id(1), &first, id(11))
        else {
            panic!("the first claim is good");
        };
        assert_eq!(previous, Some(id(10)));
        assert_eq!(ledger.holder(id(1)), Some(id(11)));
        assert_eq!(ledger.claim(id(1), &first, id(10)), Claim::Refused);
        assert_eq!(ledger.claim(id(2), &second, id(11)), Claim::Refused);
        assert_eq!(ledger.take_notices(id(10)), vec![id(1)]);
        // The holder claiming again with its own ticket is not told anything.
        let Claim::Granted { previous, .. } = ledger.claim(id(1), &second, id(11)) else {
            panic!("the current ticket is good");
        };
        assert_eq!(previous, None);
        assert!(ledger.notices().is_empty());
    }

    #[test]
    fn release_needs_the_current_ticket() {
        let mut ledger = AwayLedger::default();
        let ticket = ledger.mint(id(1), id(10));
        assert!(!ledger.release(id(1), &[0; 32]));
        assert!(ledger.is_away(id(1)));
        assert!(ledger.release(id(1), &ticket));
        assert!(!ledger.is_away(id(1)));
        assert!(!ledger.release(id(1), &ticket));
    }

    #[test]
    fn calling_home_kills_the_ticket_and_tells_the_holder() {
        let mut ledger = AwayLedger::default();
        let ticket = ledger.mint(id(1), id(10));
        ledger.mint(id(2), id(10));
        ledger.mint(id(3), id(11));
        assert_eq!(ledger.call_home(id(1)), Some(id(10)));
        assert_eq!(ledger.call_home(id(1)), None);
        assert_eq!(ledger.claim(id(1), &ticket, id(10)), Claim::Refused);
        assert_eq!(ledger.call_home_from(id(10)), vec![id(2)]);
        assert_eq!(ledger.take_notices(id(10)), vec![id(1), id(2)]);
        ledger.came_home(id(3));
        assert!(ledger.entries().is_empty());
        assert!(ledger.take_notices(id(11)).is_empty());
        ledger.mint(id(4), id(12));
        ledger.call_home(id(4));
        ledger.drop_notices(id(12));
        assert!(ledger.notices().is_empty());
    }

    #[test]
    fn the_same_notice_is_not_queued_twice() {
        let mut ledger = AwayLedger::default();
        ledger.mint(id(1), id(10));
        ledger.mint(id(1), id(11));
        ledger.mint(id(1), id(10));
        ledger.mint(id(1), id(11));
        assert_eq!(ledger.notices().len(), 2);
    }

    #[test]
    fn only_the_holder_is_authorised() {
        let mut ledger = AwayLedger::default();
        ledger.mint(id(1), id(10));
        assert!(ledger.authorises(id(10), id(1)));
        assert!(!ledger.authorises(id(11), id(1)) && !ledger.authorises(id(10), id(2)));
        assert!(!AwayLedger::default().authorises(id(10), id(1)));
    }

    #[test]
    fn the_newest_holder_wins_and_two_claims_with_one_ticket_grant_only_the_first() {
        let mut ledger = AwayLedger::default();
        let ticket = ledger.mint(id(1), id(10));
        let Claim::Granted { ticket: second, .. } = ledger.claim(id(1), &ticket, id(11)) else {
            panic!("first claim is good");
        };
        assert_ne!(second, ticket);
        assert_eq!(ledger.entry(id(1)).unwrap().generation, 2);
        assert!(!ledger.authorises(id(10), id(1)));
        assert_eq!(ledger.claim(id(1), &ticket, id(12)), Claim::Refused);
        assert_eq!(ledger.holder(id(1)), Some(id(11)));
    }

    #[test]
    fn a_stale_or_wrong_ticket_is_refused_and_changes_nothing() {
        let mut ledger = AwayLedger::default();
        let ticket = ledger.mint(id(1), id(10));
        let before = ledger.clone();
        assert_eq!(
            ledger.claim(id(1), &crypto::random_key(), id(11)),
            Claim::Refused
        );
        assert_eq!(ledger.claim(id(1), &[], id(11)), Claim::Refused);
        assert_eq!(ledger.claim(id(2), &ticket, id(11)), Claim::Refused);
        assert_eq!(ledger, before);
    }

    #[test]
    fn the_holder_claiming_again_just_rotates() {
        let mut ledger = AwayLedger::default();
        let first = ledger.mint(id(1), id(10));
        let Claim::Granted {
            ticket: second,
            previous,
        } = ledger.claim(id(1), &first, id(10))
        else {
            panic!("refused");
        };
        assert!(previous.is_none() && ledger.notices().is_empty());
        let Claim::Granted { ticket: third, .. } = ledger.claim(id(1), &second, id(10)) else {
            panic!("the current ticket is good");
        };
        // The second ticket arrived, so the first is dead even for the holder.
        assert_eq!(ledger.claim(id(1), &first, id(10)), Claim::Refused);
        assert!(matches!(
            ledger.claim(id(1), &third, id(10)),
            Claim::Granted { .. }
        ));
    }

    #[test]
    fn a_holder_whose_claimed_was_lost_claims_again_with_the_ticket_it_has() {
        let mut ledger = AwayLedger::default();
        let first = ledger.mint(id(1), id(10));
        // The holder claims. The connection drops before the `claimed` reply arrives.
        assert!(matches!(
            ledger.claim(id(1), &first, id(10)),
            Claim::Granted { .. }
        ));
        // Another device may not use it, but the holder may, and gets a fresh ticket.
        assert_eq!(ledger.claim(id(1), &first, id(11)), Claim::Refused);
        let Claim::Granted {
            ticket: fresh,
            previous,
        } = ledger.claim(id(1), &first, id(10))
        else {
            panic!("the holder's last ticket is still good");
        };
        assert!(previous.is_none() && ledger.notices().is_empty());
        // That `claimed` may be lost too: the ticket the holder has stays good until it uses a newer one.
        assert!(matches!(
            ledger.claim(id(1), &first, id(10)),
            Claim::Granted { .. }
        ));
        assert!(ledger.release(id(1), &first) && !ledger.is_away(id(1)));
        let _ = fresh;
        // The same with a release: the ticket before the lost `claimed` brings the Imp home.
        let first = ledger.mint(id(2), id(10));
        ledger.claim(id(2), &first, id(10));
        assert!(ledger.release(id(2), &first) && !ledger.is_away(id(2)));
        // An entry with no earlier ticket is written without `previous` and reads back without it.
        let old: AwayEntry = serde_json::from_str(
            r#"{"imp":"00000000-0000-0000-0000-000000000001","holder":"00000000-0000-0000-0000-00000000000a","ticket":"AAAA","generation":3}"#,
        )
        .unwrap();
        assert!(old.previous.is_none());
    }

    #[test]
    fn passing_again_mints_a_ticket_that_kills_the_old() {
        let mut ledger = AwayLedger::default();
        let old = ledger.mint(id(1), id(10));
        let new = ledger.mint(id(1), id(11));
        assert_eq!(ledger.holder(id(1)), Some(id(11)));
        assert_eq!(ledger.entry(id(1)).unwrap().generation, 2);
        assert_eq!(ledger.claim(id(1), &old, id(10)), Claim::Refused);
        assert!(matches!(
            ledger.claim(id(1), &new, id(11)),
            Claim::Granted { .. }
        ));
    }

    #[test]
    fn a_late_claim_or_release_after_calling_home_finds_nothing_and_the_holder_hears_once() {
        let mut ledger = AwayLedger::default();
        let ticket = ledger.mint(id(1), id(10));
        assert_eq!(ledger.call_home(id(1)), Some(id(10)));
        assert!(!ledger.is_away(id(1)) && !ledger.authorises(id(10), id(1)));
        assert_eq!(ledger.claim(id(1), &ticket, id(10)), Claim::Refused);
        assert!(!ledger.release(id(1), &ticket));
        assert!(ledger.take_notices(id(11)).is_empty());
        assert_eq!(ledger.take_notices(id(10)), vec![id(1)]);
        assert!(ledger.take_notices(id(10)).is_empty());
    }

    #[test]
    fn calling_home_from_a_device_takes_all_it_holds_and_leaves_the_rest() {
        let mut ledger = AwayLedger::default();
        ledger.mint(id(1), id(10));
        ledger.mint(id(2), id(10));
        ledger.mint(id(3), id(11));
        let mut taken = ledger.call_home_from(id(10));
        taken.sort();
        assert_eq!(taken, vec![id(1), id(2)]);
        assert_eq!(ledger.holder(id(3)), Some(id(11)));
        assert_eq!(ledger.entries().len(), 1);
        let mut told = ledger.take_notices(id(10));
        told.sort();
        assert_eq!(told, vec![id(1), id(2)]);
    }

    #[test]
    fn release_after_a_claim_needs_the_newest_ticket() {
        let mut ledger = AwayLedger::default();
        let first = ledger.mint(id(1), id(10));
        let Claim::Granted { ticket: second, .. } = ledger.claim(id(1), &first, id(11)) else {
            panic!("refused");
        };
        assert!(!ledger.release(id(1), &first) && ledger.is_away(id(1)));
        assert!(ledger.release(id(1), &second) && !ledger.is_away(id(1)));
        assert!(!ledger.release(id(1), &second));
    }

    #[test]
    fn coming_home_kills_the_ticket_quietly() {
        let mut ledger = AwayLedger::default();
        ledger.mint(id(1), id(10));
        ledger.came_home(id(1));
        assert!(!ledger.is_away(id(1)) && ledger.notices().is_empty());
    }

    #[test]
    fn notices_are_not_duplicated_across_claims() {
        let mut ledger = AwayLedger::default();
        let t = ledger.mint(id(1), id(10));
        let Claim::Granted { ticket: t2, .. } = ledger.claim(id(1), &t, id(11)) else {
            panic!()
        };
        let Claim::Granted { ticket: t3, .. } = ledger.claim(id(1), &t2, id(10)) else {
            panic!()
        };
        ledger.claim(id(1), &t3, id(11));
        assert_eq!(
            ledger
                .notices()
                .iter()
                .filter(|n| n.device == id(10))
                .count(),
            1
        );
    }

    #[test]
    fn minting_over_a_previous_holder_tells_it_gone_but_not_the_same_holder() {
        let mut ledger = AwayLedger::default();
        ledger.mint(id(1), id(10));
        ledger.mint(id(1), id(10));
        assert!(ledger.notices().is_empty());
        ledger.mint(id(1), id(11));
        assert_eq!(ledger.holder(id(1)), Some(id(11)));
        assert_eq!(ledger.take_notices(id(10)), vec![id(1)]);
    }
}
