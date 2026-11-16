//! Live API (opt-in): `IMP_LIVE_TESTS=1 cargo test -p imp-engine --test live_troupe -- --nocapture --test-threads=1`.
//! Talks to the real service in ./.env (`OPENAI_BASE_URL`, `OPENAI_API_KEY`, `OPENAI_MODEL`). Costs a few cents.
//! Checks that the model reads what Imps say about themselves, and that an answer which comes later reaches it.

use imp_engine::agent::{BoxFuture, HostTool, ToolHost};
use imp_engine::troupe::{
    MessageTool, TalkWaiting, TargetProfile, answer_event, receipt, task_label,
};
use imp_engine::{ChatMessage, OpenAiClient, RetryPolicy, Role, ToolSelection, run_agent};
use serde_json::Value;
use std::cell::RefCell;
use std::collections::HashMap;
use uuid::Uuid;

/// The values in ./.env, or `None` when live tests are off.
fn live() -> Option<HashMap<String, String>> {
    if std::env::var("IMP_LIVE_TESTS").as_deref() != Ok("1") {
        eprintln!("live tests are off (IMP_LIVE_TESTS=1 turns them on)");
        return None;
    }
    let path = concat!(env!("CARGO_MANIFEST_DIR"), "/../.env");
    let text = std::fs::read_to_string(path).expect("./.env is missing");
    let mut out = HashMap::new();
    for line in text.lines().map(str::trim) {
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        let line = line.strip_prefix("export ").unwrap_or(line);
        if let Some((k, v)) = line.split_once('=') {
            out.insert(
                k.trim().to_string(),
                v.trim().trim_matches(['"', '\'']).to_string(),
            );
        }
    }
    Some(out)
}

fn client(env: &HashMap<String, String>) -> (OpenAiClient, String) {
    let client = OpenAiClient::new(
        &env["OPENAI_BASE_URL"],
        Some(env["OPENAI_API_KEY"].clone()),
        RetryPolicy::default(),
    )
    .expect("client");
    (client, env["OPENAI_MODEL"].clone())
}

/// Offers `imp_message` and remembers the arguments of each call. What it returns is chosen by the test.
struct Host {
    tool: MessageTool,
    seen: RefCell<Vec<Value>>,
    reply: fn(&Value) -> String,
}

impl ToolHost for Host {
    fn tools(&self) -> Vec<HostTool> {
        vec![HostTool {
            entry: None,
            spec: self.tool.spec(),
        }]
    }

    fn call<'a>(&'a self, name: &'a str, arguments: &'a str) -> BoxFuture<'a, Option<String>> {
        Box::pin(async move {
            if name != "imp_message" {
                return None;
            }
            let args: Value = serde_json::from_str(arguments).unwrap_or(Value::Null);
            let text = (self.reply)(&args);
            self.seen.borrow_mut().push(args);
            Some(text)
        })
    }
}

fn profiles() -> Vec<TargetProfile> {
    vec![
        TargetProfile {
            name: "Ash".into(),
            about: Some("Only knows cooking: recipes, ingredients and kitchen tricks.".into()),
            abilities: Vec::new(),
        },
        TargetProfile {
            name: "Birch".into(),
            about: Some("Knows the capital city of every country in the world.".into()),
            abilities: Vec::new(),
        },
    ]
}

fn tool(waiting: TalkWaiting) -> MessageTool {
    MessageTool {
        targets: vec!["Ash".into(), "Birch".into()],
        profiles: profiles(),
        waiting,
        ..MessageTool::default()
    }
}

#[tokio::test]
async fn descriptions_steer_which_imp_is_asked() {
    let Some(env) = live() else { return };
    let (client, model) = client(&env);
    let host = Host {
        tool: tool(TalkWaiting::Wait),
        seen: RefCell::new(Vec::new()),
        reply: |_| "Canberra".into(),
    };
    let mut messages = vec![
        ChatMessage::new(
            Role::System,
            "You are Pip, a small helper. You can message other Imps. Pick the one whose description fits.",
        ),
        ChatMessage::new(
            Role::User,
            "Ask the right Imp what the capital of Australia is, then tell me.",
        ),
    ];
    let answer = run_agent(
        &client,
        &model,
        &mut messages,
        &host,
        &ToolSelection::default(),
        4,
        |_| {},
    )
    .await
    .expect("answer");
    let seen = host.seen.borrow();
    println!("live troupe: calls {seen:?}, reply {answer:?}");
    assert!(!seen.is_empty(), "the model never messaged an Imp");
    assert!(
        seen.iter().all(|args| args["to"] == "Birch"),
        "asked the wrong Imp: {seen:?}"
    );
}

#[tokio::test]
async fn an_answer_that_comes_later_arrives_as_a_new_message_and_wakes_the_imp() {
    let Some(env) = live() else { return };
    let (client, model) = client(&env);
    let host = Host {
        tool: tool(TalkWaiting::DontWait),
        seen: RefCell::new(Vec::new()),
        reply: |args| {
            let task = task_label(Uuid::from_u128(0xabcd_ef12_u128 << 96));
            receipt(args["to"].as_str().unwrap_or("?"), &task)
        },
    };
    let mut messages = vec![
        ChatMessage::new(
            Role::System,
            "You are Pip, a small helper. You can message other Imps. A message to an Imp does not wait: \
             its answer comes later as a new message that starts with [Event, not from the user].",
        ),
        ChatMessage::new(
            Role::User,
            "Ask Birch what the capital of Australia is. Don't wait for it; tell me you have asked.",
        ),
    ];
    let first = run_agent(
        &client,
        &model,
        &mut messages,
        &host,
        &ToolSelection::default(),
        4,
        |_| {},
    )
    .await
    .expect("first turn");
    println!("live troupe: first turn {first:?}");
    let sent = host.seen.borrow().clone();
    assert!(!sent.is_empty(), "the model never messaged Birch");
    assert_eq!(sent[0]["to"], "Birch");

    let task = task_label(Uuid::from_u128(0xabcd_ef12_u128 << 96));
    let held = receipt("Birch", &task);
    let before = messages.clone();
    let tool_at = messages
        .iter()
        .position(|m| m.role == Role::Tool)
        .expect("a tool message");
    assert_eq!(messages[tool_at].content, held);

    let event = answer_event("Birch", &task, "10:00 UTC", "Canberra", false);
    messages.push(ChatMessage::new(Role::User, event.clone()));
    let woken = run_agent(
        &client,
        &model,
        &mut messages,
        &host,
        &ToolSelection::default(),
        4,
        |_| {},
    )
    .await
    .expect("woken turn");
    println!("live troupe: woken turn {woken:?}");

    // Nothing earlier was edited, moved or removed.
    assert_eq!(&messages[..before.len()], &before[..]);
    assert_eq!(messages[tool_at].content, held);
    let last_user = messages
        .iter()
        .rfind(|m| m.role == Role::User)
        .expect("a user message");
    assert_eq!(last_user.content, event);
    assert!(woken.to_lowercase().contains("canberra"), "{woken}");
}
