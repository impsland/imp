//! A device that `imp qr` runs and a second node from the core join each other over real loopback sockets,
//! directly and through a Hop, with the adapter the command line app uses on both ends.

use imp_chat::link::device::{DeviceOptions, make_node};
use imp_chat::link::{Runner, SeedStore, local_hosts};
use imp_engine::link::LinkInvite;
use imp_engine::link::card::LinkKind;
use imp_engine::link::hop::HopAddress;
use imp_engine::link::node::{Event, Node, Options};
use std::sync::{Arc, Mutex};
use std::time::Duration;
use tokio::net::TcpListener;
use tokio::sync::{mpsc, oneshot};
use uuid::Uuid;

/// A key store in memory, so the tests never touch the real one.
#[derive(Default)]
struct Memory(Mutex<Option<String>>);

impl SeedStore for Memory {
    fn get(&self) -> Result<Option<String>, String> {
        Ok(self.0.lock().unwrap().clone())
    }
    fn set(&self, seed: &str) -> Result<(), String> {
        *self.0.lock().unwrap() = Some(seed.to_string());
        Ok(())
    }
}

fn memory() -> Arc<dyn SeedStore> {
    Arc::new(Memory::default())
}

struct Side {
    runner: Runner,
    events: mpsc::UnboundedReceiver<Event>,
}

async fn run(node: Node) -> Side {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let (tx, events) = mpsc::unbounded_channel();
    let runner = Runner::start(node, listener, tx, |_| Ok(())).unwrap();
    Side { runner, events }
}

async fn heard(side: &mut Side, wanted: impl Fn(&Event) -> bool) -> Event {
    tokio::time::timeout(Duration::from_secs(15), async {
        loop {
            let event = side.events.recv().await.expect("the node stopped");
            if wanted(&event) {
                return event;
            }
        }
    })
    .await
    .expect("the event never came")
}

fn dir(name: &str) -> std::path::PathBuf {
    let dir = std::env::temp_dir().join(format!("imp-chat-link-{name}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    dir
}

fn options(name: &str) -> DeviceOptions {
    DeviceOptions {
        name: Some(name.into()),
        hosts: vec!["127.0.0.1".into()],
        hop: None,
        data_dir: dir(name),
        ..DeviceOptions::default()
    }
}

fn phone() -> Node {
    Node::new(
        None,
        "Pocket",
        LinkKind::Phone,
        Uuid::from_u128(7),
        Options::default(),
    )
    .unwrap()
}

#[tokio::test]
async fn a_device_scans_the_code_of_imp_qr_and_joins() {
    let (node, _) = make_node(&options("direct"), memory()).unwrap();
    let mut host = run(node).await;
    let invite = host.runner.with(|n, now| n.invite(now)).await.unwrap();
    let code = invite.url();
    assert!(code.starts_with("implink://join?"));

    // The guest reads the text a camera would give it.
    let scanned = LinkInvite::parse(&code).expect("the apps accept it");
    let mut guest = run(phone()).await;
    guest
        .runner
        .with(move |n, now| n.join(&scanned, now))
        .await
        .unwrap();

    let joined = heard(&mut guest, |e| matches!(e, Event::Joined { .. })).await;
    let Event::Joined { result, .. } = joined else {
        unreachable!()
    };
    assert_eq!(result.expect("joined").name, host_name(&invite));
    heard(
        &mut host,
        |e| matches!(e, Event::Linked(d) if d.name == "Pocket"),
    )
    .await;
    assert_eq!(host.runner.with(|n, _| n.links().len()).await, Some(1));
    assert_eq!(guest.runner.with(|n, _| n.links().len()).await, Some(1));
    host.runner.stop().await;
    guest.runner.stop().await;
}

fn host_name(invite: &LinkInvite) -> String {
    invite.device.name.clone()
}

#[tokio::test]
async fn a_device_joins_through_a_hop() {
    // The Hop listens on every interface, because the code gives it out under this computer's own
    // address (see below), not under 127.0.0.1.
    let hop = TcpListener::bind("0.0.0.0:0").await.unwrap();
    let hop_port = hop.local_addr().unwrap().port();

    // With no host names given, make_node uses this computer's own addresses, Wi-Fi first. The host's
    // link listener stays on loopback, so the guest can only come in through the Hop.
    let Some(own) = local_hosts().into_iter().next() else {
        eprintln!("skipped: this computer has no network address to give the Hop out under");
        return;
    };
    // A computer whose only address is a VPN tunnel may not reach itself through it. That says nothing
    // about the code, so the test stops there.
    if std::net::TcpStream::connect_timeout(
        &format!("{own}:{hop_port}").parse().unwrap(),
        Duration::from_secs(2),
    )
    .is_err()
    {
        eprintln!("skipped: this computer cannot reach its own address {own} (a VPN tunnel?)");
        return;
    }
    let (stop, stopped) = oneshot::channel::<()>();
    let relay = tokio::spawn(imp_hop::run(hop, imp_hop::Config::default(), async move {
        let _ = stopped.await;
    }));

    let mut pair = options("hop");
    pair.hosts = Vec::new();
    pair.hop = Some(format!("127.0.0.1:{hop_port}"));
    let (node, _) = make_node(&pair, memory()).unwrap();
    let mut host = run(node).await;
    let invite = host.runner.with(|n, now| n.invite(now)).await.unwrap();
    // On the device that scans the code, 127.0.0.1 would be that device itself, so a Hop on this
    // computer's loopback is given out under the computer's own address (LinkRoutes::lenient).
    assert_eq!(
        invite.routes.hop,
        HopAddress::new(&own, hop_port).map(|h| h.text())
    );

    let mut guest = run(phone()).await;
    let scanned = LinkInvite::parse(&invite.url()).unwrap();
    guest
        .runner
        .with(move |n, now| n.join(&scanned, now))
        .await
        .unwrap();
    let joined = heard(&mut guest, |e| matches!(e, Event::Joined { .. })).await;
    let Event::Joined { result, .. } = joined else {
        unreachable!()
    };
    result.expect("joined through the Hop");
    heard(&mut host, |e| matches!(e, Event::Linked(_))).await;
    let device = guest.runner.with(|n, _| n.links()[0].id()).await.unwrap();
    assert_eq!(
        guest
            .runner
            .with(move |n, _| n.is_through_hop(device))
            .await,
        Some(true)
    );
    host.runner.stop().await;
    guest.runner.stop().await;
    let _ = stop.send(());
    relay.await.unwrap();
}

#[test]
fn the_book_is_private_and_the_device_stays_the_same() {
    let pair = options("book");
    let store = memory();
    let (first, book) = make_node(&pair, store.clone()).unwrap();
    book.save(&first.book_bytes()).unwrap();
    assert!(
        !std::fs::read_to_string(book.path())
            .unwrap()
            .contains("seed")
    );
    let (second, _) = make_node(&pair, store).unwrap();
    assert_eq!(first.device().id, second.device().id);
    assert_eq!(first.device().key, second.device().key);
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let mode = std::fs::metadata(book.path()).unwrap().permissions().mode();
        assert_eq!(mode & 0o777, 0o600);
    }
    let _ = std::fs::remove_dir_all(&pair.data_dir);
}
