//! Live Hop (opt-in): nodes whose only route to each other is a running Hop, over TCP.
//!
//!   cargo run -p imp-hop &                      (listens on HOP_ADDR, 0.0.0.0:4677 by default)
//!   IMP_HOP=127.0.0.1:4677 cargo test -p imp-cli --test hop_live -- --ignored
//!
//! The nodes have no host names, so a guest can only reach its host through the Hop. The Hop limits each
//! address to 30 new connections a minute by default: repeated runs against one Hop need
//! HOP_PER_IP_PER_MINUTE raised (for example 100000 on a local test Hop). Everything waits for events or
//! conditions with a timeout, never for a fixed time.

use imp_cli::link::Runner;
use imp_core::link::card::LinkKind;
use imp_core::link::hop::HopAddress;
use imp_core::link::messages::{LinkEntry, LinkImp, LinkMessage, LinkSide};
use imp_core::link::node::{Event, JoinError, Node, Options, PassOutcome};
use imp_core::link::visits::Visits;
use std::time::{Duration, Instant};
use tokio::net::TcpListener;
use tokio::sync::mpsc;
use uuid::Uuid;

const WAIT: Duration = Duration::from_secs(15);

fn hop() -> HopAddress {
    let text =
        std::env::var("IMP_HOP").expect("IMP_HOP names the running Hop, like 127.0.0.1:4677");
    HopAddress::parse(&text).expect("IMP_HOP is host:port")
}

struct Device {
    id: Uuid,
    runner: Runner,
    events: mpsc::UnboundedReceiver<Event>,
}

async fn device(n: u128, kind: LinkKind, hop: &HopAddress) -> Device {
    let id = Uuid::from_u128(n);
    let options = Options {
        visitor_grace: 0.6,
        handshake_timeout: 10.0,
        transfer_timeout: 5.0,
        retry_start: 0.1,
        retry_longest: 0.4,
        join_timeout: 12.0,
        ..Options::default()
    };
    let mut node = Node::new(None, &format!("Hop device {n}"), kind, id, options).unwrap();
    // No host names: nothing but the Hop leads to this device.
    node.set_hosts(Vec::new());
    node.set_server(Some(hop.clone()));
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let (tx, events) = mpsc::unbounded_channel();
    let runner = Runner::start(node, listener, tx, |_| Ok(())).unwrap();
    Device { id, runner, events }
}

impl Device {
    async fn take(&mut self, wanted: impl Fn(&Event) -> bool) -> Option<Event> {
        tokio::time::timeout(WAIT, async {
            loop {
                let event = self.events.recv().await?;
                if wanted(&event) {
                    return Some(event);
                }
            }
        })
        .await
        .ok()
        .flatten()
    }

    async fn until<T: Send + 'static>(
        &self,
        check: impl Fn(&mut Node) -> Option<T> + Send + Clone + 'static,
    ) -> Option<T> {
        let end = Instant::now() + WAIT;
        while Instant::now() < end {
            let check = check.clone();
            if let Some(Some(found)) = self.runner.with(move |n, _| check(n)).await {
                return Some(found);
            }
            tokio::time::sleep(Duration::from_millis(20)).await;
        }
        None
    }

    async fn stop(self) {
        self.runner.stop().await;
    }
}

fn pip() -> LinkImp {
    LinkImp {
        id: Uuid::from_u128(1000),
        name: "Pip".into(),
        hue: 0.4,
        scale: 1.0,
        traits: Default::default(),
    }
}

/// `guest` scans a fresh code of `host`, over the Hop. Both end up connected as peers.
async fn link(host: &mut Device, guest: &mut Device) {
    let invite = host.runner.with(|n, now| n.invite(now)).await.unwrap();
    guest
        .runner
        .with(move |n, now| n.join(&invite, now))
        .await
        .unwrap();
    let Some(Event::Joined { result, .. }) =
        guest.take(|e| matches!(e, Event::Joined { .. })).await
    else {
        panic!("the guest never heard how the join ended");
    };
    assert_eq!(result.expect("joined").id, host.id);
    let (h, g) = (host.id, guest.id);
    assert!(
        guest
            .until(move |n| n.is_connected(h).then_some(()))
            .await
            .is_some()
    );
    assert!(
        host.until(move |n| n.is_connected(g).then_some(()))
            .await
            .is_some()
    );
    assert!(
        guest
            .runner
            .with(move |n, _| n.is_through_hop(h))
            .await
            .unwrap(),
        "the guest reached its host some other way than the Hop"
    );
}

/// `from` throws `imp` to `to`; `to` takes it. Returns the transfer.
async fn throw(imp: &LinkImp, from: &mut Device, to: &mut Device) -> Uuid {
    let (imp, target) = (imp.clone(), to.id);
    let transfer = from
        .runner
        .with(move |n, now| {
            n.pass(
                &imp,
                LinkEntry::new(LinkSide::Right, 0.5, 900.0),
                target,
                now,
            )
        })
        .await
        .unwrap()
        .expect("a connected linked device");
    let arrived = to
        .take(|e| matches!(e, Event::Message(LinkMessage::Pass { transfer: t, .. }, _) if *t == transfer))
        .await;
    assert!(arrived.is_some(), "the thrown Imp never crossed the Hop");
    assert!(
        to.runner
            .with(move |n, now| n.accept(transfer, now))
            .await
            .unwrap()
    );
    transfer
}

async fn took(device: &mut Device, transfer: Uuid) {
    let event = device
        .take(|e| matches!(e, Event::Passed(p) if p.transfer == transfer))
        .await;
    let Some(Event::Passed(passed)) = event else {
        panic!("no answer to the throw");
    };
    assert_eq!(passed.outcome, PassOutcome::Took);
}

fn visit_home(visits: &Visits, imp: Uuid) -> Option<Uuid> {
    visits.visit(imp).map(|v| v.home.id())
}

#[tokio::test]
#[ignore = "needs a running Hop: IMP_HOP=host:port cargo test -p imp-cli --test hop_live -- --ignored"]
async fn a_guest_joins_its_host_through_the_hop_and_an_imp_passes() {
    let hop = hop();
    let mut host = device(1, LinkKind::Mac, &hop).await;
    let mut guest = device(2, LinkKind::Phone, &hop).await;
    link(&mut host, &mut guest).await;

    let imp = pip();
    let transfer = throw(&imp, &mut host, &mut guest).await;
    took(&mut host, transfer).await;
    let (id, home) = (imp.id, host.id);
    assert!(
        guest
            .until(move |n| (visit_home(n.visits(), id) == Some(home)).then_some(()))
            .await
            .is_some()
    );

    // Thrown back over the same Hop, it is home again.
    let transfer = throw(&imp, &mut guest, &mut host).await;
    took(&mut guest, transfer).await;
    host.stop().await;
    guest.stop().await;
}

#[tokio::test]
#[ignore = "needs a running Hop: IMP_HOP=host:port cargo test -p imp-cli --test hop_live -- --ignored"]
async fn a_visitor_claims_a_ticket_through_the_hop() {
    let hop = hop();
    let mut a = device(11, LinkKind::Mac, &hop).await;
    let mut b = device(12, LinkKind::Phone, &hop).await;
    let mut c = device(13, LinkKind::Phone, &hop).await;
    link(&mut a, &mut b).await;
    link(&mut c, &mut b).await;

    // A's Imp goes to B, then B passes it on to C: C holds it, and A is its home.
    let imp = pip();
    let transfer = throw(&imp, &mut a, &mut b).await;
    took(&mut a, transfer).await;
    // B's own claim rotates the ticket first: wait until B holds the new one, or it would pass on a stale one.
    let id = imp.id;
    assert!(
        a.until(move |n| (n.away().entry(id).map(|e| e.generation) == Some(2)).then_some(()))
            .await
            .is_some()
    );
    let hash = a
        .runner
        .with(move |n, _| n.away().entry(id).map(|e| e.ticket.0.clone()))
        .await
        .unwrap()
        .unwrap();
    assert!(
        b.until(move |n| {
            let ticket = n.visits().visit(id)?.ticket.0.clone();
            imp_core::link::crypto::ticket_matches(&ticket, &hash).then_some(())
        })
        .await
        .is_some(),
        "the home's new ticket never reached the visitor"
    );
    let transfer = throw(&imp, &mut b, &mut c).await;
    took(&mut b, transfer).await;

    // C reaches A as a visitor, over the Hop, and claims: A rotates the ticket and C is the holder.
    let (id, holder) = (imp.id, c.id);
    assert!(
        a.until(move |n| (n.holder_of(id) == Some(holder)).then_some(()))
            .await
            .is_some(),
        "the visitor's claim never reached the home"
    );
    let generation = a
        .runner
        .with(move |n, _| n.away().entry(id).map(|e| e.generation))
        .await
        .unwrap();
    assert_eq!(generation, Some(3));
    let hash = a
        .runner
        .with(move |n, _| n.away().entry(id).map(|e| e.ticket.0.clone()))
        .await
        .unwrap()
        .unwrap();
    let ticket = c
        .until(move |n| n.visits().visit(id).map(|v| v.ticket.0.clone()))
        .await
        .unwrap();
    assert!(imp_core::link::crypto::ticket_matches(&ticket, &hash));
    a.stop().await;
    b.stop().await;
    c.stop().await;
}

#[tokio::test]
#[ignore = "needs a running Hop: IMP_HOP=host:port cargo test -p imp-cli --test hop_live -- --ignored"]
async fn a_guest_with_a_wrong_door_is_turned_away_by_the_hop() {
    let hop = hop();
    let mut host = device(21, LinkKind::Mac, &hop).await;
    let mut guest = device(22, LinkKind::Phone, &hop).await;
    let mut other = device(23, LinkKind::Phone, &hop).await;

    // The gate is derived from the door key, so a wrong door cannot get past the Hop.
    let mut wrong = host.runner.with(|n, now| n.invite(now)).await.unwrap();
    wrong.door = imp_core::link::crypto::random_key().to_vec().into();
    guest
        .runner
        .with(move |n, now| n.join(&wrong, now))
        .await
        .unwrap();
    let Some(Event::Joined { result, .. }) =
        guest.take(|e| matches!(e, Event::Joined { .. })).await
    else {
        panic!("the join never ended");
    };

    // The Hop turned the guest away, so no route worked.
    assert_eq!(result, Err(JoinError::Unreachable));
    let (h, g) = (host.id, guest.id);
    assert!(
        !guest
            .runner
            .with(move |n, _| n.is_connected(h))
            .await
            .unwrap()
    );
    assert!(
        !host
            .runner
            .with(move |n, _| n.is_connected(g))
            .await
            .unwrap()
    );

    // The host kept waiting: the right door still gets through.
    link(&mut host, &mut other).await;
    host.stop().await;
    guest.stop().await;
    other.stop().await;
}
