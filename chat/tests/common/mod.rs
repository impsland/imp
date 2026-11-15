//! What several test files share: a local stand-in for an OpenAI-compatible service.

use std::sync::{Arc, Mutex};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpListener;

/// Answers every request with "Answer N" and records the request bodies.
pub async fn mock() -> (String, Arc<Mutex<Vec<String>>>) {
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
