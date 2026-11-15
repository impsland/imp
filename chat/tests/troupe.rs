//! `imp_message` between two Imps of the terminal app, against a local mock service.

use imp_chat::config::Config;
use imp_chat::troupe::ImpMessageHost;
use imp_engine::{TalkStore, ToolHost, ToolSelection};
use std::path::PathBuf;

mod common;
use common::mock;

fn data_dir(name: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!("imp-troupe-{}-{name}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    dir
}

fn host(url: &str, dir: &PathBuf, now: fn() -> u64) -> ImpMessageHost {
    let config = Config::parse(&format!(
        "[imps.pip]\npersonality=\"Pip.\"\nbase_url=\"{url}\"\nmodel=\"m\"\n[imps.bo]\npersonality=\"Bo.\"\nbase_url=\"{url}\"\nmodel=\"m\"\n"
    ))
    .unwrap();
    ImpMessageHost::new("pip", config, TalkStore::new(dir), Box::new(|_, _| None)).with_clock(now)
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
    let dir = data_dir("continue");
    let first = host(&url, &dir, t0);
    assert_eq!(
        first
            .deliver("bo", "Remember the number 42", None)
            .await
            .unwrap(),
        "Answer 1"
    );
    let second = host(&url, &dir, t_after_10_minutes);
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
    let log = TalkStore::new(&dir).load("bo", "pip");
    assert_eq!(log.conversations.len(), 1);
    assert_eq!(log.conversations[0].messages.len(), 4);
    let _ = std::fs::remove_dir_all(dir);
}

#[tokio::test]
async fn an_old_conversation_or_a_new_request_starts_fresh() {
    let (url, seen) = mock().await;
    let dir = data_dir("new");
    host(&url, &dir, t0)
        .deliver("bo", "Old topic", None)
        .await
        .unwrap();
    // After the window the default is a new conversation.
    host(&url, &dir, t_after_two_hours)
        .deliver("bo", "Second topic", None)
        .await
        .unwrap();
    // The Imp can ask for a new one even while the last is recent.
    host(&url, &dir, t_after_two_hours)
        .deliver("bo", "Third topic", Some("new"))
        .await
        .unwrap();
    // And for the latest one even when it is old.
    host(&url, &dir, t_after_ten_hours)
        .deliver("bo", "Fourth topic", Some("continue"))
        .await
        .unwrap();
    let bodies = seen.lock().unwrap();
    assert!(!bodies[1].contains("Old topic"), "{}", bodies[1]);
    assert!(!bodies[2].contains("Second topic"), "{}", bodies[2]);
    assert!(bodies[3].contains("Third topic"));
    assert!(!bodies[3].contains("Old topic"));
    let log = TalkStore::new(&dir).load("pip", "bo");
    assert_eq!(log.conversations.len(), 3);
    let _ = std::fs::remove_dir_all(dir);
}

#[tokio::test]
async fn the_tool_is_described_called_and_can_be_switched_off() {
    let (url, seen) = mock().await;
    let dir = data_dir("tool");
    let tool_host = host(&url, &dir, t0);
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
    assert_eq!(entry.id, "own.troupe.imp_message");
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
    let _ = std::fs::remove_dir_all(dir);
}

/// Two Imps set up only by `.agents/agents/imp.md` and `pip.md`, with their own service and key
/// variable: once the folder is trusted, `imp` messages `pip` at pip's address with pip's model.
#[tokio::test]
async fn imps_from_agent_files_alone_message_each_other() {
    use imp_chat::project::{Project, TrustStore};
    let (url, seen) = mock().await;
    let root = data_dir("agent-files");
    let agents = root.join("work/.agents/agents");
    std::fs::create_dir_all(&agents).unwrap();
    std::fs::write(
        agents.join("imp.md"),
        format!("---\ndefault: true\nbase_url: {url}\nmodel: imp-model\napi_key: ${{IMP_FILES_KEY}}\n---\nThe planner.\n"),
    )
    .unwrap();
    std::fs::write(
        agents.join("pip.md"),
        format!("---\nbase_url: {url}/\nmodel: pip-model\napi_key_env: PIP_FILES_KEY\n---\nI am Pip, I count things.\n"),
    )
    .unwrap();
    let workspace = root.join("work");
    // Not trusted yet: the files' services are not used, and the chat says what waits.
    let untrusted = Project::load(&workspace, None, &TrustStore::default());
    let mut config = Config::default();
    untrusted.apply(&mut config);
    assert_eq!(config.default_imp.as_deref(), Some("imp"));
    assert_eq!(config.imps["pip"].base_url, imp_chat::config::DEFAULT_URL);
    assert_eq!(config.imps["pip"].api_key_env, None);
    assert!(
        untrusted.notices()[0].contains("PIP_FILES_KEY"),
        "{:?}",
        untrusted.notices()
    );
    // Trusted: each Imp is whole from its file.
    let store = TrustStore::at(root.join("trust.json"));
    store
        .set(&untrusted.root, untrusted.trust_digest.as_deref())
        .unwrap();
    let project = Project::load(&workspace, None, &store);
    assert!(project.trusted && project.notices().is_empty());
    let mut config = Config::default();
    project.apply(&mut config);
    let (name, imp) = config.pick_imp(None).unwrap();
    assert_eq!((name, imp.model.as_str()), ("imp", "imp-model"));
    assert_eq!(config.imps["pip"].base_url, url);
    let env = |n: &str| (n == "PIP_FILES_KEY").then(|| "pip-secret".to_string());
    let key = imp_chat::keys::find(&config, "pip", &config.imps["pip"], env, |_| None);
    assert_eq!(key.unwrap().key, "pip-secret");
    let host = ImpMessageHost::new(
        "imp",
        config.clone(),
        TalkStore::new(root.join("talks")),
        Box::new(move |n, i| imp_chat::keys::find(&config, n, i, env, |_| None).map(|k| k.key)),
    )
    .with_clock(t0);
    let enum_of_to = host.tools()[0].spec.parameters["properties"]["to"]["enum"].clone();
    assert_eq!(enum_of_to, serde_json::json!(["pip"]));
    let answer = host
        .call("imp_message", r#"{"to":"pip","text":"How many?"}"#)
        .await
        .unwrap();
    assert!(answer.contains("Answer 1"), "{answer}");
    let body = seen.lock().unwrap()[0].clone();
    assert!(body.contains("pip-model"), "{body}");
    assert!(body.contains("I am Pip, I count things."), "{body}");
    assert!(body.contains("How many?"), "{body}");
    // A change to a service asks again.
    std::fs::write(
        agents.join("pip.md"),
        "---\nbase_url: https://elsewhere.example/v1\napi_key_env: PIP_FILES_KEY\n---\nPip.\n",
    )
    .unwrap();
    assert!(!Project::load(&workspace, None, &store).trusted);
    let _ = std::fs::remove_dir_all(root);
}
