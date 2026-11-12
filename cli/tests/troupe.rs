//! `imp_message` between two Imps of the terminal app, against a local mock service.

use imp_cli::config::Config;
use imp_cli::troupe::ImpMessageHost;
use imp_core::{TalkStore, ToolHost, ToolSelection};
use std::path::PathBuf;
use std::sync::{Arc, Mutex};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpListener;

/// Answers every request with "Answer N" and records the request bodies.
async fn mock() -> (String, Arc<Mutex<Vec<String>>>) {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let url = format!("http://{}/v1", listener.local_addr().unwrap());
    let seen = Arc::new(Mutex::new(Vec::<String>::new()));
    let log = seen.clone();
    tokio::spawn(async move {
        loop {
            let Ok((mut socket, _)) = listener.accept().await else {
                return;
            };
            let log = log.clone();
            tokio::spawn(async move {
                let mut data = Vec::new();
                let mut buf = [0u8; 8192];
                let body = loop {
                    let read = socket.read(&mut buf).await.unwrap_or(0);
                    data.extend_from_slice(&buf[..read]);
                    let text = String::from_utf8_lossy(&data).to_string();
                    if let Some((head, rest)) = text.split_once("\r\n\r\n") {
                        let length = head
                            .lines()
                            .find_map(|l| {
                                l.to_ascii_lowercase()
                                    .strip_prefix("content-length:")
                                    .map(|v| v.trim().parse::<usize>().unwrap())
                            })
                            .unwrap_or(0);
                        if rest.len() >= length {
                            break rest.to_string();
                        }
                    }
                    if read == 0 {
                        break String::new();
                    }
                };
                let n = {
                    let mut log = log.lock().unwrap();
                    log.push(body);
                    log.len()
                };
                let sse = format!(
                    "data: {{\"choices\":[{{\"delta\":{{\"content\":\"Answer {n}\"}}}}]}}\n\ndata: {{\"choices\":[{{\"delta\":{{}},\"finish_reason\":\"stop\"}}]}}\n\ndata: [DONE]\n\n"
                );
                let head = "HTTP/1.1 200 OK\r\ncontent-type: text/event-stream\r\nconnection: close\r\n\r\n";
                let _ = socket.write_all(format!("{head}{sse}").as_bytes()).await;
                let _ = socket.shutdown().await;
            });
        }
    });
    (url, seen)
}

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
    assert!(bodies[1].contains("Pip is another Imp") || bodies[1].contains("pip is another Imp"));
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
