//! What the model is sent of a chat, against a local mock service: the core's chat memory, and
//! `/compact`, which sums the chat up and goes on from the summary.

mod common;

use common::mock;
use imp_chat::session::{Session, SessionOptions};
use imp_chat::slash::{self, Context, Outcome};
use std::path::{Path, PathBuf};

fn folder(name: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!("imp-chat-memory-{name}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    dir
}

async fn session(dir: &Path, url: &str, extra: &str) -> Session {
    let config = dir.join("config.toml");
    std::fs::write(
        &config,
        format!(
            "api_key_env = \"IMP_TEST_NO_KEY\"\n{extra}\n[imps.pip]\npersonality = \"Kind.\"\nbase_url = \"{url}\"\nmodel = \"m\"\n"
        ),
    )
    .unwrap();
    Session::open(
        &config,
        None,
        SessionOptions {
            workspace: Some(dir.to_path_buf()),
            remote: None,
            // Not the developer's own ~/.agents.
            agents_home: Some(no_home()),
        },
    )
    .await
    .unwrap()
}

/// One message and its answer, as the chats do it: the request is the chat's, then the exchange ends.
async fn ask(s: &Session, chat: &mut imp_chat::chat_state::ChatState, text: &str) -> String {
    chat.push_user(text);
    let mut messages = chat.request_messages();
    let answer = imp_engine::run_agent(
        &s.client,
        &s.model,
        &mut messages,
        &*s.toolbox,
        &s.selection,
        s.max_steps,
        |e| chat.apply_agent(&e),
    )
    .await
    .unwrap();
    chat.finish_exchange(true);
    answer
}

#[tokio::test]
async fn compact_sums_the_chat_up_and_the_next_message_goes_on_from_it() {
    let (url, seen) = mock().await;
    let dir = folder("compact");
    let mut s = session(&dir, &url, "").await;
    let mut chat = s.new_chat();
    ask(&s, &mut chat, "Remember the number 42").await;
    ask(&s, &mut chat, "And the colour blue").await;
    let mut device = None;
    let outcome = slash::run(
        "/compact",
        Context {
            session: &mut s,
            device: &mut device,
            device_options: None,
            visiting: None,
            history: chat.messages(),
        },
    )
    .await;
    assert_eq!(outcome, Outcome::Compact);
    let summary = s.recap(chat.memory()).await.unwrap();
    assert_eq!(summary, "Answer 3");
    assert!(chat.recapped(&summary));
    ask(&s, &mut chat, "What was the number?").await;
    let bodies = seen.lock().unwrap().clone();
    assert!(bodies[2].contains("The chat to recap"), "{}", bodies[2]);
    assert!(bodies[2].contains("Remember the number 42"));
    let last = &bodies[3];
    assert!(last.contains("Recap of our chat so far"), "{last}");
    assert!(last.contains("Answer 3"));
    assert!(!last.contains("Remember the number 42"), "{last}");
    assert!(
        last.contains("And the colour blue"),
        "the last exchange stays"
    );
    assert_eq!(chat.messages().len(), 6, "the chat still shows it all");
    s.close().await;
    let _ = std::fs::remove_dir_all(dir);
}

#[tokio::test]
async fn memory_exchanges_sends_only_the_latest() {
    let (url, seen) = mock().await;
    let dir = folder("exchanges");
    let s = session(&dir, &url, "memory_exchanges = 1").await;
    assert_eq!(s.memory_exchanges, 1);
    let mut chat = s.new_chat();
    ask(&s, &mut chat, "first").await;
    ask(&s, &mut chat, "second").await;
    ask(&s, &mut chat, "third").await;
    let last = seen.lock().unwrap()[2].clone();
    assert!(!last.contains("first"), "{last}");
    assert!(last.contains("second") && last.contains("third"), "{last}");
    s.close().await;
    let _ = std::fs::remove_dir_all(dir);
}

/// An empty folder standing for the person's home, so the tests never read the developer's ~/.agents.
fn no_home() -> PathBuf {
    let dir = std::env::temp_dir().join(format!("imp-chat-no-home-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    dir
}
