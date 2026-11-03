//! The line chat against a local mock service. No real service is called.

use imp_cli::chat_state::ChatState;
use imp_cli::commands::{Io, chat_loop};
use imp_core::{OpenAiClient, RetryPolicy, Role};
use std::io::Cursor;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpListener;

async fn mock(reply: &'static str) -> String {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let url = format!("http://{}/v1", listener.local_addr().unwrap());
    tokio::spawn(async move {
        loop {
            let Ok((mut socket, _)) = listener.accept().await else {
                return;
            };
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

#[tokio::test]
async fn a_line_gets_a_streamed_reply() {
    let url = mock("Hello there").await;
    let client = OpenAiClient::new(&url, None, RetryPolicy::none()).unwrap();
    let mut input = Cursor::new(b"hi\n\n/quit\nnot read\n".to_vec());
    let (mut out, mut err) = (Vec::new(), Vec::new());
    let mut io = Io {
        input: &mut input,
        out: &mut out,
        err: &mut err,
    };
    chat_loop(&client, "m", "pip", ChatState::new("You are pip."), &mut io)
        .await
        .unwrap();
    assert_eq!(String::from_utf8(out).unwrap(), "Hello there\n");
    assert!(
        String::from_utf8(err)
            .unwrap()
            .contains("Chatting with pip")
    );
}

#[tokio::test]
async fn a_failing_service_is_reported_and_the_chat_goes_on() {
    let client = OpenAiClient::new("http://127.0.0.1:1/v1", None, RetryPolicy::none()).unwrap();
    let mut input = Cursor::new(b"hi\nagain\n".to_vec());
    let (mut out, mut err) = (Vec::new(), Vec::new());
    let mut io = Io {
        input: &mut input,
        out: &mut out,
        err: &mut err,
    };
    chat_loop(&client, "m", "pip", ChatState::new("s"), &mut io)
        .await
        .unwrap();
    assert_eq!(
        String::from_utf8(err)
            .unwrap()
            .matches("Something went wrong")
            .count(),
        2
    );
    let _ = Role::User;
}
