//! The chat client against a local mock server. No real service is called.

use imp_core::{ChatError, ChatMessage, OpenAiClient, RetryPolicy, StreamEvent};
use std::sync::Arc;
use std::sync::atomic::{AtomicUsize, Ordering};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpListener;

/// Answers each connection with the next canned response. Returns the base URL, the request
/// counter and the raw requests seen.
async fn mock(
    responses: Vec<String>,
) -> (String, Arc<AtomicUsize>, Arc<std::sync::Mutex<Vec<String>>>) {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let url = format!("http://{}/v1", listener.local_addr().unwrap());
    let count = Arc::new(AtomicUsize::new(0));
    let seen = Arc::new(std::sync::Mutex::new(Vec::new()));
    let (c, s) = (count.clone(), seen.clone());
    tokio::spawn(async move {
        loop {
            let Ok((mut socket, _)) = listener.accept().await else {
                return;
            };
            let n = c.fetch_add(1, Ordering::SeqCst);
            let response = responses.get(n).or(responses.last()).unwrap().clone();
            let seen = s.clone();
            tokio::spawn(async move {
                let mut data = Vec::new();
                let mut buf = [0u8; 4096];
                loop {
                    let read = socket.read(&mut buf).await.unwrap_or(0);
                    data.extend_from_slice(&buf[..read]);
                    let text = String::from_utf8_lossy(&data).to_string();
                    if let Some((head, body)) = text.split_once("\r\n\r\n") {
                        let length = head
                            .lines()
                            .find_map(|l| {
                                l.to_ascii_lowercase()
                                    .strip_prefix("content-length:")
                                    .map(|v| v.trim().parse::<usize>().unwrap())
                            })
                            .unwrap_or(0);
                        if body.len() >= length {
                            break;
                        }
                    }
                    if read == 0 {
                        break;
                    }
                }
                seen.lock()
                    .unwrap()
                    .push(String::from_utf8_lossy(&data).to_string());
                let _ = socket.write_all(response.as_bytes()).await;
                let _ = socket.shutdown().await;
            });
        }
    });
    (url, count, seen)
}

fn sse(chunks: &[&str]) -> String {
    let body: String = chunks.iter().map(|c| format!("data: {c}\n\n")).collect();
    format!("HTTP/1.1 200 OK\r\ncontent-type: text/event-stream\r\nconnection: close\r\n\r\n{body}")
}

fn status(code: u16, body: &str) -> String {
    format!(
        "HTTP/1.1 {code} X\r\ncontent-type: application/json\r\ncontent-length: {}\r\nconnection: close\r\n\r\n{body}",
        body.len()
    )
}

fn fast() -> RetryPolicy {
    RetryPolicy::new(2, 0.01, 1.0, 0.01)
}

#[tokio::test]
async fn streams_text_and_tool_calls_with_the_key() {
    let (url, _, seen) = mock(vec![sse(&[
        r#"{"choices":[{"delta":{"role":"assistant","content":"Hel"}}]}"#,
        r#"{"choices":[{"delta":{"content":"lo"}}]}"#,
        r#"{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"c1","function":{"name":"look","arguments":"{\"a\":"}}]}}]}"#,
        r#"{"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"1}"}}]},"finish_reason":"tool_calls"}]}"#,
        "[DONE]",
    ])])
    .await;
    let client = OpenAiClient::new(&url, Some("sk-secret".into()), fast()).unwrap();
    let mut pieces = Vec::new();
    let reply = client
        .stream(
            "m",
            &[ChatMessage::user("hi")],
            &[],
            |e| pieces.push(e.clone()),
            |_| {},
        )
        .await
        .unwrap();
    assert_eq!(reply.text, "Hello");
    assert_eq!(reply.tool_calls.len(), 1);
    assert_eq!(reply.tool_calls[0].arguments, "{\"a\":1}");
    assert_eq!(reply.finish_reason.as_deref(), Some("tool_calls"));
    assert!(pieces.contains(&StreamEvent::Text("Hel".into())));
    let request = seen.lock().unwrap()[0].to_ascii_lowercase();
    assert!(request.starts_with("post /v1/chat/completions"));
    assert!(request.contains("authorization: bearer sk-secret"));
    assert!(request.contains("\"stream\":true"));
}

#[tokio::test]
async fn retries_a_503_then_succeeds() {
    let ok = sse(&[
        r#"{"choices":[{"delta":{"content":"ok"},"finish_reason":"stop"}]}"#,
        "[DONE]",
    ]);
    let (url, count, _) = mock(vec![status(503, "{}"), ok]).await;
    let client = OpenAiClient::new(&url, None, fast()).unwrap();
    let mut notices = 0;
    let reply = client
        .stream(
            "m",
            &[ChatMessage::user("hi")],
            &[],
            |_| {},
            |_| notices += 1,
        )
        .await
        .unwrap();
    assert_eq!(reply.text, "ok");
    assert_eq!(count.load(Ordering::SeqCst), 2);
    assert_eq!(notices, 1);
}

#[tokio::test]
async fn does_not_retry_a_401_and_gives_up_after_the_limit() {
    let (url, count, _) = mock(vec![status(401, r#"{"error":"bad key"}"#)]).await;
    let client = OpenAiClient::new(&url, None, fast()).unwrap();
    let err = client
        .stream("m", &[ChatMessage::user("hi")], &[], |_| {}, |_| {})
        .await
        .unwrap_err();
    assert!(matches!(err, ChatError::Http { status: 401, .. }));
    assert_eq!(count.load(Ordering::SeqCst), 1);

    let (url, count, _) = mock(vec![status(503, "{}")]).await;
    let client = OpenAiClient::new(&url, None, fast()).unwrap();
    let err = client
        .stream("m", &[ChatMessage::user("hi")], &[], |_| {}, |_| {})
        .await
        .unwrap_err();
    assert!(matches!(err, ChatError::Http { status: 503, .. }));
    assert_eq!(count.load(Ordering::SeqCst), 3);
}
