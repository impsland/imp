//! Custom commands against a real session: what a template runs or reads goes through the Imp's
//! permission rules, and a subtask answers in a conversation of its own.

mod common;

use common::World;
use imp_chat::custom;
use imp_chat::session::{Session, SessionOptions};
use imp_chat::slash::{self, Context};
use imp_engine::config::Command;

async fn session(w: &World, url: &str) -> Session {
    w.with_mock(url);
    w.agent("pip", "description: Kind", "Kind.");
    Session::open(&w.settings(), Some("pip"), SessionOptions::default())
        .await
        .unwrap()
}

async fn run(session: &mut Session, line: &str) {
    let mut device = None;
    slash::run(
        line,
        Context {
            session,
            device: &mut device,
            device_options: None,
            visiting: None,
            history: &[],
        },
    )
    .await;
}

#[tokio::test]
async fn a_shell_command_in_a_template_waits_for_the_shell_permission() {
    let w = World::new("custom-shell");
    let mut s = session(&w, "http://127.0.0.1:1/v1").await;
    let command = Command::parse("status", "Said: !`echo hello`").unwrap();

    // `ask`, and nobody to ask in a test: it counts as a refusal and nothing runs.
    run(&mut s, "/permission add shell '*' ask").await;
    let err = custom::prepare(&command, "", &s.world()).await.unwrap_err();
    assert!(
        err.contains("echo hello") && err.contains("nobody to ask"),
        "{err}"
    );

    run(&mut s, "/permission remove 1").await;
    run(&mut s, "/permission add shell 'echo hello' deny").await;
    let err = custom::prepare(&command, "", &s.world()).await.unwrap_err();
    assert!(err.starts_with("Not allowed: shell echo hello"), "{err}");

    run(&mut s, "/permission remove 1").await;
    run(&mut s, "/permission add shell 'echo hello' allow").await;
    let ready = custom::prepare(&command, "", &s.world()).await.unwrap();
    assert_eq!(ready.text, "Said: hello");
    s.close().await;
}

#[tokio::test]
async fn a_file_in_a_template_waits_for_the_read_permission() {
    let w = World::new("custom-read");
    let mut s = session(&w, "http://127.0.0.1:1/v1").await;
    w.in_work("notes.txt", "remember the milk\n");
    let command = Command::parse("look", "Look at @notes.txt and @nothing.txt").unwrap();

    run(&mut s, "/permission add read '*' deny").await;
    let err = custom::prepare(&command, "", &s.world()).await.unwrap_err();
    assert!(err.starts_with("Not allowed: read "), "{err}");

    run(&mut s, "/permission remove 1").await;
    run(&mut s, "/permission add read '*' allow").await;
    let ready = custom::prepare(&command, "", &s.world()).await.unwrap();
    assert!(
        ready
            .text
            .contains("<file path=\"notes.txt\">\nremember the milk\n</file>"),
        "{}",
        ready.text
    );
    assert!(
        ready.text.ends_with("and @nothing.txt"),
        "a name that is no file stays"
    );
    s.close().await;
}

#[tokio::test]
async fn a_subtask_answers_in_a_conversation_of_its_own() {
    let w = World::new("custom-subtask");
    let (url, bodies) = common::mock().await;
    let s = session(&w, &url).await;
    let command = Command::parse("ask", "---\nsubtask: true\n---\nWhat is $1?").unwrap();
    let ready = custom::prepare(&command, "rust", &s.world()).await.unwrap();
    assert!(ready.subtask);
    let answer = s
        .one_off(ready.agent, ready.model)
        .run(&ready.text)
        .await
        .unwrap();
    assert_eq!(answer, "Answer 1");
    assert!(bodies.lock().unwrap()[0].contains("What is rust?"));
    s.close().await;
}
