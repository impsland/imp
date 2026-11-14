//! This computer as a device, against a phone made from the core's own node, over real loopback sockets and a
//! mock model service. An Imp of the computer goes to the phone, answers what the phone asks while it is
//! there, and comes back with its conversation. An Imp of the phone visits the computer and answers through
//! its home. Imps message each other across the two. No real service or key store is used.

use imp_cli::link::device::{Device, DeviceOptions, Update};
use imp_cli::link::{Runner, SeedStore};
use imp_core::link::card::LinkKind;
use imp_core::link::node::{Event, Node, Options};
use imp_core::link::{LinkEntry, LinkImp, LinkMessage, LinkSide, LinkStaged, LinkTraits, LinkTurn};
use imp_core::{ChatMessage, Role};
use std::path::PathBuf;
use std::sync::{Arc, Mutex};
use std::time::Duration;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpListener;
use tokio::sync::mpsc;
use uuid::Uuid;

const WAIT: Duration = Duration::from_secs(20);

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

/// An OpenAI-compatible service that streams `reply` to every request.
async fn mock(reply: &'static str) -> String {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let url = format!("http://{}/v1", listener.local_addr().unwrap());
    tokio::spawn(async move {
        while let Ok((mut socket, _)) = listener.accept().await {
            tokio::spawn(async move {
                let mut data = Vec::new();
                let mut buf = [0u8; 8192];
                while !String::from_utf8_lossy(&data).contains("\"messages\"")
                    || !data.ends_with(b"}")
                {
                    let n = socket.read(&mut buf).await.unwrap_or(0);
                    if n == 0 {
                        break;
                    }
                    data.extend_from_slice(&buf[..n]);
                }
                let body = format!(
                    "data: {{\"choices\":[{{\"delta\":{{\"content\":\"{reply}\"}}}}]}}\n\ndata: {{\"choices\":[{{\"delta\":{{}},\"finish_reason\":\"stop\"}}]}}\n\ndata: [DONE]\n\n"
                );
                let _ = socket.write_all(format!("HTTP/1.1 200 OK\r\ncontent-type: text/event-stream\r\nconnection: close\r\n\r\n{body}").as_bytes()).await;
                let _ = socket.shutdown().await;
            });
        }
    });
    url
}

fn folder(name: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!("imp-cli-device-{name}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    dir
}

/// A computer with one Imp, `linktest`, whose brain is the mock.
async fn computer(name: &str) -> (Device, DeviceOptions) {
    let dir = folder(name);
    let url = mock("Hello from the computer").await;
    let config = dir.join("config.toml");
    std::fs::write(
        &config,
        format!(
            "api_key_env = \"IMP_TEST_NO_KEY\"\n[imps.linktest]\npersonality = \"Kind.\"\nbase_url = \"{url}\"\nmodel = \"m\"\n"
        ),
    )
    .unwrap();
    let options = DeviceOptions {
        name: Some("Desk".into()),
        hosts: vec!["127.0.0.1".into()],
        data_dir: dir.join("data"),
        config,
        workspace: Some(dir),
        ..DeviceOptions::default()
    };
    let device = Device::start(&options, Arc::new(Memory::default()))
        .await
        .unwrap();
    (device, options)
}

struct Phone {
    runner: Runner,
    events: mpsc::UnboundedReceiver<Event>,
    id: Uuid,
}

async fn phone() -> Phone {
    let node = Node::new(
        None,
        "Pocket",
        LinkKind::Phone,
        Uuid::from_u128(77),
        Options::default(),
    )
    .unwrap();
    let id = node.device().id;
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let (tx, events) = mpsc::unbounded_channel();
    let runner = Runner::start(node, listener, tx, |_| Ok(())).unwrap();
    Phone { runner, events, id }
}

/// Runs the computer until the phone hears what it waits for.
async fn phone_hears(
    device: &mut Device,
    phone: &mut Phone,
    wanted: impl Fn(&Event) -> bool,
) -> Event {
    tokio::time::timeout(WAIT, async {
        loop {
            tokio::select! {
                event = phone.events.recv() => {
                    let event = event.expect("the phone stopped");
                    if wanted(&event) {
                        return event;
                    }
                }
                _ = device.next() => {}
            }
        }
    })
    .await
    .expect("the phone never heard it")
}

/// Runs the computer (and the phone, so its events don't pile up) until the computer says what is wanted.
async fn computer_says(
    device: &mut Device,
    phone: &mut Phone,
    wanted: impl Fn(&Update) -> bool,
) -> Update {
    tokio::time::timeout(WAIT, async {
        loop {
            tokio::select! {
                update = device.next() => {
                    if wanted(&update) {
                        return update;
                    }
                }
                Some(_) = phone.events.recv() => {}
            }
        }
    })
    .await
    .expect("the computer never said it")
}

/// Runs both sides until `done` holds for the computer.
async fn until(device: &mut Device, phone: &mut Phone, done: impl Fn(&Device) -> bool) {
    tokio::time::timeout(WAIT, async {
        while !done(device) {
            tokio::select! {
                _ = device.next() => {}
                _ = phone.events.recv() => {}
                _ = tokio::time::sleep(Duration::from_millis(20)) => {}
            }
        }
    })
    .await
    .expect("it never happened");
}

async fn link(device: &mut Device, phone: &mut Phone) {
    let invite = device.invite().await.unwrap();
    phone
        .runner
        .with(move |n, now| n.join(&invite, now))
        .await
        .unwrap();
    phone_hears(device, phone, |e| {
        matches!(e, Event::Joined { result: Ok(_), .. })
    })
    .await;
    // The computer knows the phone as a connected peer.
    tokio::time::timeout(WAIT, async {
        loop {
            if device
                .peers()
                .iter()
                .any(|p| p.name == "Pocket" && p.connected)
            {
                return;
            }
            tokio::select! {
                _ = device.next() => {}
                _ = phone.events.recv() => {}
            }
        }
    })
    .await
    .expect("the computer never saw the phone");
}

fn pocket_imp() -> LinkImp {
    LinkImp {
        id: Uuid::from_u128(900),
        name: "Pebble".into(),
        hue: 0.3,
        scale: 1.0,
        traits: LinkTraits::default(),
    }
}

#[tokio::test]
async fn an_imp_goes_to_the_phone_answers_there_and_comes_back_with_its_conversation() {
    let (mut device, _options) = computer("travel").await;
    let mut phone = phone().await;
    link(&mut device, &mut phone).await;
    let peer = device.find_peer("pocket").unwrap();
    device
        .send_imp(
            "linktest",
            vec![
                ChatMessage::user("before"),
                ChatMessage::assistant("earlier answer"),
            ],
            &peer,
        )
        .await
        .unwrap();

    // The phone takes it: it is a visitor there, thinking on the computer.
    let Event::Message(
        LinkMessage::Pass {
            transfer,
            imp,
            home,
            ..
        },
        _,
    ) = phone_hears(&mut device, &mut phone, |e| {
        matches!(e, Event::Message(LinkMessage::Pass { .. }, _))
    })
    .await
    else {
        unreachable!()
    };
    assert_eq!(imp.name, "linktest");
    assert!(home.is_some(), "a visit carries its home's card");
    let accepted = phone
        .runner
        .with(move |n, now| n.accept(transfer, now))
        .await;
    assert_eq!(accepted, Some(true));
    let update = computer_says(&mut device, &mut phone, |u| {
        matches!(u, Update::Away { .. })
    })
    .await;
    assert_eq!(
        update,
        Update::Away {
            imp: "linktest".into(),
            device: "Pocket".into()
        }
    );
    assert_eq!(device.away_on(imp.id).as_deref(), Some("Pocket"));

    // The phone is told what it needs to show it, including the conversation so far.
    let Event::Message(LinkMessage::Chat { turns, .. }, _) =
        phone_hears(&mut device, &mut phone, |e| {
            matches!(e, Event::Message(LinkMessage::Chat { .. }, _))
        })
        .await
    else {
        unreachable!()
    };
    assert_eq!(turns.len(), 1);
    assert_eq!(turns[0].request, "before");

    // What the phone asks, the computer answers with the Imp's own model.
    let (id, home_id) = (imp.id, device_id(&device, &phone).await);
    phone
        .runner
        .with(move |n, _| {
            n.send(
                &LinkMessage::Ask {
                    imp: id,
                    text: "How are you?".into(),
                },
                home_id,
            )
        })
        .await;
    let turns: Vec<LinkTurn> = loop {
        let Event::Message(LinkMessage::Chat { turns, .. }, _) =
            phone_hears(&mut device, &mut phone, |e| {
                matches!(e, Event::Message(LinkMessage::Chat { .. }, _))
            })
            .await
        else {
            unreachable!()
        };
        if turns.len() == 2 {
            break turns;
        }
    };
    assert_eq!(turns[1].request, "How are you?");
    assert_eq!(turns[1].reply, "Hello from the computer");
    assert!(!turns[1].failed);

    // Thrown back, it comes home with everything that was said.
    let look = imp.clone();
    let to = home_id;
    phone
        .runner
        .with(move |n, now| n.pass(&look, LinkEntry::new(LinkSide::Left, 0.5, 0.0), to, now))
        .await
        .flatten()
        .expect("the phone throws it back");
    let Update::CameHome {
        imp: name,
        messages,
    } = computer_says(&mut device, &mut phone, |u| {
        matches!(u, Update::CameHome { .. })
    })
    .await
    else {
        unreachable!()
    };
    assert_eq!(name, "linktest");
    let said: Vec<(Role, &str)> = messages
        .iter()
        .map(|m| (m.role, m.content.as_str()))
        .collect();
    assert_eq!(
        said,
        [
            (Role::User, "before"),
            (Role::Assistant, "earlier answer"),
            (Role::User, "How are you?"),
            (Role::Assistant, "Hello from the computer"),
        ]
    );
    assert_eq!(device.away_on(imp.id), None);
    phone.runner.stop().await;
    device.stop().await;
}

/// The computer's id, as the phone knows it from the link.
async fn device_id(_device: &Device, phone: &Phone) -> Uuid {
    phone.runner.with(|n, _| n.links()[0].id()).await.unwrap()
}

#[tokio::test]
async fn an_imp_of_the_phone_visits_the_computer_and_answers_through_its_home() {
    let (mut device, _options) = computer("visit").await;
    let mut phone = phone().await;
    link(&mut device, &mut phone).await;
    let desk = device_id(&device, &phone).await;
    let pebble = pocket_imp();
    let look = pebble.clone();
    phone
        .runner
        .with(move |n, now| n.pass(&look, LinkEntry::new(LinkSide::Right, 0.5, 0.0), desk, now))
        .await
        .flatten()
        .expect("thrown");
    let note = computer_says(
        &mut device,
        &mut phone,
        |u| matches!(u, Update::Note(t) if t.contains("Pebble")),
    )
    .await;
    assert!(matches!(note, Update::Note(t) if t.contains("came over from Pocket")));
    let visitor = device.visitor(pebble.id).expect("it visits");
    assert_eq!(visitor.home_name, "Pocket");

    // Its home says it is awake, and the computer asks it something: the question goes to the phone.
    let id = pebble.id;
    phone
        .runner
        .with(move |n, _| {
            n.send(
                &LinkMessage::Brain {
                    imp: id,
                    ready: true,
                    tools: Some(false),
                },
                desk,
            )
        })
        .await;
    until(&mut device, &mut phone, |d| {
        d.visitor(id).is_some_and(|v| v.awake)
    })
    .await;
    device.ask_visitor(id, "Hi Pebble").await.unwrap();
    let Event::Message(LinkMessage::Ask { text, .. }, _) =
        phone_hears(&mut device, &mut phone, |e| {
            matches!(e, Event::Message(LinkMessage::Ask { .. }, _))
        })
        .await
    else {
        unreachable!()
    };
    assert_eq!(text, "Hi Pebble");

    // The home's chat shows on the computer.
    let turn = LinkTurn {
        id: Uuid::from_u128(5),
        date: 1.0,
        request: "Hi Pebble".into(),
        from: None,
        reply: "Hi from the pocket".into(),
        failed: false,
        steps: vec![],
    };
    phone
        .runner
        .with(move |n, _| {
            n.send(
                &LinkMessage::Chat {
                    imp: id,
                    turns: vec![turn],
                },
                desk,
            )
        })
        .await;
    until(&mut device, &mut phone, |d| {
        d.visitor(id).is_some_and(|v| !v.turns.is_empty())
    })
    .await;
    let shown = device.visitor(id).unwrap();
    assert_eq!(shown.turns[0].reply, "Hi from the pocket");

    // Sent home, it lands on the phone again.
    device.send_home(id).await.unwrap();
    let Event::Message(LinkMessage::Pass { transfer, home, .. }, _) =
        phone_hears(&mut device, &mut phone, |e| {
            matches!(e, Event::Message(LinkMessage::Pass { .. }, _))
        })
        .await
    else {
        unreachable!()
    };
    assert!(home.is_none(), "an Imp going home needs no home card");
    phone
        .runner
        .with(move |n, now| n.accept(transfer, now))
        .await;
    until(&mut device, &mut phone, |d| d.visitor(id).is_none()).await;
    phone.runner.stop().await;
    device.stop().await;
}

#[tokio::test]
async fn imps_message_each_other_across_devices() {
    let (mut device, options) = computer("troupe").await;
    let mut phone = phone().await;
    link(&mut device, &mut phone).await;
    let desk = device_id(&device, &phone).await;
    let pocket = phone.id;
    // The phone shows Pebble, and trusts the computer as one of the owner's devices.
    phone
        .runner
        .with(move |n, _| {
            n.set_stage(vec![LinkStaged {
                imp: pocket_imp(),
                home: pocket,
            }]);
            n.set_trusted(desk, true);
        })
        .await;
    let remote = device.remote();
    tokio::time::timeout(WAIT, async {
        // `next` only returns with something to show, so look again now and then.
        while remote.imps().is_empty() {
            tokio::select! {
                _ = device.next() => {}
                _ = phone.events.recv() => {}
                _ = tokio::time::sleep(Duration::from_millis(50)) => {}
            }
        }
    })
    .await
    .expect("the phone's stage never came");
    let target = remote.imps()[0].clone();
    assert_eq!(target.look.name, "Pebble");
    assert_eq!(target.place, "Pocket");

    // The computer's Imp asks Pebble. The phone answers it as its app would.
    let config = imp_cli::config::Config::load_with_ids(&options.config).unwrap();
    let me = imp_cli::session::look_of("linktest", &config.imps["linktest"]);
    let asking = remote.ask(me, target, "What's up?");
    tokio::pin!(asking);
    let answer = tokio::time::timeout(WAIT, async {
        loop {
            tokio::select! {
                answer = &mut asking => return answer,
                _ = device.next() => {}
                event = phone.events.recv() => {
                    if let Some(Event::Message(LinkMessage::Message { id, text, .. }, from)) = event {
                        assert_eq!(text, "What's up?");
                        let reply = LinkMessage::Answer { id, text: "All good".into(), failed: false };
                        phone.runner.with(move |n, _| n.send(&reply, from)).await;
                    }
                }
            }
        }
    })
    .await
    .expect("no answer");
    assert_eq!(answer.as_deref(), Ok("All good"));
    phone.runner.stop().await;
    device.stop().await;
}

#[tokio::test]
async fn only_one_program_is_the_computer_at_a_time() {
    let (device, options) = computer("lock").await;
    let second = Device::start(&options, Arc::new(Memory::default())).await;
    assert!(matches!(
        second.err(),
        Some(imp_cli::link::device::StartError::Busy)
    ));
    device.stop().await;
}
