//! Bookkeeping for Imps in flight (`docs/connecting/link.md`, "Passing"). A throw is answered `took` or
//! `declined`, and no answer in time is a decline. A transfer id that comes again is answered again and
//! never taken twice. Time is passed in, in seconds.

use crate::link::messages::LinkDecline;
use std::collections::{BTreeMap, VecDeque};
use uuid::Uuid;

/// A throw that is not answered in this time (seconds) bounces back.
pub const TRANSFER_TIMEOUT: f64 = 10.0;
/// How long a receiver may take to answer an adoption (seconds).
pub const ADOPT_TIMEOUT: f64 = 10.0 * 60.0;
/// How many answers are remembered for repeats.
const REMEMBERED: usize = 256;
/// How long (seconds) and how many expired throws are remembered, so a late `took` can still be dealt with.
const BURIED_LIFE: f64 = 10.0 * 60.0;
const BURIED_COUNT: usize = 256;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TransferKind {
    Pass,
    /// Moving in for good waits for the receiver's user, so it gets longer.
    Adopt,
}

/// A throw this device made and waits to hear about.
#[derive(Debug, Clone, PartialEq)]
pub struct Outgoing {
    pub id: Uuid,
    pub imp: Uuid,
    pub to: Uuid,
    pub kind: TransferKind,
    deadline: f64,
}

/// What this device answered (or still owes) for a throw it received.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Reply {
    Waiting,
    Took,
    Declined(LinkDecline),
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Received {
    /// First time: ask the user (or the screen) and answer.
    New,
    /// Already asked and still waiting: say nothing.
    Pending,
    /// Already answered: answer the same again.
    Repeated(Reply),
}

#[derive(Debug, Clone)]
struct Incoming {
    from: Uuid,
    reply: Reply,
    deadline: f64,
}

#[derive(Debug, Default)]
pub struct Transfers {
    outgoing: BTreeMap<Uuid, Outgoing>,
    buried: BTreeMap<Uuid, (Outgoing, f64)>,
    buried_order: VecDeque<Uuid>,
    incoming: BTreeMap<Uuid, Incoming>,
    order: VecDeque<Uuid>,
}

impl Transfers {
    pub fn outgoing(&self) -> &BTreeMap<Uuid, Outgoing> {
        &self.outgoing
    }

    /// A throw was sent to `to`.
    pub fn sent(
        &mut self,
        id: Uuid,
        imp: Uuid,
        to: Uuid,
        kind: TransferKind,
        now: f64,
        timeout: f64,
    ) {
        let wait = if kind == TransferKind::Adopt {
            timeout.max(ADOPT_TIMEOUT)
        } else {
            timeout
        };
        self.outgoing.insert(
            id,
            Outgoing {
                id,
                imp,
                to,
                kind,
                deadline: now + wait,
            },
        );
    }

    /// `took` or `declined` came from `device`. None if nothing was waiting for that from it (an unknown
    /// id, a late answer after the timeout, or somebody else's).
    pub fn answered(&mut self, id: Uuid, device: Uuid) -> Option<Outgoing> {
        if self.outgoing.get(&id)?.to != device {
            return None;
        }
        self.outgoing.remove(&id)
    }

    /// The throws that ran out of time.
    pub fn expired(&mut self, now: f64) -> Vec<Outgoing> {
        let ids: Vec<Uuid> = self
            .outgoing
            .values()
            .filter(|t| t.deadline <= now)
            .map(|t| t.id)
            .collect();
        ids.into_iter()
            .filter_map(|id| self.bury(id, now))
            .collect()
    }

    /// A `took` came from `device` for a throw that already ran out of time (or whose connection
    /// dropped). None unless it is one we remember, thrown to that device.
    pub fn late(&mut self, id: Uuid, device: Uuid, now: f64) -> Option<Outgoing> {
        let (known, until) = self.buried.get(&id)?;
        if known.to != device || *until <= now {
            return None;
        }
        self.buried.remove(&id).map(|(t, _)| t)
    }

    fn bury(&mut self, id: Uuid, now: f64) -> Option<Outgoing> {
        let t = self.outgoing.remove(&id)?;
        self.buried.insert(id, (t.clone(), now + BURIED_LIFE));
        self.buried_order.push_back(id);
        while self.buried_order.len() > BURIED_COUNT
            || self
                .buried_order
                .front()
                .is_some_and(|f| self.buried.get(f).is_none_or(|(_, until)| *until <= now))
        {
            if let Some(old) = self.buried_order.pop_front() {
                self.buried.remove(&old);
            }
        }
        Some(t)
    }

    /// The throws to `device`, which just went away.
    pub fn lost(&mut self, device: Uuid, now: f64) -> Vec<Outgoing> {
        let ids: Vec<Uuid> = self
            .outgoing
            .values()
            .filter(|t| t.to == device)
            .map(|t| t.id)
            .collect();
        ids.into_iter()
            .filter_map(|id| self.bury(id, now))
            .collect()
    }

    /// A throw arrived from `device`.
    pub fn received(&mut self, id: Uuid, device: Uuid, now: f64, timeout: f64) -> Received {
        if let Some(known) = self.incoming.get(&id).filter(|k| k.from == device) {
            return match known.reply {
                Reply::Waiting => Received::Pending,
                reply => Received::Repeated(reply),
            };
        }
        self.incoming.insert(
            id,
            Incoming {
                from: device,
                reply: Reply::Waiting,
                deadline: now + timeout,
            },
        );
        self.order.retain(|o| *o != id);
        self.order.push_back(id);
        // The oldest answered one goes. One still waiting for the app is never forgotten.
        if self.order.len() > REMEMBERED
            && let Some(i) = self.order.iter().position(|o| {
                self.incoming
                    .get(o)
                    .is_none_or(|k| k.reply != Reply::Waiting)
            })
            && let Some(old) = self.order.remove(i)
        {
            self.incoming.remove(&old);
        }
        Received::New
    }

    /// How many throws from `device` still wait for an answer.
    pub fn waiting(&self, device: Uuid) -> usize {
        self.incoming
            .values()
            .filter(|k| k.from == device && k.reply == Reply::Waiting)
            .count()
    }

    /// Whether a throw was received and is still waiting for an answer.
    pub fn is_waiting(&self, id: Uuid) -> bool {
        self.incoming
            .get(&id)
            .is_some_and(|k| k.reply == Reply::Waiting)
    }

    /// Records the answer to a throw. False if it is not one waiting (answered already, or unknown).
    pub fn answer(&mut self, id: Uuid, reply: Reply) -> bool {
        match self.incoming.get_mut(&id) {
            Some(known) if known.reply == Reply::Waiting => {
                known.reply = reply;
                true
            }
            _ => false,
        }
    }

    /// Throws nobody answered in time: they are declined (the thrower gave up on them anyway).
    pub fn lapsed(&mut self, now: f64) -> Vec<(Uuid, Uuid)> {
        let mut late = Vec::new();
        for (id, known) in &mut self.incoming {
            if known.reply == Reply::Waiting && known.deadline <= now {
                known.reply = Reply::Declined(LinkDecline::Timeout);
                late.push((*id, known.from));
            }
        }
        late
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn id(n: u128) -> Uuid {
        Uuid::from_u128(n)
    }

    #[test]
    fn a_throw_is_answered_once_and_only_by_who_it_went_to() {
        let mut t = Transfers::default();
        t.sent(
            id(1),
            id(100),
            id(10),
            TransferKind::Pass,
            0.0,
            TRANSFER_TIMEOUT,
        );
        assert!(t.answered(id(1), id(11)).is_none());
        assert_eq!(t.answered(id(1), id(10)).unwrap().imp, id(100));
        assert!(t.answered(id(1), id(10)).is_none());
        assert!(t.answered(id(2), id(10)).is_none());
    }

    #[test]
    fn a_throw_with_no_answer_expires_and_a_late_took_is_still_known() {
        let mut t = Transfers::default();
        t.sent(id(1), id(100), id(10), TransferKind::Pass, 0.0, 10.0);
        assert!(t.expired(9.9).is_empty());
        let late = t.expired(10.0);
        assert_eq!(late.len(), 1);
        assert!(t.answered(id(1), id(10)).is_none());
        assert!(t.late(id(1), id(11), 11.0).is_none());
        assert_eq!(t.late(id(1), id(10), 11.0).unwrap().imp, id(100));
        assert!(t.late(id(1), id(10), 11.0).is_none());
    }

    #[test]
    fn a_buried_throw_is_forgotten_after_its_life() {
        let mut t = Transfers::default();
        t.sent(id(1), id(100), id(10), TransferKind::Pass, 0.0, 10.0);
        t.expired(10.0);
        assert!(t.late(id(1), id(10), 10.0 + BURIED_LIFE).is_none());
    }

    #[test]
    fn an_adoption_waits_longer_for_the_other_user() {
        let mut t = Transfers::default();
        t.sent(id(1), id(100), id(10), TransferKind::Adopt, 0.0, 10.0);
        assert!(t.expired(60.0).is_empty());
        assert_eq!(t.expired(ADOPT_TIMEOUT).len(), 1);
    }

    #[test]
    fn a_lost_device_takes_its_throws_with_it() {
        let mut t = Transfers::default();
        t.sent(id(1), id(100), id(10), TransferKind::Pass, 0.0, 10.0);
        t.sent(id(2), id(101), id(11), TransferKind::Pass, 0.0, 10.0);
        assert_eq!(t.lost(id(10), 1.0).len(), 1);
        assert_eq!(t.outgoing().len(), 1);
        assert!(t.late(id(1), id(10), 2.0).is_some());
    }

    #[test]
    fn a_repeated_throw_is_answered_again_and_never_taken_twice() {
        let mut t = Transfers::default();
        assert_eq!(t.received(id(1), id(10), 0.0, 10.0), Received::New);
        assert_eq!(t.received(id(1), id(10), 1.0, 10.0), Received::Pending);
        assert!(t.is_waiting(id(1)));
        assert_eq!(t.waiting(id(10)), 1);
        assert!(t.answer(id(1), Reply::Took));
        assert!(!t.answer(id(1), Reply::Declined(LinkDecline::Full)));
        assert_eq!(
            t.received(id(1), id(10), 2.0, 10.0),
            Received::Repeated(Reply::Took)
        );
        assert_eq!(t.waiting(id(10)), 0);
        assert!(!t.answer(id(9), Reply::Took));
    }

    #[test]
    fn unanswered_throws_lapse_into_a_timeout_decline() {
        let mut t = Transfers::default();
        t.received(id(1), id(10), 0.0, 10.0);
        assert!(t.lapsed(5.0).is_empty());
        assert_eq!(t.lapsed(10.0), vec![(id(1), id(10))]);
        assert_eq!(
            t.received(id(1), id(10), 11.0, 10.0),
            Received::Repeated(Reply::Declined(LinkDecline::Timeout))
        );
        assert!(t.lapsed(20.0).is_empty());
    }

    #[test]
    fn a_waiting_throw_is_never_forgotten_for_room() {
        let mut t = Transfers::default();
        t.received(id(0), id(10), 0.0, 1e9);
        for n in 1..=REMEMBERED as u128 + 10 {
            t.received(id(n), id(10), 0.0, 1e9);
            t.answer(id(n), Reply::Took);
        }
        assert!(t.is_waiting(id(0)));
        assert!(t.incoming.len() <= REMEMBERED + 1);
    }

    #[test]
    fn declines_are_repeated_too() {
        let mut t = Transfers::default();
        t.received(id(1), id(10), 0.0, 10.0);
        assert!(t.answer(id(1), Reply::Declined(LinkDecline::Playing)));
        assert_eq!(
            t.received(id(1), id(10), 1.0, 10.0),
            Received::Repeated(Reply::Declined(LinkDecline::Playing))
        );
    }

    #[test]
    fn only_recent_answers_are_remembered() {
        let mut t = Transfers::default();
        t.received(id(0), id(10), 0.0, 10.0);
        t.answer(id(0), Reply::Took);
        for n in 1..=REMEMBERED as u128 + 1 {
            t.received(id(n), id(10), 0.0, 10.0);
        }
        assert_eq!(t.received(id(0), id(10), 0.0, 10.0), Received::New);
    }

    #[test]
    fn waiting_throws_are_counted_per_device() {
        let mut t = Transfers::default();
        t.received(id(0), id(10), 0.0, 1e9);
        for n in 1..=REMEMBERED as u128 + 10 {
            t.received(id(n), id(11), 0.0, 1e9);
        }
        assert_eq!(t.waiting(id(10)), 1);
        assert_eq!(t.waiting(id(11)), REMEMBERED + 10);
    }

    #[test]
    fn buried_throws_are_bounded() {
        let mut t = Transfers::default();
        t.sent(id(0), id(500), id(10), TransferKind::Pass, 0.0, 1.0);
        t.expired(2.0);
        for n in 1..=BURIED_COUNT as u128 {
            t.sent(id(n), id(500 + n), id(10), TransferKind::Pass, 0.0, 1.0);
        }
        t.expired(2.0);
        assert!(t.late(id(0), id(10), 3.0).is_none());
        assert!(t.late(id(1), id(10), 3.0).is_some());
    }

    #[test]
    fn two_expired_throws_are_each_remembered_for_a_late_took() {
        let mut t = Transfers::default();
        t.sent(id(1), id(500), id(10), TransferKind::Pass, 0.0, 1.0);
        t.sent(id(2), id(501), id(10), TransferKind::Pass, 0.0, 1.0);
        assert_eq!(t.expired(2.0).len(), 2);
        assert_eq!(t.late(id(1), id(10), 3.0).unwrap().imp, id(500));
        assert_eq!(t.late(id(2), id(10), 2.0 + BURIED_LIFE), None);
    }
}
