//! This computer as a device, against a phone made from the core's own node, over real loopback sockets and a
//! mock model service. An Imp of the computer goes to the phone, answers what the phone asks while it is
//! there, and comes back with its conversation. An Imp of the phone visits the computer and answers through
//! its home. Imps message each other across the two. No real service or key store is used.

mod common;

use common::World;
use imp_chat::link::device::{Device, DeviceOptions, Update};
use imp_chat::link::{Runner, SeedStore};
use imp_engine::link::card::LinkKind;
use imp_engine::link::node::{Event, Node, Options};
use imp_engine::link::{
    LinkEntry, LinkImp, LinkMessage, LinkSide, LinkStaged, LinkTraits, LinkTurn, LinkWho,
};
use imp_engine::{ChatMessage, Role};
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

/// A service that answers its first request with a reasoning step and a call of `imp_message` to Ghost, and
/// every later one with `last`. It keeps the body of each request.
async fn scripted(last: &'static str) -> (String, Arc<Mutex<Vec<String>>>) {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let url = format!("http://{}/v1", listener.local_addr().unwrap());
    let seen = Arc::new(Mutex::new(Vec::<String>::new()));
    let kept = seen.clone();
    tokio::spawn(async move {
        while let Ok((mut socket, _)) = listener.accept().await {
            let seen = kept.clone();
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
                let text = String::from_utf8_lossy(&data).to_string();
                let first = {
                    let mut seen = seen.lock().unwrap();
                    seen.push(
                        text.split_once("\r\n\r\n")
                            .map_or(text.clone(), |(_, b)| b.into()),
                    );
                    seen.len() == 1
                };
                let chunk = |delta: serde_json::Value, finish: Option<&str>| {
                    let json =
                        serde_json::json!({"choices":[{"delta":delta,"finish_reason":finish}]});
                    format!("data: {json}\n\n")
                };
                let mut body = String::new();
                if first {
                    let call =
                        serde_json::json!({"to":"Ghost","text":"Are you there?"}).to_string();
                    body += &chunk(
                        serde_json::json!({"reasoning_content":"I should ask Ghost."}),
                        None,
                    );
                    body += &chunk(
                        serde_json::json!({"tool_calls":[{"index":0,"id":"call_1","type":"function",
                            "function":{"name":"imp_message","arguments":call}}]}),
                        None,
                    );
                    body += &chunk(serde_json::json!({}), Some("tool_calls"));
                } else {
                    body += &chunk(serde_json::json!({"content":last}), None);
                    body += &chunk(serde_json::json!({}), Some("stop"));
                }
                body += "data: [DONE]\n\n";
                let _ = socket.write_all(format!("HTTP/1.1 200 OK\r\ncontent-type: text/event-stream\r\nconnection: close\r\n\r\n{body}").as_bytes()).await;
                let _ = socket.shutdown().await;
            });
        }
    });
    (url, seen)
}

/// A computer with one Imp, `linktest`, whose brain is the mock. The world holds its files and goes with it.
async fn computer(name: &str) -> (Device, DeviceOptions, World) {
    let world = World::new(&format!("device-{name}"));
    let url = mock("Hello from the computer").await;
    world.with_mock(&url);
    world.agent("linktest", "mode: primary", "Kind.");
    let options = DeviceOptions {
        name: Some("Desk".into()),
        hosts: vec!["127.0.0.1".into()],
        data_dir: world.data.clone(),
        settings: Some(world.settings()),
        workspace: Some(world.work.clone()),
        ..DeviceOptions::default()
    };
    let device = Device::start(&options, Arc::new(Memory::default()))
        .await
        .unwrap();
    (device, options, world)
}

struct Phone {
    runner: Runner,
    events: mpsc::UnboundedReceiver<Event>,
    id: Uuid,
}

async fn phone() -> Phone {
    device_of("Pocket", 77).await
}

/// A device made from the core's node, listening on loopback.
async fn device_of(name: &str, seed: u128) -> Phone {
    let node = Node::new(
        None,
        name,
        LinkKind::Phone,
        Uuid::from_u128(seed),
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
        about: None,
        abilities: Vec::new(),
    }
}

#[tokio::test]
async fn an_imp_goes_to_the_phone_answers_there_and_comes_back_with_its_conversation() {
    let (mut device, _options, _world) = computer("travel").await;
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
                    attachments: Vec::new(),
                },
                home_id,
            )
        })
        .await;
    // The chat with the answer comes before the end of the work, which is when a holder shows it.
    let mut answered: Option<Vec<LinkTurn>> = None;
    let mut working = false;
    let turns: Vec<LinkTurn> = loop {
        let event = phone_hears(&mut device, &mut phone, |e| {
            matches!(
                e,
                Event::Message(LinkMessage::Chat { .. } | LinkMessage::Work { .. }, _)
            )
        })
        .await;
        match event {
            Event::Message(LinkMessage::Chat { turns, .. }, _) if turns.len() == 2 => {
                answered = Some(turns);
            }
            Event::Message(LinkMessage::Work { work: Some(_), .. }, _) => working = true,
            Event::Message(LinkMessage::Work { work: None, .. }, _) if working => {
                break answered.expect("the answer's chat came before the work ended");
            }
            _ => {}
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
    let (mut device, _options, _world) = computer("visit").await;
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
    // Right after the note, the chat hears that it arrived, so an idle chat can show it.
    let arrived = computer_says(&mut device, &mut phone, |u| matches!(u, Update::Arrived(_))).await;
    assert_eq!(arrived, Update::Arrived(pebble.id));
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
                    tools: false,
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
        thoughts: None,
        answer: None,
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
    let (mut device, options, _world) = computer("troupe").await;
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
                home: LinkWho {
                    id: pocket,
                    name: "Pocket".into(),
                    kind: LinkKind::Mac,
                },
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
    let loaded = options.settings.as_ref().unwrap().load();
    let agent = imp_chat::settings::find_imp(&loaded, Some("linktest")).unwrap();
    let servers = imp_chat::settings::servers_of(&loaded, &agent.value);
    let me = imp_chat::settings::look_of(&loaded, &agent.value, &servers);
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
async fn an_imp_away_on_the_phone_messages_an_imp_of_a_third_device_through_the_phone() {
    // The desk's Imp is on the phone. Ghost lives on the tablet, which only the phone is linked to.
    let world = World::new("device-holder");
    let (url, seen) = scripted("Ghost answered.").await;
    world.with_mock(&url);
    world.agent("linktest", "mode: primary", "Kind.");
    let options = DeviceOptions {
        name: Some("Desk".into()),
        hosts: vec!["127.0.0.1".into()],
        data_dir: world.data.clone(),
        settings: Some(world.settings()),
        workspace: Some(world.work.clone()),
        ..DeviceOptions::default()
    };
    let mut device = Device::start(&options, Arc::new(Memory::default()))
        .await
        .unwrap();
    let mut phone = phone().await;
    let mut tablet = device_of("Slate", 78).await;
    link(&mut device, &mut phone).await;
    // The phone is one of the owner's devices, so what it asks may use tools.
    device.set_trusted(phone.id, true).await;
    let invite = phone
        .runner
        .with(|n, now| {
            n.set_hosts(vec!["127.0.0.1".into()]);
            n.invite(now)
        })
        .await
        .unwrap();
    tablet
        .runner
        .with(move |n, now| n.join(&invite, now))
        .await
        .unwrap();
    let (desk, slate) = (device_id(&device, &phone).await, tablet.id);
    // Wait until the phone and the tablet are connected.
    tokio::time::timeout(WAIT, async {
        while !phone
            .runner
            .with(move |n, _| n.connected().contains(&slate))
            .await
            .unwrap_or(false)
        {
            tokio::select! {
                _ = device.next() => {}
                _ = tablet.events.recv() => {}
                _ = tokio::time::sleep(Duration::from_millis(20)) => {}
            }
        }
    })
    .await
    .expect("the tablet never connected to the phone");

    // The Imp goes to the phone, which takes it.
    let peer = device.find_peer("pocket").unwrap();
    device.send_imp("linktest", vec![], &peer).await.unwrap();
    let Event::Message(LinkMessage::Pass { transfer, imp, .. }, _) =
        phone_hears(&mut device, &mut phone, |e| {
            matches!(e, Event::Message(LinkMessage::Pass { .. }, _))
        })
        .await
    else {
        unreachable!()
    };
    phone
        .runner
        .with(move |n, now| n.accept(transfer, now))
        .await;
    until(&mut device, &mut phone, |d| d.away_on(imp.id).is_some()).await;

    // The phone shows it and Ghost (whose home is the tablet). The tablet shows Ghost and that Imp too.
    let ghost = LinkImp {
        id: Uuid::from_u128(901),
        name: "Ghost".into(),
        ..pocket_imp()
    };
    let stage = vec![
        LinkStaged {
            imp: imp.clone(),
            home: LinkWho {
                id: desk,
                name: "Desk".into(),
                kind: LinkKind::Mac,
            },
        },
        LinkStaged {
            imp: ghost.clone(),
            home: LinkWho {
                id: slate,
                name: "Slate".into(),
                kind: LinkKind::Mac,
            },
        },
    ];
    let shown = stage.clone();
    phone
        .runner
        .with(move |n, _| {
            n.set_stage(shown);
        })
        .await;
    tablet.runner.with(move |n, _| n.set_stage(stage)).await;
    let remote = device.remote();
    tokio::time::timeout(WAIT, async {
        while !remote.imps().iter().any(|r| r.look.name == "Ghost") {
            tokio::select! {
                _ = device.next() => {}
                _ = phone.events.recv() => {}
                _ = tablet.events.recv() => {}
                _ = tokio::time::sleep(Duration::from_millis(50)) => {}
            }
        }
    })
    .await
    .expect("the phone's stage never came");

    // The phone asks the Imp. It answers with a call of imp_message, which goes to Ghost's home.
    let ask = LinkMessage::Ask {
        imp: imp.id,
        text: "Find Ghost.".into(),
        attachments: Vec::new(),
    };
    phone.runner.with(move |n, _| n.send(&ask, desk)).await;
    let mut asked_ghost = false;
    let mut answered: Option<Vec<LinkTurn>> = None;
    tokio::time::timeout(WAIT, async {
        while answered.is_none() {
            tokio::select! {
                _ = device.next() => {}
                event = tablet.events.recv() => {
                    // Forwarded by the phone, which is not Ghost's home either: the tablet answers.
                    if let Some(Event::Message(LinkMessage::Message { id, text, .. }, from)) = event {
                        assert_eq!(text, "Are you there?");
                        assert_eq!(from, phone.id, "the question came through the holder");
                        asked_ghost = true;
                        let reply = LinkMessage::Answer { id, text: "Here.".into(), failed: false };
                        tablet.runner.with(move |n, _| n.send(&reply, from)).await;
                    }
                }
                event = phone.events.recv() => {
                    if let Some(Event::Message(LinkMessage::Chat { turns, .. }, _)) = event
                        && turns.len() == 1
                        && !turns[0].reply.is_empty()
                    {
                        answered = Some(turns);
                    }
                }
            }
        }
    })
    .await
    .expect("the answer never reached the phone");
    assert!(asked_ghost);
    let turn = &answered.unwrap()[0];
    assert_eq!(turn.request, "Find Ghost.");
    assert_eq!(turn.reply, "Ghost answered.");
    assert!(!turn.failed);
    // The tool call, and the model's thought before it, show as steps. Which of them are thoughts is told.
    assert!(turn.steps[0].starts_with("Thought for"), "{:?}", turn.steps);
    assert_eq!(turn.thoughts, Some(vec![0]));

    // The first request offered imp_message, with Ghost to message. The second carried Ghost's answer.
    let bodies = seen.lock().unwrap().clone();
    assert_eq!(bodies.len(), 2, "{bodies:?}");
    let first: serde_json::Value = serde_json::from_str(&bodies[0]).unwrap();
    let tool = first["tools"]
        .as_array()
        .and_then(|t| t.iter().find(|t| t["function"]["name"] == "imp_message"))
        .unwrap_or_else(|| panic!("imp_message was not offered: {}", first["tools"]));
    assert!(tool.to_string().contains("Ghost"), "{tool}");
    assert!(bodies[1].contains("Here."), "{}", bodies[1]);
    tablet.runner.stop().await;
    phone.runner.stop().await;
    device.stop().await;
}

#[tokio::test]
async fn only_one_program_is_the_computer_at_a_time() {
    let (device, options, _world) = computer("lock").await;
    let second = Device::start(&options, Arc::new(Memory::default())).await;
    assert!(matches!(
        second.err(),
        Some(imp_chat::link::device::StartError::Busy)
    ));
    device.stop().await;
}

#[tokio::test]
async fn a_photo_and_a_sound_that_come_with_a_question_reach_the_model_and_the_folder() {
    let world = World::new("device-attachments");
    let (url, bodies) = common::mock().await;
    world.with_mock(&url);
    world.agent("linktest", "mode: primary", "Kind.");
    let options = DeviceOptions {
        name: Some("Desk".into()),
        hosts: vec!["127.0.0.1".into()],
        data_dir: world.data.clone(),
        settings: Some(world.settings()),
        workspace: Some(world.work.clone()),
        ..DeviceOptions::default()
    };
    let mut device = Device::start(&options, Arc::new(Memory::default()))
        .await
        .unwrap();
    let mut phone = phone().await;
    link(&mut device, &mut phone).await;
    let peer = device.find_peer("pocket").unwrap();
    device.send_imp("linktest", vec![], &peer).await.unwrap();
    let Event::Message(LinkMessage::Pass { transfer, imp, .. }, _) =
        phone_hears(&mut device, &mut phone, |e| {
            matches!(e, Event::Message(LinkMessage::Pass { .. }, _))
        })
        .await
    else {
        unreachable!()
    };
    let accepted = phone
        .runner
        .with(move |n, now| n.accept(transfer, now))
        .await;
    assert_eq!(accepted, Some(true));
    computer_says(&mut device, &mut phone, |u| {
        matches!(u, Update::Away { .. })
    })
    .await;

    let desk = device_id(&device, &phone).await;
    let (picture, sound) = (b"\x89PNG-pixels".to_vec(), b"RIFF-wave-bytes".to_vec());
    let (p, s, id) = (picture.clone(), sound.clone(), imp.id);
    let (first, second) = phone
        .runner
        .with(move |n, now| {
            (
                n.upload(id, desk, "../cat photo.png", "image/png", p, now),
                n.upload(id, desk, "hello.wav", "audio/wav", s, now),
            )
        })
        .await
        .unwrap();
    let (first, second) = (first.unwrap(), second.unwrap());
    let missing = Uuid::from_u128(4242);
    let ask = LinkMessage::Ask {
        imp: id,
        text: "What is this?".into(),
        attachments: vec![first, second, missing],
    };
    phone.runner.with(move |n, _| n.send(&ask, desk)).await;
    tokio::time::timeout(WAIT, async {
        while bodies.lock().unwrap().is_empty() {
            tokio::select! {
                _ = device.next() => {}
                _ = phone.events.recv() => {}
                _ = tokio::time::sleep(Duration::from_millis(20)) => {}
            }
        }
    })
    .await
    .expect("the model never heard it");

    let body: serde_json::Value = serde_json::from_str(&bodies.lock().unwrap()[0]).unwrap();
    let last = body["messages"].as_array().unwrap().last().unwrap().clone();
    let parts = last["content"].as_array().expect("a message with parts");
    // The media come before the words (see `ChatMessage::to_json`).
    let text = parts[2]["text"].as_str().unwrap();
    assert!(text.starts_with("What is this?"), "{text}");
    assert!(text.contains("attachments/"), "{text}");
    assert!(text.contains("cat_photo.png"), "{text}");
    assert!(text.contains("an attachment didn't arrive"), "{text}");
    assert_eq!(parts.len(), 3, "{parts:?}");
    assert_eq!(parts[0]["type"], "image_url");
    assert!(
        parts[0]["image_url"]["url"]
            .as_str()
            .unwrap()
            .starts_with("data:image/png;base64,")
    );
    assert_eq!(parts[1]["type"], "input_audio");
    assert_eq!(parts[1]["input_audio"]["format"], "wav");

    let mut saved: Vec<(String, Vec<u8>)> = std::fs::read_dir(world.work.join("attachments"))
        .unwrap()
        .map(|e| {
            let e = e.unwrap();
            (
                e.file_name().to_string_lossy().to_string(),
                std::fs::read(e.path()).unwrap(),
            )
        })
        .collect();
    saved.sort();
    assert_eq!(saved.len(), 2);
    assert!(
        saved
            .iter()
            .any(|(n, d)| n.ends_with("-cat_photo.png") && *d == picture)
    );
    assert!(
        saved
            .iter()
            .any(|(n, d)| n.ends_with("-hello.wav") && *d == sound)
    );
    phone.runner.stop().await;
    device.stop().await;
}
