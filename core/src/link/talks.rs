//! Who can message whom, and where a `message` goes (`docs/connecting/link.md`, "Imps talking"). An Imp
//! can message the other Imps of its home and the Imps on the screen its body is on. The home sends the
//! question to the device that can answer: the target's home, or the holder of the asking Imp, which
//! answers for its own Imps and forwards once to the target's home. The answer goes back the same way.

use crate::link::messages::LinkStaged;
use std::collections::BTreeMap;
use uuid::Uuid;

/// A message between Imps that is not answered in this time (seconds) fails.
pub const ANSWER_TIMEOUT: f64 = 120.0;
/// How many questions one device may have in flight through this one.
pub const PER_SENDER: usize = 16;

/// The Imps `asker` can message from where its body is. `mine` are the Imps of its home (this device),
/// `stage` the Imps on the screen where its body is.
pub fn targets(asker: Uuid, mine: &[LinkStaged], stage: &[LinkStaged]) -> Vec<LinkStaged> {
    let mut seen = vec![asker];
    let mut found = Vec::new();
    for staged in mine.iter().chain(stage) {
        if !seen.contains(&staged.imp.id) {
            seen.push(staged.imp.id);
            found.push(staged.clone());
        }
    }
    found
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum First {
    /// The target's home is this device: answer here.
    Here,
    /// Send it to this device.
    Via(Uuid),
    /// Nobody connected can answer.
    Unreachable,
}

/// Where a question from an Imp of this device (`me` is its home) goes first. `holder` is the device the
/// asking Imp's body is on (`me` when it is at home).
pub fn first(me: Uuid, target_home: Uuid, holder: Uuid, connected: &[Uuid]) -> First {
    if target_home == me {
        First::Here
    } else if connected.contains(&target_home) {
        First::Via(target_home)
    } else if holder != me && connected.contains(&holder) {
        First::Via(holder)
    } else {
        First::Unreachable
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Received {
    /// The target's home is this device: answer it.
    Answer,
    /// Not for this device: pass it on (once) to the target's home.
    Forward(Uuid),
    /// Cannot be answered or forwarded from here.
    Refuse,
}

/// What a device does with a `message` that came from `sender`.
pub fn received(
    me: Uuid,
    target_home: Uuid,
    forwarded: bool,
    sender: Uuid,
    connected: &[Uuid],
) -> Received {
    if target_home == me {
        Received::Answer
    } else if !forwarded && target_home != sender && connected.contains(&target_home) {
        Received::Forward(target_home)
    } else {
        Received::Refuse
    }
}

/// Whether a question for an Imp of this device may be answered: its asker must be on the screen the
/// target's body is on (`screen`: our own stage if the target is here, the holder's stage if it is away).
/// A forwarded one must also come from a device whose stage (`sender_stage`) holds the asker, or which is
/// the asker's home according to some stage we know (`known`).
pub fn may_ask(
    asker: Uuid,
    screen: &[LinkStaged],
    forwarded: bool,
    sender: Uuid,
    sender_stage: &[LinkStaged],
    known: &[LinkStaged],
) -> bool {
    if !screen.iter().any(|s| s.imp.id == asker) {
        return false;
    }
    !forwarded
        || sender_stage.iter().any(|s| s.imp.id == asker)
        || known.iter().any(|s| s.imp.id == asker && s.home == sender)
}

/// A question in flight.
#[derive(Debug, Clone, PartialEq)]
pub struct Question {
    pub id: Uuid,
    /// The device that sent it here (None: asked from this device).
    pub from: Option<Uuid>,
    /// The device it went on to.
    pub to: Uuid,
    deadline: f64,
}

/// Questions in flight, so each answer finds its way back, and a question nobody answers fails.
#[derive(Debug, Default)]
pub struct Pending {
    questions: BTreeMap<Uuid, Question>,
}

impl Pending {
    /// False if a question with this id is in flight already (it is not replaced).
    pub fn sent(&mut self, id: Uuid, from: Option<Uuid>, to: Uuid, now: f64, timeout: f64) -> bool {
        if self.questions.contains_key(&id) {
            return false;
        }
        self.questions.insert(
            id,
            Question {
                id,
                from,
                to,
                deadline: now + timeout,
            },
        );
        true
    }

    /// How many questions `device` has in flight through here.
    pub fn count_from(&self, device: Uuid) -> usize {
        self.questions
            .values()
            .filter(|q| q.from == Some(device))
            .count()
    }

    /// An answer came from `device`. None unless it is the one the question went to.
    pub fn answered(&mut self, id: Uuid, device: Uuid) -> Option<Question> {
        if self.questions.get(&id)?.to != device {
            return None;
        }
        self.questions.remove(&id)
    }

    /// The questions that ran out of time.
    pub fn expired(&mut self, now: f64) -> Vec<Question> {
        self.take(|q| q.deadline <= now)
    }

    /// The questions that went to `device`, which just went away.
    pub fn lost(&mut self, device: Uuid) -> Vec<Question> {
        self.take(|q| q.to == device)
    }

    fn take(&mut self, mut which: impl FnMut(&Question) -> bool) -> Vec<Question> {
        let ids: Vec<Uuid> = self
            .questions
            .values()
            .filter(|q| which(q))
            .map(|q| q.id)
            .collect();
        ids.into_iter()
            .filter_map(|id| self.questions.remove(&id))
            .collect()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::link::visits::tests::imp;

    fn id(n: u128) -> Uuid {
        Uuid::from_u128(n)
    }

    fn staged(n: u128, home: u128) -> LinkStaged {
        LinkStaged {
            imp: imp(n),
            home: id(home),
        }
    }

    #[test]
    fn an_imp_can_message_its_homes_imps_and_the_screens_but_not_itself() {
        let found = targets(
            id(1),
            &[staged(1, 10), staged(2, 10)],
            &[staged(2, 10), staged(3, 11)],
        );
        assert_eq!(
            found.iter().map(|s| s.imp.id).collect::<Vec<_>>(),
            vec![id(2), id(3)]
        );
    }

    #[test]
    fn a_question_goes_to_the_target_home_or_the_holder() {
        let me = id(1);
        assert_eq!(first(me, me, me, &[]), First::Here);
        assert_eq!(first(me, id(2), me, &[id(2)]), First::Via(id(2)));
        assert_eq!(first(me, id(2), id(3), &[id(3)]), First::Via(id(3)));
        assert_eq!(first(me, id(2), me, &[id(3)]), First::Unreachable);
        assert_eq!(first(me, id(2), id(3), &[]), First::Unreachable);
    }

    #[test]
    fn a_received_question_is_answered_forwarded_once_or_refused() {
        let me = id(1);
        assert_eq!(received(me, me, true, id(2), &[]), Received::Answer);
        assert_eq!(
            received(me, id(3), false, id(2), &[id(3)]),
            Received::Forward(id(3))
        );
        assert_eq!(received(me, id(3), true, id(2), &[id(3)]), Received::Refuse);
        assert_eq!(
            received(me, id(2), false, id(2), &[id(2)]),
            Received::Refuse
        );
        assert_eq!(received(me, id(3), false, id(2), &[]), Received::Refuse);
    }

    #[test]
    fn only_an_imp_on_the_same_screen_may_ask_and_a_forward_must_be_vouched_for() {
        let screen = [staged(5, 10)];
        assert!(!may_ask(id(6), &screen, false, id(10), &[], &[]));
        assert!(may_ask(id(5), &screen, false, id(10), &[], &[]));
        assert!(!may_ask(id(5), &screen, true, id(10), &[], &[]));
        assert!(may_ask(id(5), &screen, true, id(10), &[staged(5, 10)], &[]));
        assert!(may_ask(id(5), &screen, true, id(10), &[], &[staged(5, 10)]));
        assert!(!may_ask(
            id(5),
            &screen,
            true,
            id(11),
            &[],
            &[staged(5, 10)]
        ));
    }

    #[test]
    fn answers_find_their_way_back_and_silence_fails() {
        let mut p = Pending::default();
        assert!(p.sent(id(1), Some(id(10)), id(20), 0.0, 120.0));
        assert!(!p.sent(id(1), None, id(21), 0.0, 120.0));
        assert!(p.sent(id(2), None, id(21), 0.0, 5.0));
        assert_eq!(p.count_from(id(10)), 1);
        assert!(p.answered(id(1), id(21)).is_none());
        assert_eq!(p.answered(id(1), id(20)).unwrap().from, Some(id(10)));
        assert_eq!(p.expired(5.0).len(), 1);
        assert!(p.sent(id(3), None, id(22), 0.0, 120.0));
        assert_eq!(p.lost(id(22)).len(), 1);
        assert!(p.expired(1e9).is_empty());
    }

    #[test]
    fn a_question_across_three_devices_takes_two_hops_at_most() {
        // A (asker's home) -> C (holder of the asking Imp) -> B (target's home); A is not linked to B.
        let (a, b, c) = (id(2), id(3), id(4));
        assert_eq!(first(a, b, c, &[c]), First::Via(c));
        assert_eq!(received(c, b, false, a, &[a, b]), Received::Forward(b));
        assert_eq!(received(b, b, true, c, &[c]), Received::Answer);
        assert_eq!(received(c, b, true, a, &[a, b]), Received::Refuse);
    }

    #[test]
    fn a_device_answers_what_is_its_own_forwarded_or_not() {
        assert_eq!(
            received(id(1), id(1), false, id(2), &[id(2)]),
            Received::Answer
        );
        assert_eq!(
            received(id(1), id(1), true, id(2), &[id(2)]),
            Received::Answer
        );
    }

    #[test]
    fn an_answer_comes_once_and_our_own_question_has_nobody_to_hand_it_to() {
        let mut p = Pending::default();
        p.sent(id(1), Some(id(2)), id(3), 0.0, 120.0);
        assert!(p.answered(id(1), id(4)).is_none());
        let answered = p.answered(id(1), id(3)).unwrap();
        assert_eq!((answered.from, answered.to), (Some(id(2)), id(3)));
        assert!(p.answered(id(1), id(3)).is_none());
        p.sent(id(1), None, id(3), 0.0, 120.0);
        assert_eq!(p.answered(id(1), id(3)).unwrap().from, None);
    }

    #[test]
    fn questions_time_out_after_two_minutes_and_a_late_answer_finds_nothing() {
        let mut p = Pending::default();
        p.sent(id(1), None, id(2), 0.0, ANSWER_TIMEOUT);
        assert!(p.expired(ANSWER_TIMEOUT - 1.0).is_empty());
        let out = p.expired(ANSWER_TIMEOUT);
        assert_eq!(out.iter().map(|q| q.id).collect::<Vec<_>>(), vec![id(1)]);
        assert!(p.expired(500.0).is_empty());
        assert!(p.answered(id(1), id(2)).is_none());
        assert_eq!(ANSWER_TIMEOUT, 120.0);
    }

    #[test]
    fn senders_are_counted_and_a_question_id_is_never_in_flight_twice() {
        let mut p = Pending::default();
        assert!(p.sent(id(1), Some(id(2)), id(3), 0.0, 1.0));
        assert!(!p.sent(id(1), Some(id(4)), id(3), 0.0, 1.0));
        for n in 10..13 {
            p.sent(id(n), Some(id(2)), id(3), 0.0, 1.0);
        }
        assert_eq!((p.count_from(id(2)), p.count_from(id(4))), (4, 0));
    }

    #[test]
    fn questions_to_a_device_that_left_fail_and_others_stay() {
        let mut p = Pending::default();
        p.sent(id(1), None, id(2), 0.0, 100.0);
        p.sent(id(2), None, id(3), 0.0, 100.0);
        assert_eq!(
            p.lost(id(2)).iter().map(|q| q.id).collect::<Vec<_>>(),
            vec![id(1)]
        );
        assert_eq!(p.lost(id(2)).len(), 0);
        assert!(p.answered(id(2), id(3)).is_some());
    }
}
