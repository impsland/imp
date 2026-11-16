//! What a message from a connected device may do here. The home answers an Imp's requests only from its
//! current holder, and a holder only believes what its Imp's home says about that Imp.

use crate::link::ledger::AwayLedger;
use crate::link::messages::LinkMessage;
use crate::link::visits::Visits;
use uuid::Uuid;

/// How much a connected device is trusted (`docs/connecting/link.md`, "Handshake").
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Standing {
    /// A device this one has a link with: both pinned each other's key.
    Peer,
    /// Anyone else who knows the door key. It may only claim and use tickets.
    Visitor,
}

/// Whether `message` from `device` is allowed to do anything here.
pub fn allows(
    message: &LinkMessage,
    device: Uuid,
    standing: Standing,
    ledger: &AwayLedger,
    visits: &Visits,
) -> bool {
    use LinkMessage as M;
    let visit_of = |imp: &Uuid| visits.visit(*imp).is_some_and(|v| v.home.id() == device);
    match message {
        // Claims and releases prove themselves with a ticket, `claimed` and `gone` only touch a visit of
        // the sender's own, and an answer must match a question sent to the sender.
        M::Ping {}
        | M::Pong {}
        | M::Bye { .. }
        | M::Claim { .. }
        | M::Release { .. }
        | M::Claimed { .. }
        | M::Gone { .. }
        | M::Answer { .. } => true,
        // Only the handshake, which the node deals with before any of this.
        M::Hello { .. } | M::Welcome { .. } => false,
        M::Ask { imp, .. }
        | M::Stop { imp }
        | M::NewChat { imp }
        | M::Felt { imp, .. }
        | M::File { imp, .. }
        | M::Talks { imp } => ledger.authorises(device, *imp),
        // A visitor holds the target's body: that is its right to ask it something.
        M::Message { to, .. } => standing == Standing::Peer || ledger.authorises(device, *to),
        // What is on a screen: from a peer, from a holder of one of our Imps, or from the home of an Imp
        // visiting us.
        M::Stage { .. } => {
            standing == Standing::Peer
                || !ledger.held_by(device).is_empty()
                || visits.visits().iter().any(|v| v.home.id() == device)
        }
        M::Routes { .. }
        | M::Pass { .. }
        | M::Took { .. }
        | M::Declined { .. }
        | M::Adopt { .. }
        | M::Adopted { .. } => standing == Standing::Peer,
        M::Look { imp } => visit_of(&imp.id),
        M::Chat { imp, .. }
        | M::Work { imp, .. }
        | M::Mood { imp, .. }
        | M::Brain { imp, .. }
        | M::Animate { imp, .. }
        | M::Speech { imp, .. }
        | M::TalkLines { imp, .. } => visit_of(imp),
        M::FilePart { .. } | M::FileFailed { .. } => {
            visits.visits().iter().any(|v| v.home.id() == device)
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::link::card::{LinkKind, LinkRoutes};
    use crate::link::messages::{Bytes, LinkEntry, LinkFilePart, LinkImp, LinkSecrets, LinkSide};
    use crate::link::visits::tests::{card, imp};

    fn id(n: u128) -> Uuid {
        Uuid::from_u128(n)
    }

    fn entry() -> LinkEntry {
        LinkEntry::new(LinkSide::Left, 0.0, 0.0)
    }

    fn visiting(visits: &mut Visits, n: u128, home: u128) {
        assert!(visits.arrive(&imp(n), &entry(), id(2), &card(home, 1), &[5; 32]));
    }

    fn ask(to: u128) -> LinkMessage {
        LinkMessage::Message {
            id: id(900),
            from: imp(1),
            to: id(to),
            to_home: id(901),
            text: "?".into(),
            forwarded: false,
        }
    }

    #[test]
    fn only_the_holder_asks_an_imp() {
        let mut ledger = AwayLedger::default();
        ledger.mint(id(1), id(2));
        let visits = Visits::default();
        let messages = [
            LinkMessage::Ask {
                imp: id(1),
                text: "hi".into(),
            },
            LinkMessage::Stop { imp: id(1) },
            LinkMessage::NewChat { imp: id(1) },
            LinkMessage::Felt {
                imp: id(1),
                feeling: crate::link::messages::LinkFeeling::Poke,
            },
            LinkMessage::File {
                id: id(7),
                imp: id(1),
                reference: "a.png".into(),
            },
            LinkMessage::Talks { imp: id(1) },
        ];
        for m in &messages {
            for standing in [Standing::Visitor, Standing::Peer] {
                assert!(allows(m, id(2), standing, &ledger, &visits), "{m:?}");
                assert!(!allows(m, id(3), standing, &ledger, &visits), "{m:?}");
            }
        }
    }

    #[test]
    fn a_home_only_tells_its_own_visitors() {
        let mut visits = Visits::default();
        visiting(&mut visits, 1, 10);
        let ledger = AwayLedger::default();
        let ok =
            |m: &LinkMessage, from: u128, s: Standing| allows(m, id(from), s, &ledger, &visits);
        let work = LinkMessage::Work {
            imp: id(1),
            work: None,
        };
        assert!(ok(&work, 10, Standing::Visitor));
        assert!(!ok(&work, 3, Standing::Peer));
        let mood = LinkMessage::Mood {
            imp: id(2),
            mood: "happy".into(),
        };
        assert!(!ok(&mood, 10, Standing::Peer));
        let look = LinkMessage::Look { imp: imp(1) };
        assert!(ok(&look, 10, Standing::Peer));
        assert!(!ok(&look, 3, Standing::Peer));
        // Only its home says whether it has a brain.
        let brain = LinkMessage::Brain {
            imp: id(1),
            ready: false,
            tools: false,
        };
        assert!(ok(&brain, 10, Standing::Visitor));
        assert!(!ok(&brain, 3, Standing::Peer));
        let part = LinkMessage::FilePart {
            id: id(7),
            part: LinkFilePart {
                name: "a".into(),
                size: 1,
                offset: 0,
                data: Bytes(vec![1]),
            },
        };
        assert!(ok(&part, 10, Standing::Visitor));
        assert!(!ok(&part, 3, Standing::Visitor));
    }

    #[test]
    fn visitors_may_only_use_tickets() {
        let ledger = AwayLedger::default();
        let visits = Visits::default();
        let peer_only = [
            LinkMessage::Stage { imps: vec![] },
            LinkMessage::Routes {
                door: Bytes(vec![1; 32]),
                routes: LinkRoutes::none(),
            },
            LinkMessage::Took { transfer: id(5) },
            LinkMessage::Pass {
                transfer: id(5),
                imp: imp(1),
                entry: entry(),
                home: None,
                ticket: None,
            },
            LinkMessage::Adopt {
                transfer: id(5),
                imp: id(1),
                kit: String::new(),
                secrets: LinkSecrets::default(),
                entry: entry(),
            },
        ];
        for m in &peer_only {
            assert!(
                !allows(m, id(3), Standing::Visitor, &ledger, &visits),
                "{m:?}"
            );
            assert!(allows(m, id(3), Standing::Peer, &ledger, &visits), "{m:?}");
        }
        let tickets = [
            LinkMessage::Claim {
                imp: id(1),
                ticket: Bytes(vec![1; 32]),
            },
            LinkMessage::Release {
                imp: id(1),
                ticket: Bytes(vec![1; 32]),
            },
            LinkMessage::Ping {},
            LinkMessage::Bye {
                reason: String::new(),
            },
        ];
        for m in &tickets {
            assert!(
                allows(m, id(3), Standing::Visitor, &ledger, &visits),
                "{m:?}"
            );
        }
        // The handshake happens once, before any of this: never as a later message.
        let hello = LinkMessage::Hello {
            device: id(9),
            name: String::new(),
            kind: LinkKind::Mac,
            room: Bytes(vec![1; 32]),
            join: None,
        };
        assert!(!allows(&hello, id(3), Standing::Peer, &ledger, &visits));
    }

    #[test]
    fn a_holder_or_a_home_may_say_what_is_on_its_screen() {
        let mut ledger = AwayLedger::default();
        ledger.mint(id(2), id(20));
        let mut visits = Visits::default();
        visiting(&mut visits, 1, 10);
        let stage = LinkMessage::Stage { imps: vec![] };
        let (v, p) = (Standing::Visitor, AwayLedger::default());
        assert!(allows(&stage, id(20), v, &ledger, &Visits::default()));
        assert!(allows(&stage, id(10), v, &p, &visits));
        assert!(!allows(&stage, id(3), v, &ledger, &visits));
    }

    #[test]
    fn a_visitor_may_ask_only_what_it_holds() {
        let mut ledger = AwayLedger::default();
        ledger.mint(id(2), id(20));
        let visits = Visits::default();
        let v = Standing::Visitor;
        assert!(allows(&ask(2), id(20), v, &ledger, &visits));
        assert!(!allows(&ask(3), id(20), v, &ledger, &visits));
        assert!(allows(&ask(3), id(20), Standing::Peer, &ledger, &visits));
        let _: LinkImp = imp(1);
    }
}
