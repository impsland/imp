//! The link node end to end: several nodes joined by in-memory connections, doing what the adapters do.

mod common;

use common::{Net, id, imp, staged};
use imp_engine::link::access::Standing;
use imp_engine::link::card::LinkKind;
use imp_engine::link::node::{
    Ask, Event, FORGOTTEN, JoinError, Node, Options, PassOutcome, Problem, UNREACHABLE,
};
use imp_engine::link::talks::First;
use imp_engine::link::transfers::TransferKind;
use imp_engine::link::{LinkDecline, LinkEntry, LinkImp, LinkMessage, LinkSide};
use uuid::Uuid;

fn entry() -> LinkEntry {
    LinkEntry::new(LinkSide::Left, 0.5, 600.0)
}

fn dev(net: &Net, i: usize) -> Uuid {
    net.nodes[i].device().id
}

fn throw(net: &mut Net, from: usize, to: usize, who: &LinkImp) -> Uuid {
    let (now, target) = (net.now, dev(net, to));
    let transfer = net.nodes[from]
        .pass(who, entry(), target, now)
        .expect("a connected peer");
    net.pump();
    transfer
}

fn accept(net: &mut Net, at: usize, transfer: Uuid) -> bool {
    let now = net.now;
    let taken = net.nodes[at].accept(transfer, now);
    net.pump();
    taken
}

fn passed(net: &Net, i: usize) -> Vec<(Uuid, PassOutcome)> {
    net.events[i]
        .iter()
        .filter_map(|e| match e {
            Event::Passed(p) => Some((p.transfer, p.outcome)),
            _ => None,
        })
        .collect()
}

/// Devices 0, 1, 2 where 0 is linked with 1 and 1 with 2.
fn chain() -> Net {
    let mut net = Net::new(3);
    net.link(0, 1);
    net.link(1, 2);
    net.take(0);
    net.take(1);
    net.take(2);
    net
}

#[test]
fn a_guest_joins_with_a_fresh_invite_and_both_pin_each_other() {
    let mut net = Net::new(2);
    net.link(0, 1);
    for i in 0..2 {
        assert!(
            net.saw(i, |e| matches!(e, Event::Linked(_))),
            "node {i} linked"
        );
        assert!(net.saw(i, |e| matches!(e, Event::Connected(_, Standing::Peer))));
        assert_eq!(net.nodes[i].links().len(), 1);
    }
    assert!(net.saw(1, |e| matches!(e, Event::Joined { result: Ok(_), .. })));
    // They told each other where to be reached, so each can dial the other from now on.
    assert!(net.nodes[0].links()[0].door.is_some());
    assert!(net.nodes[1].links()[0].door.is_some());
    assert_eq!(
        net.nodes[0].links()[0].device.key.0,
        net.nodes[1].device().key.0
    );
}

#[test]
fn nothing_crosses_the_wire_in_the_clear() {
    let mut net = Net::new(2);
    net.link(0, 1);
    for name in [
        "Device 1", "Device 2", "routes", "stage", "hello", "welcome",
    ] {
        assert!(
            !net.traffic
                .windows(name.len())
                .any(|w| w == name.as_bytes()),
            "{name} was sent in the clear"
        );
    }
}

#[test]
fn a_pinned_peer_reconnects_after_the_connection_drops() {
    let mut net = Net::new(2);
    net.link(0, 1);
    net.cut(0, 1);
    assert!(!net.nodes[0].is_connected(id(2)));
    net.advance(5.0);
    assert!(net.nodes[0].is_connected(id(2)) && net.nodes[1].is_connected(id(1)));
}

#[test]
fn an_unreachable_device_is_tried_again_later_and_a_nudge_tries_now() {
    let mut net = Net::new(2);
    net.link(0, 1);
    net.unreachable.insert(id(1));
    net.unreachable.insert(id(2));
    net.cut(0, 1);
    net.advance(3.0);
    assert!(!net.nodes[0].is_connected(id(2)));
    net.unreachable.clear();
    let (now, device) = (net.now, id(2));
    net.nodes[0].kick(Some(&[device]), now);
    net.pump();
    assert!(net.nodes[0].is_connected(id(2)));
}

#[test]
fn an_expired_invite_makes_a_visitor_that_is_turned_away() {
    let mut net = Net::new(2);
    let invite = net.nodes[0].invite(net.now);
    net.nodes[0].invite_hidden(net.now);
    net.advance(16.0 * 60.0);
    net.nodes[1].join(&invite, net.now);
    net.pump();
    assert!(net.saw(1, |e| matches!(
        e,
        Event::Problem(Problem::InviteRefused(_))
    )));
    assert!(net.saw(1, |e| matches!(
        e,
        Event::Joined {
            result: Err(JoinError::Refused),
            ..
        }
    )));
    assert!(net.nodes[0].links().is_empty() && net.nodes[1].links().is_empty());
}

#[test]
fn a_replaced_invite_stops_working() {
    let mut net = Net::new(2);
    let old = net.nodes[0].invite(net.now);
    let _new = net.nodes[0].invite(net.now);
    net.nodes[1].join(&old, net.now);
    net.pump();
    assert!(net.saw(1, |e| matches!(
        e,
        Event::Joined {
            result: Err(JoinError::Refused),
            ..
        }
    )));
    assert!(net.nodes[0].links().is_empty());
}

#[test]
fn a_wrong_door_fails_the_handshake_cleanly() {
    let mut net = Net::new(2);
    let mut invite = net.nodes[0].invite(net.now);
    invite.door = vec![9; 32].into();
    net.nodes[1].join(&invite, net.now);
    net.pump();
    assert!(net.saw(1, |e| matches!(
        e,
        Event::Joined {
            result: Err(JoinError::Refused),
            ..
        }
    )));
    assert!(net.saw(1, |e| matches!(e, Event::Problem(Problem::Refused(_)))));
    assert!(net.nodes[0].links().is_empty() && net.nodes[0].connected().is_empty());
}

#[test]
fn a_join_to_nobody_ends_and_a_code_for_ourselves_is_refused() {
    let mut net = Net::new(2);
    let invite = net.nodes[0].invite(net.now);
    net.unreachable.insert(id(1));
    net.nodes[1].join(&invite, net.now);
    net.pump();
    assert!(net.saw(1, |e| matches!(
        e,
        Event::Joined {
            result: Err(JoinError::Unreachable),
            ..
        }
    )));
    let own = net.nodes[1].invite(net.now);
    net.nodes[1].join(&own, net.now);
    net.pump();
    assert!(net.saw(1, |e| matches!(
        e,
        Event::Joined {
            result: Err(JoinError::ItsOwnCode),
            ..
        }
    )));
}

#[test]
fn a_join_that_gets_no_answer_times_out() {
    let mut host = Node::new(None, "Host", LinkKind::Mac, id(1), Options::default()).unwrap();
    let mut guest = Node::new(None, "Guest", LinkKind::Phone, id(2), Options::default()).unwrap();
    guest.start(0.0);
    host.start(0.0);
    let invite = host.invite(0.0);
    guest.join(&invite, 0.0);
    // The adapter never reports back: no connection, no failure.
    guest.drain();
    guest.tick(29.0);
    assert!(!guest.drain().iter().any(|o| matches!(
        o,
        imp_engine::link::node::Output::Event(Event::Joined { .. })
    )));
    guest.tick(31.0);
    let timed_out = guest.drain().iter().any(|o| {
        matches!(
            o,
            imp_engine::link::node::Output::Event(Event::Joined {
                result: Err(JoinError::TimedOut),
                ..
            })
        )
    });
    assert!(timed_out);
}

#[test]
fn a_pinned_peer_with_another_key_is_closed_by_the_host() {
    let mut net = Net::new(2);
    net.link(0, 1);
    let invite = net.nodes[0].invite(net.now);
    // The same id with a new key: a reinstalled app, or someone pretending.
    let mut other =
        Node::new(None, "Device 2", LinkKind::Phone, id(2), Options::default()).unwrap();
    other.start(net.now);
    net.nodes[1] = other;
    net.nodes[1].join(&invite, net.now);
    net.pump();
    assert!(net.saw(0, |e| matches!(e, Event::Problem(Problem::KeyChanged(_)))));
    assert!(
        !net.nodes[0].is_connected(id(2))
            || net.nodes[0].links()[0].device.key.0 != net.nodes[1].device().key.0
    );
}

#[test]
fn a_host_with_another_key_than_pinned_is_refused_by_the_guest() {
    let mut net = Net::new(2);
    net.link(0, 1);
    net.cut(0, 1);
    net.unreachable.insert(id(1));
    net.unreachable.insert(id(2));
    net.nodes[0] = Node::new(None, "Device 1", LinkKind::Mac, id(1), Options::default()).unwrap();
    net.nodes[0].start(net.now);
    net.unreachable.clear();
    net.advance(5.0);
    assert!(net.saw(1, |e| matches!(e, Event::Problem(Problem::Refused(_)))));
    assert!(!net.nodes[1].is_connected(id(1)));
}

#[test]
fn an_imp_passes_and_is_taken() {
    let mut net = chain();
    let pip = imp(100, "Pip");
    let transfer = throw(&mut net, 0, 1, &pip);
    assert!(
        net.messages(1)
            .iter()
            .any(|(m, from)| matches!(m, LinkMessage::Pass { .. }) && *from == id(1))
    );
    assert!(net.nodes[1].can_accept(transfer));
    assert!(accept(&mut net, 1, transfer));
    assert_eq!(passed(&net, 0), vec![(transfer, PassOutcome::Took)]);
    assert_eq!(net.nodes[0].holder_of(pip.id), Some(id(2)));
    assert_eq!(
        net.nodes[1].visits().visit(pip.id).unwrap().home.id(),
        id(1)
    );
    assert!(!net.nodes[1].can_accept(transfer));
    assert!(!accept(&mut net, 1, transfer));
}

#[test]
fn a_declined_imp_bounces_and_is_not_away() {
    let mut net = chain();
    let pip = imp(100, "Pip");
    let transfer = throw(&mut net, 0, 1, &pip);
    net.nodes[1].decline(transfer, LinkDecline::Full);
    net.pump();
    assert_eq!(
        passed(&net, 0),
        vec![(transfer, PassOutcome::Declined(LinkDecline::Full))]
    );
    assert_eq!(net.nodes[0].holder_of(pip.id), None);
}

#[test]
fn a_throw_needs_a_connected_linked_device() {
    let mut net = Net::new(3);
    net.link(0, 1);
    let (now, stranger) = (net.now, id(3));
    assert!(
        net.nodes[0]
            .pass(&imp(100, "Pip"), entry(), stranger, now)
            .is_none()
    );
    assert!(
        net.nodes[0]
            .adopt(
                imp(100, "Pip").id,
                "{}",
                Default::default(),
                entry(),
                stranger,
                now
            )
            .is_none()
    );
}

#[test]
fn a_throw_interrupted_by_a_lost_connection_leaves_the_imp_at_home() {
    let mut net = chain();
    let pip = imp(100, "Pip");
    let transfer = throw(&mut net, 0, 1, &pip);
    net.cut(0, 1);
    assert_eq!(
        passed(&net, 0),
        vec![(transfer, PassOutcome::Declined(LinkDecline::Timeout))]
    );
    assert_eq!(net.nodes[0].holder_of(pip.id), None);
}

#[test]
fn a_throw_nobody_answers_times_out_and_the_imp_is_called_home() {
    let mut net = chain();
    let pip = imp(100, "Pip");
    // The receiver's app never answers.
    let transfer = throw(&mut net, 0, 1, &pip);
    net.advance(11.0);
    assert_eq!(
        passed(&net, 0),
        vec![(transfer, PassOutcome::Declined(LinkDecline::Timeout))]
    );
    assert_eq!(net.nodes[0].holder_of(pip.id), None);
    // The receiver's own wait ended too: it cannot take it now.
    assert!(!net.nodes[1].can_accept(transfer));
}

#[test]
fn a_late_took_for_an_imp_we_called_home_is_told_gone() {
    let mut net = chain();
    let pip = imp(100, "Pip");
    let transfer = throw(&mut net, 0, 1, &pip);
    net.advance(9.0);
    assert!(net.nodes[1].can_accept(transfer));
    net.advance(1.5);
    assert!(!net.nodes[1].can_accept(transfer));
    assert!(net.nodes[1].visits().visit(pip.id).is_none());
    assert_eq!(net.nodes[0].holder_of(pip.id), None);
}

#[test]
fn a_repeated_transfer_is_answered_again_and_never_taken_twice() {
    let mut net = chain();
    let pip = imp(100, "Pip");
    let transfer = throw(&mut net, 0, 1, &pip);
    assert!(accept(&mut net, 1, transfer));
    let before = net.nodes[1].visits().visits().len();
    // The same frame again, as a flaky network might.
    let card = net.nodes[0].card();
    let sent = net.nodes[0].send(
        &LinkMessage::Pass {
            transfer,
            imp: pip.clone(),
            entry: entry(),
            home: Some(card),
            ticket: Some(vec![1; 32].into()),
        },
        id(2),
    );
    assert!(sent);
    net.pump();
    assert_eq!(net.nodes[1].visits().visits().len(), before);
    assert_eq!(
        net.messages(1)
            .iter()
            .filter(|(m, _)| matches!(m, LinkMessage::Pass { .. }))
            .count(),
        1
    );
}

#[test]
fn a_third_device_claims_a_ticket_as_a_visitor_and_the_newest_holder_wins() {
    let mut net = chain();
    let pip = imp(100, "Pip");
    // 0 -> 1 (holder 1) -> 2 (holder 2). Device 2 is not linked with 0: it claims as a visitor.
    let t = throw(&mut net, 0, 1, &pip);
    assert!(accept(&mut net, 1, t));
    let t = throw(&mut net, 1, 2, &pip);
    assert!(accept(&mut net, 2, t));
    assert!(
        net.nodes[2].is_connected(id(1)),
        "the visitor reached the home"
    );
    assert_eq!(net.nodes[2].standing_of(id(1)), Some(Standing::Visitor));
    assert_eq!(net.nodes[0].holder_of(pip.id), Some(id(3)));
    // The previous holder hears it is not the holder any more.
    assert!(net.nodes[1].visits().visit(pip.id).is_none());
    // The home now answers its Imp's requests only from the new holder.
    net.take(0);
    let ask = LinkMessage::Ask {
        imp: pip.id,
        text: "hi".into(),
    };
    assert!(net.nodes[1].send(&ask, id(1)));
    net.pump();
    assert!(
        net.messages(0).is_empty(),
        "the previous holder is not the holder"
    );
    assert!(net.nodes[2].send(&ask, id(1)));
    net.pump();
    assert!(
        net.messages(0)
            .iter()
            .any(|(m, from)| matches!(m, LinkMessage::Ask { .. }) && *from == id(3))
    );
}

#[test]
fn an_imp_thrown_home_is_home_and_its_tickets_die() {
    let mut net = chain();
    let pip = imp(100, "Pip");
    let t = throw(&mut net, 0, 1, &pip);
    assert!(accept(&mut net, 1, t));
    let t = throw(&mut net, 1, 0, &pip);
    assert!(accept(&mut net, 0, t));
    assert_eq!(net.nodes[0].holder_of(pip.id), None);
    assert!(net.nodes[1].visits().visit(pip.id).is_none());
    assert!(net.nodes[0].visits().visit(pip.id).is_none());
}

#[test]
fn only_the_holder_may_ask_and_others_hear_gone() {
    let mut net = chain();
    let pip = imp(100, "Pip");
    let t = throw(&mut net, 0, 1, &pip);
    assert!(accept(&mut net, 1, t));
    net.take(0);
    net.take(1);
    // The holder (1) asks: the home passes it to the app.
    assert!(net.nodes[1].send(
        &LinkMessage::Ask {
            imp: pip.id,
            text: "hi".into()
        },
        id(1)
    ));
    net.pump();
    assert!(
        net.messages(0)
            .iter()
            .any(|(m, from)| matches!(m, LinkMessage::Ask { .. }) && *from == id(2))
    );
    // Once called home, the same request gets `gone`, not silence.
    let holder = net.nodes[0].call_home(pip.id);
    net.pump();
    assert_eq!(holder, Some(id(2)));
    assert!(net.nodes[1].visits().visit(pip.id).is_none());
    assert!(
        net.messages(1)
            .iter()
            .any(|(m, _)| matches!(m, LinkMessage::Gone { .. }))
    );
}

#[test]
fn calling_home_tells_a_holder_that_was_offline_when_it_connects() {
    let mut net = chain();
    let pip = imp(100, "Pip");
    let t = throw(&mut net, 0, 1, &pip);
    assert!(accept(&mut net, 1, t));
    net.unreachable.insert(id(1));
    net.unreachable.insert(id(2));
    net.cut(0, 1);
    net.nodes[0].call_home(pip.id);
    net.pump();
    assert_eq!(net.nodes[1].visits().visits().len(), 1);
    net.unreachable.clear();
    net.advance(5.0);
    assert!(net.nodes[1].visits().visit(pip.id).is_none());
}

#[test]
fn a_release_sent_while_offline_is_delivered_later() {
    let mut net = chain();
    let pip = imp(100, "Pip");
    let t = throw(&mut net, 0, 1, &pip);
    assert!(accept(&mut net, 1, t));
    net.unreachable.insert(id(1));
    net.unreachable.insert(id(2));
    net.cut(0, 1);
    let now = net.now;
    assert!(net.nodes[1].send_home(pip.id, now));
    net.pump();
    assert_eq!(net.nodes[1].visits().releases().len(), 1);
    assert_eq!(net.nodes[0].holder_of(pip.id), Some(id(2)));
    net.unreachable.clear();
    net.advance(5.0);
    assert_eq!(net.nodes[0].holder_of(pip.id), None);
    assert!(net.nodes[1].visits().releases().is_empty());
}

#[test]
fn forgetting_ends_the_link_on_both_sides_and_moves_the_imps_home() {
    let mut net = chain();
    let pip = imp(100, "Pip");
    let t = throw(&mut net, 0, 1, &pip);
    assert!(accept(&mut net, 1, t));
    let now = net.now;
    let forgotten = net.nodes[0].forget(id(2), now);
    net.pump();
    assert_eq!(forgotten.called_home, vec![pip.id]);
    assert!(net.nodes[0].links().is_empty());
    assert!(net.nodes[1].links().iter().all(|l| l.id() != id(1)));
    assert!(net.saw(
        1,
        |e| matches!(e, Event::Forgotten(device, _) if *device == id(1))
    ));
    assert!(
        net.nodes[1].visits().visit(pip.id).is_none(),
        "the visitor went home with its link"
    );
}

#[test]
fn forgetting_everyone_makes_a_new_door_and_old_codes_stop_working() {
    let mut net = chain();
    let old = net.nodes[1].invite(net.now);
    let before = net.nodes[1].card().door;
    let now = net.now;
    net.nodes[1].forget_everyone(now);
    net.pump();
    assert!(net.nodes[1].links().is_empty());
    assert_ne!(net.nodes[1].card().door, before);
    assert!(net.nodes[0].links().is_empty() && net.nodes[2].links().is_empty());
    net.nodes[0].join(&old, net.now);
    net.pump();
    assert!(net.saw(0, |e| matches!(e, Event::Joined { result: Err(_), .. })));
    assert!(net.nodes[1].links().is_empty());
}

#[test]
fn a_device_that_forgets_us_ends_what_forgetting_would_have() {
    let mut net = chain();
    let pip = imp(100, "Pip");
    let t = throw(&mut net, 0, 1, &pip);
    assert!(accept(&mut net, 1, t));
    // Device 1 sends the bye that means "forgotten" by forgetting 0.
    let now = net.now;
    net.nodes[1].forget(id(1), now);
    net.pump();
    assert!(net.saw(
        0,
        |e| matches!(e, Event::Forgotten(device, _) if *device == id(2))
    ));
    assert_eq!(net.nodes[0].holder_of(pip.id), None);
    assert!(net.nodes[0].links().is_empty());
}

#[test]
fn a_device_that_thinks_it_is_linked_when_we_are_not_is_told_to_forget_us() {
    let mut net = Net::new(2);
    net.link(0, 1);
    // Node 1 loses its book (a reinstall with the same id) but keeps its keys.
    let book = net.saved[1].clone().unwrap();
    let mut value: serde_json::Value = serde_json::from_slice(&book).unwrap();
    value["links"] = serde_json::json!([]);
    let mut again = Node::new(
        Some(&serde_json::to_vec(&value).unwrap()),
        "Device 2",
        LinkKind::Phone,
        id(2),
        Options::default(),
    )
    .unwrap();
    net.cut(0, 1);
    again.start(net.now);
    net.nodes[1] = again;
    net.unreachable.clear();
    net.advance(5.0);
    assert!(
        net.saw(
            0,
            |e| matches!(e, Event::Forgotten(device, _) if *device == id(2))
        ) || net.nodes[0].links().is_empty()
    );
}

#[test]
fn questions_between_imps_go_to_the_targets_home_and_forward_once() {
    let mut net = chain();
    // Devices 1, 2 and 3 of `chain`: `me` is linked with `middle`, and `middle` with `far`.
    let (me, middle, far) = (id(1), id(2), id(3));
    let asker = imp(10, "Asker");
    let target = imp(20, "Target");
    net.nodes[0].set_stage(vec![staged(10, "Asker", me)]);
    net.nodes[2].set_stage(vec![staged(20, "Target", far), staged(10, "Asker", me)]);
    net.nodes[1].set_stage(vec![staged(10, "Asker", me), staged(20, "Target", far)]);
    net.pump();
    let (qid, now) = (Uuid::from_u128(77), net.now);
    // 0 has no link with 2 but holds nothing: the asker's holder is itself, so the question cannot go.
    let first = net.nodes[0].talk(
        Ask {
            id: qid,
            from: asker.clone(),
            to: target.id,
            to_home: far,
            text: "hello?",
            holder: me,
        },
        now,
    );
    assert_eq!(first, First::Unreachable);
    // Through the middle device the holder (1) can answer for it and forward once.
    let first = net.nodes[0].talk(
        Ask {
            id: qid,
            from: asker.clone(),
            to: target.id,
            to_home: far,
            text: "hello?",
            holder: middle,
        },
        now,
    );
    assert_eq!(first, First::Via(middle));
    net.pump();
    assert!(net.messages(2).iter().any(|(m, from)| matches!(
        m,
        LinkMessage::Message {
            forwarded: true,
            ..
        }
    ) && *from == middle));
    // The target's home answers and the answer finds its way back to the asker's device.
    assert!(net.nodes[2].send(
        &LinkMessage::Answer {
            id: qid,
            text: "yes".into(),
            failed: false
        },
        middle
    ));
    net.pump();
    let back = net.messages(0).into_iter().find_map(|(m, _)| match m {
        LinkMessage::Answer { text, failed, .. } => Some((text, failed)),
        _ => None,
    });
    assert_eq!(back, Some(("yes".into(), false)));
}

#[test]
fn a_question_nobody_answers_fails() {
    let mut net = Net::new(2);
    net.link(0, 1);
    let asker = imp(10, "Asker");
    let (qid, now, far) = (Uuid::from_u128(5), net.now, id(2));
    net.nodes[1].set_stage(vec![staged(10, "Asker", id(1)), staged(20, "T", far)]);
    net.nodes[0].set_stage(vec![staged(10, "Asker", id(1))]);
    net.pump();
    assert_eq!(
        net.nodes[0].talk(
            Ask {
                id: qid,
                from: asker,
                to: id(20),
                to_home: far,
                text: "hi",
                holder: id(1),
            },
            now,
        ),
        First::Via(far)
    );
    net.take(0);
    net.advance(121.0);
    let failed = net.messages(0).into_iter().any(
        |(m, _)| matches!(m, LinkMessage::Answer { failed: true, text, .. } if text == UNREACHABLE),
    );
    assert!(failed);
}

#[test]
fn a_question_for_an_imp_is_only_put_by_what_is_on_its_screen() {
    let mut net = Net::new(2);
    net.link(0, 1);
    net.nodes[0].set_stage(vec![staged(20, "Target", id(1))]);
    net.pump();
    net.take(0);
    net.take(1);
    let (now, stranger) = (net.now, imp(99, "Stranger"));
    let first = net.nodes[1].talk(
        Ask {
            id: Uuid::from_u128(9),
            from: stranger,
            to: id(20),
            to_home: id(1),
            text: "hi",
            holder: id(2),
        },
        now,
    );
    assert_eq!(first, First::Via(id(1)));
    net.pump();
    assert!(
        !net.messages(0)
            .iter()
            .any(|(m, _)| matches!(m, LinkMessage::Message { .. })),
        "the app never hears it"
    );
    let refused = net.messages(1).into_iter().any(
        |(m, _)| matches!(m, LinkMessage::Answer { failed: true, text, .. } if text == UNREACHABLE),
    );
    assert!(refused);
}

#[test]
fn requests_for_an_imp_the_sender_does_not_hold_never_reach_the_app() {
    let mut net = Net::new(2);
    net.link(0, 1);
    net.take(0);
    assert!(net.nodes[1].send(
        &LinkMessage::Ask {
            imp: id(55),
            text: "hi".into()
        },
        id(1)
    ));
    assert!(net.nodes[1].send(
        &LinkMessage::File {
            id: id(6),
            imp: id(55),
            reference: "a.png".into()
        },
        id(1)
    ));
    assert!(net.nodes[1].send(&LinkMessage::NewChat { imp: id(55) }, id(1)));
    net.pump();
    assert!(net.messages(0).is_empty());
    assert!(net.nodes[0].is_connected(id(2)), "and the connection stays");
}

#[test]
fn a_thrown_imp_may_not_be_one_we_have_or_hold() {
    let mut net = chain();
    let pip = imp(100, "Pip");
    net.nodes[0].set_stage(vec![staged(100, "Pip", id(1))]);
    net.pump();
    net.take(0);
    let card = net.nodes[0].card();
    let sent = net.nodes[1].send(
        &LinkMessage::Pass {
            transfer: id(500),
            imp: pip.clone(),
            entry: entry(),
            home: Some(card),
            ticket: Some(vec![1; 32].into()),
        },
        id(1),
    );
    assert!(sent);
    net.pump();
    assert!(
        net.messages(0)
            .iter()
            .all(|(m, _)| !matches!(m, LinkMessage::Pass { .. }))
    );
    assert!(net.nodes[0].visits().visits().is_empty());
    // Coming home from somebody who does not hold it is refused too.
    let sent = net.nodes[1].send(
        &LinkMessage::Pass {
            transfer: id(501),
            imp: imp(101, "Other"),
            entry: entry(),
            home: None,
            ticket: None,
        },
        id(1),
    );
    assert!(sent);
    net.pump();
    assert!(
        net.messages(0)
            .iter()
            .all(|(m, _)| !matches!(m, LinkMessage::Pass { .. }))
    );
}

#[test]
fn a_device_cannot_leave_more_than_eight_throws_waiting() {
    let mut net = chain();
    for n in 0..12u128 {
        throw(&mut net, 0, 1, &imp(1_000 + n, "Pip"));
    }
    let waiting = net
        .messages(1)
        .iter()
        .filter(|(m, _)| matches!(m, LinkMessage::Pass { .. }))
        .count();
    assert_eq!(waiting, 8);
    let full = passed(&net, 0)
        .iter()
        .filter(|(_, o)| matches!(o, PassOutcome::Declined(LinkDecline::Full)))
        .count();
    assert_eq!(full, 4);
}

#[test]
fn a_connection_that_sends_too_fast_is_closed() {
    let options = Options {
        frame_burst: 20.0,
        frame_rate: 1.0,
        ..Options::default()
    };
    let mut net = Net::with(2, options);
    net.link(0, 1);
    for _ in 0..40 {
        net.nodes[1].send(&LinkMessage::Ping {}, id(1));
    }
    net.pump();
    assert!(!net.nodes[0].is_connected(id(2)));
}

#[test]
fn a_silent_connection_is_closed_and_pings_keep_a_quiet_one_alive() {
    let mut net = Net::new(2);
    net.link(0, 1);
    net.advance(120.0);
    assert!(net.nodes[0].is_connected(id(2)), "pings kept it alive");
    // Now the other side goes silent without closing.
    net.wires.clear();
    net.unreachable.insert(id(1));
    net.unreachable.insert(id(2));
    net.advance(60.0);
    assert!(!net.nodes[0].is_connected(id(2)));
}

#[test]
fn a_connection_that_never_finishes_its_handshake_is_closed() {
    let mut net = Net::new(1);
    let now = net.now;
    let conn = net.nodes[0].accepted(false, now).unwrap();
    net.nodes[0].tick(now + 11.0);
    let outputs = net.nodes[0].drain();
    assert!(
        outputs
            .iter()
            .any(|o| matches!(o, imp_engine::link::node::Output::Close { conn: c } if *c == conn))
    );
    // And garbage in the handshake closes it at once.
    let conn = net.nodes[0].accepted(false, net.now).unwrap();
    net.nodes[0].received(conn, &[0, 4, 1, 2, 3, 4], net.now);
    let outputs = net.nodes[0].drain();
    assert!(
        outputs
            .iter()
            .any(|o| matches!(o, imp_engine::link::node::Output::Close { conn: c } if *c == conn))
    );
}

#[test]
fn trust_is_per_link_and_never_for_others() {
    let mut net = chain();
    assert!(!net.nodes[1].is_trusted(id(1)));
    net.nodes[1].set_trusted(id(1), true);
    net.nodes[1].set_trusted(id(99), true);
    assert!(net.nodes[1].is_trusted(id(1)));
    assert!(!net.nodes[1].is_trusted(id(3)) && !net.nodes[1].is_trusted(id(99)));
    let ask = LinkMessage::Ask {
        imp: id(5),
        text: "x".into(),
    };
    assert!(net.nodes[1].is_trusted_message(&ask, id(1)));
    assert!(!net.nodes[1].is_trusted_message(&ask, id(3)));
    assert!(!net.nodes[1].is_trusted_message(&LinkMessage::Ping {}, id(1)));
    net.nodes[1].set_trusted(id(1), false);
    assert!(!net.nodes[1].is_trusted_message(&ask, id(1)));
}

#[test]
fn throws_nobody_answered_are_called_home_after_a_restart() {
    let mut net = chain();
    let pip = imp(100, "Pip");
    throw(&mut net, 0, 1, &pip);
    assert!(net.nodes[0].away().is_away(pip.id));
    // The app is killed with the throw in the air. The book says so.
    let book = net.nodes[0].book_bytes();
    let mut again = Node::new(
        Some(&book),
        "Device 1",
        LinkKind::Mac,
        id(1),
        Options::default(),
    )
    .unwrap();
    assert!(again.away().is_away(pip.id));
    again.start(net.now);
    assert!(!again.away().is_away(pip.id), "called home on start");
    assert_eq!(
        again.away().notices().len(),
        1,
        "the receiver will hear gone"
    );
}

#[test]
fn a_book_restores_the_same_device_and_links() {
    let mut net = Net::new(2);
    net.link(0, 1);
    let book = net.nodes[0].book_bytes();
    let again = Node::new(
        Some(&book),
        "Device 1",
        LinkKind::Mac,
        id(1),
        Options::default(),
    )
    .unwrap();
    assert_eq!(again.device().key, net.nodes[0].device().key);
    assert_eq!(again.links().len(), 1);
    assert!(
        Node::new(
            Some(b"not a book"),
            "x",
            LinkKind::Mac,
            id(1),
            Options::default()
        )
        .is_err()
    );
}

#[test]
fn a_new_node_asks_for_its_book_to_be_saved() {
    let net = Net::new(1);
    assert!(net.saved[0].is_some());
}

#[test]
fn adopting_waits_for_the_other_user_and_the_answer_is_took() {
    let mut net = Net::new(2);
    net.link(0, 1);
    let (now, to) = (net.now, id(2));
    let transfer = net.nodes[0]
        .adopt(id(100), "{}", Default::default(), entry(), to, now)
        .unwrap();
    net.pump();
    assert!(net.nodes[1].can_accept(transfer));
    // The throw timeout is ten seconds but moving in for good waits for the person.
    net.advance(60.0);
    assert!(net.nodes[1].can_accept(transfer));
    assert!(accept(&mut net, 1, transfer));
    let outcome = net.events[0].iter().find_map(|e| match e {
        Event::Passed(p) if p.kind == TransferKind::Adopt => Some(p.outcome),
        _ => None,
    });
    assert_eq!(outcome, Some(PassOutcome::Took));
}

#[test]
fn the_door_follows_who_is_connected_and_how_the_imp_came() {
    let mut net = chain();
    let pip = imp(100, "Pip");
    let t = throw(&mut net, 0, 1, &pip);
    assert!(accept(&mut net, 1, t));
    use imp_engine::link::doors::{Bounce, Door};
    // On device 1 the Imp came in by the left from device 0: the left leads back, the right on to 2.
    assert_eq!(
        net.nodes[1].door_of(pip.id, LinkSide::Left, 0.5),
        Door::To(id(1))
    );
    assert_eq!(
        net.nodes[1].door_of(pip.id, LinkSide::Right, 0.5),
        Door::To(id(3))
    );
    assert_eq!(net.nodes[1].bands_of(pip.id, LinkSide::Right).len(), 1);
    let alone = Net::new(1);
    assert_eq!(
        alone.nodes[0].door_of(pip.id, LinkSide::Left, 0.5),
        Door::Bounce(Bounce::NobodyConnected)
    );
}

#[test]
fn the_forgotten_reason_is_one_word() {
    assert_eq!(FORGOTTEN, "forgotten");
}

/// Thrown off the `exit` side of `from`, so it flies in from the other side of `to`.
fn throw_by(net: &mut Net, from: usize, to: usize, who: &LinkImp, exit: LinkSide) -> Uuid {
    let (now, target) = (net.now, dev(net, to));
    let transfer = net.nodes[from]
        .pass(
            who,
            LinkEntry::new(exit.opposite(), 0.5, 600.0),
            target,
            now,
        )
        .expect("a connected peer");
    net.pump();
    assert!(accept(net, to, transfer), "the receiver takes it");
    transfer
}

#[test]
fn imps_travel_across_four_devices_and_the_home_keeps_up() {
    use imp_engine::link::crypto::ticket_matches;
    use imp_engine::link::doors::LinkTravel;
    let mut net = Net::new(4);
    net.link(0, 1);
    let (two, three, four) = (imp(2, "Two"), imp(3, "Three"), imp(4, "Four"));
    throw_by(&mut net, 0, 1, &two, LinkSide::Left);
    throw_by(&mut net, 0, 1, &three, LinkSide::Left);
    throw_by(&mut net, 0, 1, &four, LinkSide::Right);
    // They came in by the opposite side of the one they left by.
    let (d1, d2, d3, d4) = (id(1), id(2), id(3), id(4));
    assert_eq!(
        net.nodes[1].travel_of(two.id),
        LinkTravel::Visit {
            side: LinkSide::Right,
            from: d1
        }
    );
    assert_eq!(
        net.nodes[1].travel_of(four.id),
        LinkTravel::Visit {
            side: LinkSide::Left,
            from: d1
        }
    );
    // Each claimed at its home, so the tickets are already rotated and the visitor holds the new one.
    for who in [&two, &three, &four] {
        let entry = net.nodes[0].away().entry(who.id).unwrap();
        assert_eq!(entry.generation, 2);
        let ticket = &net.nodes[1].visits().visit(who.id).unwrap().ticket.0;
        assert!(ticket_matches(ticket, &entry.ticket.0));
        assert_eq!(net.nodes[0].holder_of(who.id), Some(d2));
    }

    // Devices 2 and 3 link, and 4 links with 3.
    net.link(1, 2);
    net.link(3, 2);
    // Back by the side it came in, an Imp can only go where it came from. The other side leads on.
    assert_eq!(
        net.nodes[1].door_of(three.id, LinkSide::Right, 0.5),
        imp_engine::link::doors::Door::To(d1)
    );
    for height in [0.0, 1.0] {
        assert_eq!(
            net.nodes[1].door_of(three.id, LinkSide::Left, height),
            imp_engine::link::doors::Door::To(d3)
        );
    }
    assert_eq!(
        net.nodes[1].door_of(four.id, LinkSide::Right, 0.3),
        imp_engine::link::doors::Door::To(d3)
    );

    // Device 2 passes Imps 3 and 4 on to device 3, which is not linked with the home.
    throw_by(&mut net, 1, 2, &three, LinkSide::Left);
    throw_by(&mut net, 1, 2, &four, LinkSide::Right);
    assert_eq!(net.nodes[0].holder_of(three.id), Some(d3));
    assert_eq!(net.nodes[0].holder_of(four.id), Some(d3));
    assert_eq!(
        net.nodes[2].travel_of(three.id),
        LinkTravel::Visit {
            side: LinkSide::Right,
            from: d2
        }
    );
    assert_eq!(
        net.nodes[2].travel_of(four.id),
        LinkTravel::Visit {
            side: LinkSide::Left,
            from: d2
        }
    );
    assert!(net.nodes[2].links().iter().all(|l| l.device.id != d1));
    assert_eq!(net.nodes[2].visits().visit(three.id).unwrap().home.id(), d1);

    // Device 3 passes Imp 4 on to device 4, through the side that does not lead back.
    assert_eq!(
        net.nodes[2].door_of(four.id, LinkSide::Left, 0.5),
        imp_engine::link::doors::Door::To(d2)
    );
    throw_by(&mut net, 2, 3, &four, LinkSide::Right);

    // The home knows each Imp where it is, with the newest ticket, and answers only the holder.
    assert_eq!(net.nodes[0].holder_of(two.id), Some(d2));
    assert_eq!(net.nodes[0].holder_of(three.id), Some(d3));
    assert_eq!(net.nodes[0].holder_of(four.id), Some(d4));
    assert_eq!(net.nodes[0].away().entry(four.id).unwrap().generation, 4);
    assert_eq!(net.nodes[0].away().entry(three.id).unwrap().generation, 3);
    for (node, who) in [(1, &two), (2, &three), (3, &four)] {
        let visit = net.nodes[node].visits().visit(who.id).unwrap();
        let entry = net.nodes[0].away().entry(who.id).unwrap();
        assert!(ticket_matches(&visit.ticket.0, &entry.ticket.0));
        assert_eq!(visit.home.id(), d1);
    }
    assert!(net.nodes[0].away().authorises(d4, four.id));
    assert!(!net.nodes[0].away().authorises(d3, four.id));
    assert!(!net.nodes[0].away().authorises(d2, three.id));
}

#[test]
fn a_late_claim_with_an_old_ticket_makes_the_body_go() {
    let mut net = Net::new(3);
    net.link(0, 1);
    net.link(0, 2);
    let pip = imp(1, "Pip");
    // Thrown to 1, then called home, then thrown to 2: whatever 1 still believes is dead.
    throw_by(&mut net, 0, 1, &pip, LinkSide::Left);
    let old = net.nodes[1]
        .visits()
        .visit(pip.id)
        .unwrap()
        .ticket
        .0
        .clone();
    assert_eq!(net.nodes[0].call_home(pip.id), Some(id(2)));
    net.pump();
    throw_by(&mut net, 0, 2, &pip, LinkSide::Left);
    assert_eq!(net.nodes[0].holder_of(pip.id), Some(id(3)));
    // Device 2 never heard (it was told gone above), and a claim it sends late with the old ticket is refused.
    net.take(1);
    let late = LinkMessage::Claim {
        imp: pip.id,
        ticket: old.into(),
    };
    net.nodes[1].send(&late, id(1));
    net.pump();
    assert!(net.nodes[1].visits().visit(pip.id).is_none());
    assert_eq!(net.nodes[0].holder_of(pip.id), Some(id(3)));
}

#[test]
fn a_visitor_without_a_valid_claim_is_turned_away_after_the_grace() {
    use imp_engine::link::book::LinkBook;
    let options = Options {
        visitor_grace: 0.3,
        ..Options::default()
    };
    let mut net = Net::with(2, options.clone());
    // The guest believes an Imp of the host's is visiting, with a ticket the host never gave.
    let mut book = LinkBook::new(id(2), [2; 32], [9; 32]);
    let home = net.nodes[0].card();
    assert!(
        book.visits
            .arrive(&imp(1, "Pip"), &entry(), id(5), &home, &[7; 32])
    );
    let mut guest = Node::new(
        Some(&book.write()),
        "Device 2",
        LinkKind::Phone,
        id(2),
        options,
    )
    .unwrap();
    guest.set_port(Some(imp_engine::link::PORT));
    net.nodes[1] = guest;
    let now = net.now;
    net.nodes[1].start(now);
    net.pump();
    assert!(net.saw(
        0,
        |e| matches!(e, Event::Connected(d, Standing::Visitor) if d.id == id(2))
    ));
    // Its claim is refused: `gone`, and the body is dropped.
    assert!(
        net.messages(1)
            .iter()
            .any(|(m, from)| matches!(m, LinkMessage::Gone { .. }) && *from == id(1))
    );
    assert!(net.nodes[1].visits().visits().is_empty());
    net.advance(2.0);
    assert!(net.saw(0, |e| matches!(e, Event::Disconnected(d) if *d == id(2))));
    assert!(net.nodes[0].links().is_empty() && net.nodes[0].away().entry(id(1)).is_none());
}

#[test]
fn an_imp_of_the_holder_asks_the_visitor_it_holds_even_when_only_visiting_its_home() {
    let mut net = chain();
    let (visitor, local) = (imp(100, "Pip"), imp(7, "Local"));
    let t = throw(&mut net, 0, 1, &visitor);
    assert!(accept(&mut net, 1, t));
    let t = throw(&mut net, 1, 2, &visitor);
    assert!(accept(&mut net, 2, t));
    assert_eq!(net.nodes[0].holder_of(visitor.id), Some(id(3)));
    // Device 3's own Imp and the visitor share its screen, and device 1 hears about it though device 3
    // only visits it.
    net.nodes[2].set_stage(vec![staged(100, "Pip", id(1)), staged(7, "Local", id(3))]);
    net.pump();
    assert_eq!(net.nodes[0].stage_of(id(3)).len(), 2);
    net.take(0);
    let (q, now) = (Uuid::from_u128(5), net.now);
    let first = net.nodes[2].talk(
        Ask {
            id: q,
            from: local,
            to: visitor.id,
            to_home: id(1),
            text: "hello?",
            holder: id(3),
        },
        now,
    );
    assert_eq!(first, First::Via(id(1)));
    net.pump();
    assert!(net.messages(0).iter().any(
        |(m, from)| matches!(m, LinkMessage::Message { id, .. } if *id == q) && *from == id(3)
    ));
}

#[test]
fn two_imps_that_swapped_devices_still_reach_each_other() {
    let mut net = Net::new(2);
    net.link(0, 1);
    // A is device 1's, B is device 2's. A goes to device 2 and B to device 1.
    let (a, b) = (imp(10, "A"), imp(20, "B"));
    let t = throw(&mut net, 0, 1, &a);
    assert!(accept(&mut net, 1, t));
    let t = throw(&mut net, 1, 0, &b);
    assert!(accept(&mut net, 0, t));
    net.nodes[0].set_stage(vec![staged(20, "B", id(2))]);
    net.nodes[1].set_stage(vec![staged(10, "A", id(1))]);
    net.pump();
    net.take(0);
    net.take(1);
    let now = net.now;
    // A (thinking at device 1, out on device 2) asks B, which device 1 holds: B's home lets its holder in.
    let first = net.nodes[0].talk(
        Ask {
            id: Uuid::from_u128(1),
            from: a.clone(),
            to: b.id,
            to_home: id(2),
            text: "hi B",
            holder: id(2),
        },
        now,
    );
    assert_eq!(first, First::Via(id(2)));
    net.pump();
    assert!(
        net.messages(1)
            .iter()
            .any(|(m, from)| matches!(m, LinkMessage::Message { .. }) && *from == id(1))
    );
    // And the other way round.
    let first = net.nodes[1].talk(
        Ask {
            id: Uuid::from_u128(2),
            from: b,
            to: a.id,
            to_home: id(1),
            text: "hi A",
            holder: id(1),
        },
        now,
    );
    assert_eq!(first, First::Via(id(1)));
    net.pump();
    assert!(
        net.messages(0)
            .iter()
            .any(|(m, from)| matches!(m, LinkMessage::Message { .. }) && *from == id(2))
    );
}

#[test]
fn forgetting_a_device_after_a_swap_brings_ours_home_and_sends_its_visitor_home() {
    let mut net = Net::new(2);
    net.link(0, 1);
    let (a, b) = (imp(10, "Imp"), imp(20, "Pip"));
    let t = throw(&mut net, 0, 1, &a);
    assert!(accept(&mut net, 1, t));
    let t = throw(&mut net, 1, 0, &b);
    assert!(accept(&mut net, 0, t));
    // The other device is gone for good (its app deleted): it never says anything again.
    let now = net.now;
    net.nodes[1].stop(now);
    net.pump();
    let forgotten = net.nodes[0].forget(id(2), now);
    assert_eq!(forgotten.called_home, vec![a.id]);
    assert_eq!(forgotten.sent_home, vec![b.id]);
    assert!(net.nodes[0].away().entry(a.id).is_none());
    assert!(net.nodes[0].visits().visits().is_empty());
}
