//! What the model is sent of a chat, against a local mock service: the core's chat memory, and
//! `/compact`, which sums the chat up and goes on from the summary.

mod common;

use common::{World, mock};
use imp_chat::session::{Session, SessionOptions};
use imp_chat::slash::{self, Context, Outcome};

/// An Imp called pip on the mock service. `extra` is more of `imp.json`'s `imps.pip`.
async fn session(w: &World, url: &str, extra: &str) -> Session {
    w.with_mock(url);
    w.agent("pip", "description: Kind", "Kind.");
    if !extra.is_empty() {
        let mut config = w.read_config();
        config["imps"] =
            serde_json::json!({ "pip": serde_json::from_str::<serde_json::Value>(extra).unwrap() });
        w.write_config(&config.to_string());
    }
    Session::open(&w.settings(), None, SessionOptions::default())
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
        &imp_engine::ToolSelection::all(),
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
    let w = World::new("compact");
    let mut s = session(&w, &url, "").await;
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
}

#[tokio::test]
async fn memory_exchanges_sends_only_the_latest() {
    let (url, seen) = mock().await;
    let w = World::new("exchanges");
    let s = session(
        &w,
        &url,
        r#"{"id":"7c0e0000-0000-4000-8000-000000000001","memory":{"exchanges":1}}"#,
    )
    .await;
    assert_eq!(s.memory_exchanges, 1);
    let mut chat = s.new_chat();
    ask(&s, &mut chat, "first").await;
    ask(&s, &mut chat, "second").await;
    ask(&s, &mut chat, "third").await;
    let last = seen.lock().unwrap()[2].clone();
    assert!(!last.contains("first"), "{last}");
    assert!(last.contains("second") && last.contains("third"), "{last}");
    s.close().await;
}
