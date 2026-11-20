//! `imp_message` between two Imps of the terminal app, against a local mock service.

use imp_chat::troupe::ImpMessageHost;
use imp_engine::{TalkStore, ToolHost, ToolSelection};

mod common;
use common::{World, mock, mock_with, text_reply};

/// Where the talks between Imps are kept in this world.
fn store(w: &World) -> TalkStore {
    TalkStore::new(w.data.join("talks"))
}

/// Pip and Bo, two Imps of the person's own agents folder, both on the service at `url`. Pip sends.
fn host(url: &str, w: &World, now: fn() -> u64) -> ImpMessageHost {
    if !w.imp_json().exists() {
        w.with_mock(url);
        w.agent("pip", "description: Pip", "Pip.");
        w.agent("bo", "description: Bo", "Bo.");
    }
    ImpMessageHost::new("pip", w.settings().load(), store(w)).with_clock(now)
}

fn t0() -> u64 {
    1_000_000
}
fn t_after_10_minutes() -> u64 {
    1_000_000 + 10 * 60
}
fn t_after_ten_hours() -> u64 {
    1_000_000 + 600 * 60
}
fn t_after_two_hours() -> u64 {
    1_000_000 + 120 * 60
}

#[tokio::test]
async fn a_recent_conversation_is_continued_by_default() {
    let (url, seen) = mock().await;
    let w = World::new("continue");
    let first = host(&url, &w, t0);
    assert_eq!(
        first
            .deliver("bo", "Remember the number 42", None)
            .await
            .unwrap(),
        "Answer 1"
    );
    let second = host(&url, &w, t_after_10_minutes);
    assert_eq!(
        second.deliver("bo", "What was it?", None).await.unwrap(),
        "Answer 2"
    );
    let bodies = seen.lock().unwrap();
    assert!(!bodies[0].contains("Remember the number 42\"},{"));
    assert!(
        bodies[1].contains("Remember the number 42"),
        "{}",
        bodies[1]
    );
    assert!(bodies[1].contains("Answer 1"));
    assert!(bodies[1].contains("What was it?"));
    // The answering Imp is told who wrote, in the core's words (the apps use the same).
    assert!(
        bodies[1].contains("Message from pip, another Imp"),
        "{}",
        bodies[1]
    );
    let log = store(&w).load("bo", "pip");
    assert_eq!(log.conversations.len(), 1);
    assert_eq!(log.conversations[0].messages.len(), 4);
}

#[tokio::test]
async fn an_old_conversation_or_a_new_request_starts_fresh() {
    let (url, seen) = mock().await;
    let w = World::new("new");
    host(&url, &w, t0)
        .deliver("bo", "Old topic", None)
        .await
        .unwrap();
    // After the window the default is a new conversation.
    host(&url, &w, t_after_two_hours)
        .deliver("bo", "Second topic", None)
        .await
        .unwrap();
    // The Imp can ask for a new one even while the last is recent.
    host(&url, &w, t_after_two_hours)
        .deliver("bo", "Third topic", Some("new"))
        .await
        .unwrap();
    // And for the latest one even when it is old.
    host(&url, &w, t_after_ten_hours)
        .deliver("bo", "Fourth topic", Some("continue"))
        .await
        .unwrap();
    let bodies = seen.lock().unwrap();
    assert!(!bodies[1].contains("Old topic"), "{}", bodies[1]);
    assert!(!bodies[2].contains("Second topic"), "{}", bodies[2]);
    assert!(bodies[3].contains("Third topic"));
    assert!(!bodies[3].contains("Old topic"));
    let log = store(&w).load("pip", "bo");
    assert_eq!(log.conversations.len(), 3);
}

#[tokio::test]
async fn the_tool_is_described_called_and_can_be_switched_off() {
    let (url, seen) = mock().await;
    let w = World::new("tool");
    let tool_host = host(&url, &w, t0);
    let tools = tool_host.tools();
    assert_eq!(tools.len(), 1);
    let spec = &tools[0].spec;
    assert_eq!(spec.name, "imp_message");
    assert_eq!(
        spec.parameters["properties"]["to"]["enum"],
        serde_json::json!(["bo"])
    );
    assert_eq!(
        spec.parameters["properties"]["conversation"]["enum"],
        serde_json::json!(["new", "continue"])
    );
    assert_eq!(
        spec.parameters["required"],
        serde_json::json!(["to", "text"])
    );
    let entry = tools[0].entry.as_ref().unwrap();
    assert_eq!(entry.id, "own.personality.imp_message");
    let mut off = ToolSelection::all();
    off.tools_off.insert(entry.id.clone());
    assert!(!off.allows(Some(entry)));

    let answer = tool_host
        .call(
            "imp_message",
            "{\"to\":\"bo\",\"text\":\"hello\",\"conversation\":\"new\"}",
        )
        .await;
    assert_eq!(answer.as_deref(), Some("Answer 1"));
    assert_eq!(seen.lock().unwrap().len(), 1);
    let unknown = tool_host
        .call("imp_message", "{\"to\":\"nobody\",\"text\":\"hello\"}")
        .await
        .unwrap();
    assert!(unknown.starts_with("Error:") && unknown.contains("bo"));
    let to_self = tool_host
        .call("imp_message", "{\"to\":\"pip\",\"text\":\"hello\"}")
        .await
        .unwrap();
    assert!(to_self.starts_with("Error:"));
    assert!(tool_host.call("other_tool", "{}").await.is_none());
    assert_eq!(seen.lock().unwrap().len(), 1);
}

/// Two Imps set up only by the folder's `.agents`: agent files `imp.md` and `pip.md`, and a service and its
/// key variable in `.agents/imp.json`. Until the folder is trusted the service is not used. Once it is,
/// `imp` messages `pip` at pip's address with pip's model and the key from the environment.
#[tokio::test]
async fn imps_from_the_folders_files_message_each_other_once_trusted() {
    let (url, seen, heads) = mock_with(|n| text_reply(&format!("Answer {n}"))).await;
    let w = World::new("agent-files");
    let project_config = |url: &str| {
        format!(
            r#"{{"providers":{{"pipsvc":{{"options":{{"baseURL":"{url}","apiKey":"{{env:PIP_FILES_KEY}}"}}}}}}}}"#
        )
    };
    w.in_work(".agents/imp.json", &project_config(&url));
    w.in_work(
        ".agents/agents/imp.md",
        "---\nmodel: pipsvc/imp-model\n---\nThe planner.\n",
    );
    w.in_work(
        ".agents/agents/pip.md",
        "---\nmodel: pipsvc/pip-model\n---\nI am Pip, I count things.\n",
    );
    let settings = w.settings_with(&[("PIP_FILES_KEY", "pip-secret")]);
    let message = |settings: &imp_chat::settings::Settings| {
        ImpMessageHost::new("imp", settings.load(), store(&w)).with_clock(t0)
    };
    // Not trusted yet: the folder's service is not used, and the folder says what waits.
    let untrusted = settings.load();
    let project = untrusted.project.as_ref().expect("the folder has settings");
    assert!(!project.trusted);
    assert!(!untrusted.config.providers.contains_key("pipsvc"));
    let host = message(&settings);
    let refused = host.deliver("pip", "How many?", None).await.unwrap_err();
    assert!(refused.contains("pipsvc"), "{refused}");
    assert!(seen.lock().unwrap().is_empty());
    // Trusted: each Imp is whole from its file.
    settings
        .trust
        .set(&project.root, project.digest.as_deref())
        .unwrap();
    let loaded = settings.load();
    assert!(loaded.project.as_ref().unwrap().trusted);
    let host = message(&settings);
    assert_eq!(
        host.tools()[0].spec.parameters["properties"]["to"]["enum"],
        serde_json::json!(["pip"])
    );
    let answer = host
        .call("imp_message", r#"{"to":"pip","text":"How many?"}"#)
        .await
        .unwrap();
    assert!(answer.contains("Answer 1"), "{answer}");
    let body = seen.lock().unwrap()[0].clone();
    assert!(body.contains("pip-model"), "{body}");
    assert!(body.contains("I am Pip, I count things."), "{body}");
    assert!(body.contains("How many?"), "{body}");
    assert!(
        heads.lock().unwrap()[0].contains("authorization: bearer pip-secret"),
        "{}",
        heads.lock().unwrap()[0]
    );
    // A change to the folder's services asks again.
    w.in_work(
        ".agents/imp.json",
        &project_config("https://elsewhere.example/v1"),
    );
    assert!(!settings.load().project.unwrap().trusted);
    assert!(
        message(&settings)
            .deliver("pip", "again", None)
            .await
            .is_err()
    );
}

/// The person's other devices, each with an Imp, for `imp_message`: it answers with where it is.
struct Elsewhere(Vec<imp_chat::troupe::RemoteImp>);

impl imp_chat::troupe::Remote for Elsewhere {
    fn imps(&self) -> Vec<imp_chat::troupe::RemoteImp> {
        self.0.clone()
    }

    fn ask<'a>(
        &'a self,
        _from: imp_engine::link::LinkImp,
        to: imp_chat::troupe::RemoteImp,
        _text: &'a str,
    ) -> imp_engine::BoxFuture<'a, Result<String, String>> {
        Box::pin(async move { Ok(format!("{} on {}", to.look.name, to.place)) })
    }
}

fn remote(name: &str, place: &str) -> imp_chat::troupe::RemoteImp {
    imp_chat::troupe::RemoteImp {
        look: imp_engine::link::LinkImp {
            id: uuid::Uuid::new_v4(),
            name: name.into(),
            hue: 0.0,
            scale: 1.0,
            traits: Default::default(),
            about: None,
            abilities: Vec::new(),
        },
        home: uuid::Uuid::new_v4(),
        place: place.into(),
    }
}

/// Pip here, Pip on a Mac and Pip on an iPhone: each one the others can tell apart and reach, and an
/// Imp elsewhere called like one here (Bo) is reachable too.
#[tokio::test]
async fn imps_called_alike_on_other_devices_are_each_reachable() {
    let (url, _) = mock().await;
    let w = World::new("alike");
    let look = remote("pip", "here").look;
    let others = Elsewhere(vec![
        remote("Pip", "Mac"),
        remote("Pip", "iPhone"),
        remote("Bo", "Mac"),
    ]);
    let tool_host = host(&url, &w, t0).with_remote(look, Some(std::rc::Rc::new(others)));
    let spec = &tool_host.tools()[0].spec;
    assert_eq!(
        spec.parameters["properties"]["to"]["enum"],
        serde_json::json!(["bo", "Pip@Mac", "Pip@iPhone", "Bo@Mac"])
    );
    for (to, from) in [
        ("Pip@Mac", "Pip on Mac"),
        ("pip@iphone", "Pip on iPhone"),
        ("Bo@Mac", "Bo on Mac"),
    ] {
        let answer = tool_host
            .call(
                "imp_message",
                &format!("{{\"to\":\"{to}\",\"text\":\"hi\"}}"),
            )
            .await
            .unwrap();
        assert!(answer.contains(from), "{to}: {answer}");
    }
}

// Messages that do not wait.

use imp_chat::troupe::Later;
use imp_engine::troupe::{MAX_DEPTH, MAX_PENDING, TalkWaiting};
use imp_engine::{ChatMessage, Role};
use std::rc::Rc;

fn later_host(url: &str, dir: &World, waiting: TalkWaiting) -> (ImpMessageHost, Rc<Later>) {
    let later = Rc::new(Later::new());
    let host = host(url, dir, t0).with_later(waiting, Some(later.clone()));
    (host, later)
}

#[tokio::test]
async fn a_message_that_does_not_wait_returns_a_receipt_at_once_and_the_answer_comes_later() {
    let (url, seen) = mock().await;
    let w = World::new("later");
    let (tool_host, later) = later_host(&url, &w, TalkWaiting::DontWait);
    let spec = &tool_host.tools()[0].spec;
    assert!(spec.parameters["properties"].get("wait").is_none());
    assert!(spec.description.contains("comes later as a new message"));

    let receipt = tool_host
        .call(
            "imp_message",
            r#"{"to":"bo","text":"capital of Australia?"}"#,
        )
        .await
        .unwrap();
    assert!(receipt.starts_with("Sent to bo (task t-"), "{receipt}");
    assert!(receipt.contains("answer will come later as a new message"));
    // Nothing was asked of Bo's model yet, and one answer is on its way.
    assert_eq!(seen.lock().unwrap().len(), 0);
    assert_eq!(later.pending(), 1);

    let arrival = later.next().await;
    assert_eq!(later.pending(), 0);
    assert_eq!(arrival.from, "bo");
    assert_eq!((arrival.text.as_str(), arrival.failed), ("Answer 1", false));
    assert_eq!(arrival.sent, "13:46 UTC");
    assert!(
        receipt.contains(&arrival.task),
        "{receipt} {}",
        arrival.task
    );
    assert_eq!(seen.lock().unwrap().len(), 1);
    // Bo filed its answer as for any message.
    assert_eq!(store(&w).load("pip", "bo").conversations.len(), 1);

    // The Imp's chat: the receipt stays what it was, and the answer is a new user message at the end.
    let asked = ChatMessage {
        tool_calls: vec![imp_engine::ToolCall {
            id: "c1".into(),
            name: "imp_message".into(),
            arguments: "{}".into(),
        }],
        ..ChatMessage::assistant("")
    };
    let mut chat = imp_chat::chat_state::ChatState::from_messages(
        "sys",
        vec![
            ChatMessage::user("Ask Bo"),
            asked,
            ChatMessage::tool_result("c1", &receipt),
            ChatMessage::assistant("I asked Bo."),
        ],
    );
    let before = chat.messages().to_vec();
    assert!(chat.push_user(&arrival.event()));
    let after = chat.messages();
    assert_eq!(after.len(), before.len() + 1);
    assert_eq!(after[..before.len()], before[..]);
    assert_eq!(after[2].content, receipt);
    let last = after.last().unwrap();
    assert_eq!(last.role, Role::User);
    assert!(
        last.content
            .starts_with("[Event, not from the user] bo answered your message"),
        "{}",
        last.content
    );
    assert!(last.content.contains("“Answer 1”"));
    // The woken Imp is one deeper.
    assert_eq!(arrival.wakes_at(), 1);
}

#[tokio::test]
async fn the_sender_decides_when_the_setting_leaves_it_to_it() {
    let (url, seen) = mock().await;
    let w = World::new("decides");
    let (tool_host, later) = later_host(&url, &w, TalkWaiting::Decides);
    let spec = &tool_host.tools()[0].spec;
    assert_eq!(spec.parameters["properties"]["wait"]["type"], "boolean");
    // Nothing said, or true: it waits.
    let waited = tool_host
        .call("imp_message", r#"{"to":"bo","text":"one"}"#)
        .await
        .unwrap();
    assert_eq!(waited, "Answer 1");
    let waited = tool_host
        .call("imp_message", r#"{"to":"bo","text":"two","wait":true}"#)
        .await
        .unwrap();
    assert_eq!(waited, "Answer 2");
    assert_eq!(later.pending(), 0);
    // False: a receipt.
    let receipt = tool_host
        .call("imp_message", r#"{"to":"bo","text":"three","wait":false}"#)
        .await
        .unwrap();
    assert!(receipt.starts_with("Sent to bo"), "{receipt}");
    assert_eq!(seen.lock().unwrap().len(), 2);
    assert_eq!(later.next().await.text, "Answer 3");

    // A setting of wait wins over the argument.
    let (always, _) = later_host(&url, &w, TalkWaiting::Wait);
    assert!(
        always.tools()[0].spec.parameters["properties"]
            .get("wait")
            .is_none()
    );
    let waited = always
        .call("imp_message", r#"{"to":"bo","text":"four","wait":false}"#)
        .await
        .unwrap();
    assert_eq!(waited, "Answer 4");

    // A chat that takes no later answers never offers the choice.
    let alone = host(&url, &w, t0).with_later(TalkWaiting::DontWait, None);
    assert!(
        alone.tools()[0].spec.parameters["properties"]
            .get("wait")
            .is_none()
    );
    let waited = alone
        .call("imp_message", r#"{"to":"bo","text":"five","wait":false}"#)
        .await
        .unwrap();
    assert_eq!(waited, "Answer 5");
}

#[tokio::test]
async fn an_imp_can_have_only_so_many_answers_on_their_way_and_only_so_deep() {
    let (url, _) = mock().await;
    let w = World::new("limits");
    let (tool_host, later) = later_host(&url, &w, TalkWaiting::DontWait);
    let send = r#"{"to":"bo","text":"x"}"#;
    for _ in 0..MAX_PENDING {
        let receipt = tool_host.call("imp_message", send).await.unwrap();
        assert!(receipt.starts_with("Sent to"), "{receipt}");
    }
    let refused = tool_host.call("imp_message", send).await.unwrap();
    assert!(
        refused.starts_with("Error:") && refused.contains("wait=true"),
        "{refused}"
    );
    assert_eq!(later.pending(), MAX_PENDING);
    // An answer coming back frees a place.
    later.next().await;
    assert!(
        tool_host
            .call("imp_message", send)
            .await
            .unwrap()
            .starts_with("Sent to")
    );
    while later.pending() > 0 {
        later.next().await;
    }
    // Woken by an answer, deep enough, it may not send more without waiting.
    later.set_depth(MAX_DEPTH - 1);
    assert!(
        tool_host
            .call("imp_message", send)
            .await
            .unwrap()
            .starts_with("Sent to")
    );
    let arrival = later.next().await;
    assert_eq!(arrival.depth, MAX_DEPTH - 1);
    later.set_depth(arrival.wakes_at());
    let refused = tool_host.call("imp_message", send).await.unwrap();
    assert!(
        refused.starts_with("Error:") && refused.contains("deep"),
        "{refused}"
    );
    assert_eq!(later.pending(), 0);
    // A name nobody has is refused at once and takes no place.
    later.set_depth(0);
    let unknown = tool_host
        .call("imp_message", r#"{"to":"nobody","text":"x"}"#)
        .await
        .unwrap();
    assert!(
        unknown.starts_with("Error:") && unknown.contains("bo"),
        "{unknown}"
    );
    assert_eq!(later.pending(), 0);
}

#[tokio::test]
async fn an_imp_that_does_not_answer_in_time_comes_back_as_a_failed_answer() {
    // A service that takes the request and never answers.
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let url = format!("http://{}/v1", listener.local_addr().unwrap());
    let keep = tokio::spawn(async move {
        let mut held = Vec::new();
        while let Ok((socket, _)) = listener.accept().await {
            held.push(socket);
        }
    });
    let w = World::new("timeout");
    let (tool_host, later) = later_host(&url, &w, TalkWaiting::DontWait);
    later.set_timeout(std::time::Duration::from_millis(200));
    let receipt = tool_host
        .call("imp_message", r#"{"to":"bo","text":"hello?"}"#)
        .await
        .unwrap();
    assert!(receipt.starts_with("Sent to bo"));
    let arrival = later.next().await;
    assert!(arrival.failed);
    assert!(
        arrival.text.contains("bo didn't answer"),
        "{}",
        arrival.text
    );
    assert!(arrival.event().contains("bo couldn't answer your message"));
    keep.abort();
}

#[tokio::test]
async fn an_imp_on_another_device_answers_later_too() {
    let (url, _) = mock().await;
    let w = World::new("later-remote");
    let (tool_host, later) = later_host(&url, &w, TalkWaiting::DontWait);
    let look = remote("pip", "here").look;
    let others = Elsewhere(vec![remote("Mo", "iPhone")]);
    let tool_host = tool_host.with_remote(look, Some(Rc::new(others)));
    let receipt = tool_host
        .call("imp_message", r#"{"to":"Mo","text":"hi"}"#)
        .await
        .unwrap();
    assert!(receipt.starts_with("Sent to Mo"), "{receipt}");
    let arrival = later.next().await;
    assert_eq!(arrival.from, "Mo");
    assert_eq!(arrival.text, "Mo on iPhone");
}

#[tokio::test]
async fn imps_are_told_what_the_others_say_about_themselves() {
    let (url, _) = mock().await;
    let w = World::new("profiles");
    w.write_config(&format!(
        r#"{{"model":"mock/m","providers":{{"mock":{{"options":{{"baseURL":"{url}"}}}}}},"mcp":{{"atlas":{{"type":"local","command":["atlas"]}}}}}}"#
    ));
    w.agent("pip", "description: Pip", "Pip.");
    w.agent(
        "ash",
        "description: \"knows the capital cities\\nof every country\"",
        "A.",
    );
    // Birch has no description and no tool servers (a rule turns the one there is off for it).
    w.agent(
        "birch",
        "permissions:\n  - {action: mcp, resource: \"atlas/*\", effect: deny}",
        "B.",
    );
    let mut mo = remote("Mo", "iPhone");
    mo.look.about = Some("  draws\npictures ".into());
    mo.look.abilities = vec!["canvas".into()];
    let look = remote("pip", "here").look;
    let tool_host = ImpMessageHost::new("pip", w.settings().load(), store(&w))
        .with_remote(look, Some(Rc::new(Elsewhere(vec![mo]))));
    let d = tool_host.tools()[0].spec.description.clone();
    assert!(
        d.contains("- ash: knows the capital cities of every country. Can: atlas."),
        "{d}"
    );
    assert!(d.contains("- Mo: draws pictures. Can: canvas."), "{d}");
    // Birch says nothing, so it is not listed.
    assert!(!d.contains("- birch"), "{d}");
}
