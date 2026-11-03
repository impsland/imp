//! The MCP client and the agent loop, against a tiny fake MCP server and a mock chat service.
//!
//! The fake MCP server is this very test program started again with `IMP_FAKE_MCP=1`. That needs
//! no extra binary. Lines the test harness prints are skipped by the client because they are not JSON.

use imp_core::{
    AgentEvent, ChatMessage, McpClient, McpHost, McpServerSpec, OpenAiClient, RetryPolicy, Role,
    ToolSelection, Toolbox, run_agent,
};
use serde_json::{Value, json};
use std::io::{BufRead, Write};
use std::rc::Rc;
use std::sync::{Arc, Mutex};
use std::time::Duration;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpListener;

/// Not a real test. It is the fake server when `IMP_FAKE_MCP` is set and does nothing otherwise.
#[test]
fn fake_mcp_server() {
    if std::env::var("IMP_FAKE_MCP").is_err() {
        return;
    }
    let mut out = std::io::stdout();
    for line in std::io::stdin().lock().lines() {
        let Ok(message) = serde_json::from_str::<Value>(&line.unwrap()) else {
            continue;
        };
        let Some(id) = message.get("id").cloned() else {
            continue;
        };
        let params = &message["params"];
        let result = match message["method"].as_str().unwrap() {
            "initialize" => {
                json!({ "protocolVersion": "2025-03-26", "capabilities": { "tools": {} }, "serverInfo": { "name": "fake", "version": "1" } })
            }
            "tools/list" if params.get("cursor").is_none() => json!({
                "tools": [
                    { "name": "echo", "description": "Echo the text", "inputSchema": { "type": "object", "properties": { "text": { "type": "string" } } } },
                    { "name": "fail", "description": "Always fails", "inputSchema": { "type": "object" } },
                ],
                "nextCursor": "more",
            }),
            "tools/list" => json!({ "tools": [
                { "name": "slow", "description": "Takes long", "inputSchema": { "type": "object" } },
                { "name": "pid", "description": "Process id", "inputSchema": { "type": "object" } },
                { "name": "secret", "description": "Reads an env var", "inputSchema": { "type": "object" } },
            ] }),
            "tools/call" => match params["name"].as_str().unwrap() {
                "echo" => {
                    let text = params["arguments"]["text"].as_str().unwrap_or("");
                    json!({ "content": [{ "type": "text", "text": format!("echo: {text}") }] })
                }
                "fail" => {
                    json!({ "isError": true, "content": [{ "type": "text", "text": "it broke" }] })
                }
                "slow" => {
                    std::thread::sleep(Duration::from_secs(5));
                    json!({ "content": [] })
                }
                "pid" => {
                    json!({ "content": [{ "type": "text", "text": std::process::id().to_string() }] })
                }
                _ => {
                    let v = std::env::var("FAKE_VALUE").unwrap_or_default();
                    json!({ "content": [{ "type": "text", "text": v }] })
                }
            },
            _ => json!({}),
        };
        // A noise line and a notification first, which a client has to skip.
        writeln!(out, "not json at all").unwrap();
        writeln!(
            out,
            "{}",
            json!({ "jsonrpc": "2.0", "method": "notifications/message" })
        )
        .unwrap();
        writeln!(
            out,
            "{}",
            json!({ "jsonrpc": "2.0", "id": id, "result": result })
        )
        .unwrap();
        out.flush().unwrap();
    }
}

fn spec(env: &[(&str, &str)]) -> McpServerSpec {
    let mut all: Vec<(String, String)> = vec![("IMP_FAKE_MCP".into(), "1".into())];
    all.extend(env.iter().map(|(k, v)| (k.to_string(), v.to_string())));
    McpServerSpec {
        name: "fake".into(),
        command: std::env::current_exe().unwrap().to_string_lossy().into(),
        args: [
            "--exact",
            "fake_mcp_server",
            "--nocapture",
            "--test-threads=1",
        ]
        .map(String::from)
        .to_vec(),
        env: all,
    }
}

#[tokio::test]
async fn lists_calls_and_reports_errors() {
    let client = McpClient::connect_stdio(&spec(&[]), Duration::from_secs(20))
        .await
        .unwrap();
    let names: Vec<String> = client
        .list_tools()
        .await
        .unwrap()
        .into_iter()
        .map(|t| t.name)
        .collect();
    assert_eq!(names, ["echo", "fail", "slow", "pid", "secret"]);
    let text = client.call_tool("echo", json!({ "text": "hi" })).await;
    assert_eq!(text.unwrap(), "echo: hi");
    let failed = client.call_tool("fail", json!({})).await.unwrap();
    assert_eq!(failed, "Error: it broke");
}

#[tokio::test]
async fn a_slow_call_times_out() {
    let client = McpClient::connect_stdio(&spec(&[]), Duration::from_millis(800))
        .await
        .unwrap();
    let error = client.call_tool("slow", json!({})).await.unwrap_err();
    assert!(error.to_string().contains("in time"), "{error}");
}

#[tokio::test]
async fn a_missing_command_is_a_plain_error() {
    let mut s = spec(&[]);
    s.command = "/no/such/imp-mcp-server".into();
    let error = McpClient::connect_stdio(&s, Duration::from_secs(2))
        .await
        .err()
        .unwrap();
    assert!(error.to_string().contains("could not start"));
    let (host, problems) = McpHost::connect(&[s], Duration::from_secs(2)).await;
    assert_eq!(problems.len(), 1);
    assert!(imp_core::ToolHost::tools(&host).is_empty());
}

#[cfg(unix)]
#[tokio::test]
async fn the_child_is_killed_on_drop() {
    let client = McpClient::connect_stdio(&spec(&[]), Duration::from_secs(20))
        .await
        .unwrap();
    let pid = client.call_tool("pid", json!({})).await.unwrap();
    let alive = |pid: &str| {
        std::process::Command::new("kill")
            .args(["-0", pid])
            .output()
            .map(|o| o.status.success())
            .unwrap_or(false)
    };
    assert!(alive(&pid));
    drop(client);
    for _ in 0..50 {
        if !alive(&pid) {
            return;
        }
        tokio::time::sleep(Duration::from_millis(100)).await;
    }
    panic!("the server process {pid} is still running");
}

/// Answers each request with the next canned SSE body and records the request bodies.
async fn mock(bodies: Vec<String>) -> (String, Arc<Mutex<Vec<Value>>>) {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let url = format!("http://{}/v1", listener.local_addr().unwrap());
    let seen = Arc::new(Mutex::new(Vec::new()));
    let log = seen.clone();
    tokio::spawn(async move {
        let mut n = 0;
        loop {
            let Ok((mut socket, _)) = listener.accept().await else {
                return;
            };
            let body = bodies.get(n).or(bodies.last()).unwrap().clone();
            n += 1;
            let log = log.clone();
            tokio::spawn(async move {
                let mut data = Vec::new();
                let mut buf = [0u8; 8192];
                loop {
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
                            if let Ok(v) = serde_json::from_str(rest) {
                                log.lock().unwrap().push(v);
                            }
                            break;
                        }
                    }
                    if read == 0 {
                        break;
                    }
                }
                let head = "HTTP/1.1 200 OK\r\ncontent-type: text/event-stream\r\nconnection: close\r\n\r\n";
                let _ = socket.write_all(format!("{head}{body}").as_bytes()).await;
                let _ = socket.shutdown().await;
            });
        }
    });
    (url, seen)
}

fn call_body(id: &str, name: &str, args: &str) -> String {
    let delta = json!({ "choices": [{ "delta": { "tool_calls": [{ "index": 0, "id": id, "function": { "name": name, "arguments": args } }] } }] });
    let end = json!({ "choices": [{ "delta": {}, "finish_reason": "tool_calls" }] });
    format!("data: {delta}\n\ndata: {end}\n\ndata: [DONE]\n\n")
}

fn text_body(text: &str) -> String {
    let delta = json!({ "choices": [{ "delta": { "content": text } }] });
    let end = json!({ "choices": [{ "delta": {}, "finish_reason": "stop" }] });
    format!("data: {delta}\n\ndata: {end}\n\ndata: [DONE]\n\n")
}

async fn toolbox(env: &[(&str, &str)]) -> Toolbox {
    let (host, problems) = McpHost::connect(&[spec(env)], Duration::from_secs(20)).await;
    assert!(problems.is_empty(), "{problems:?}");
    let mut toolbox = Toolbox::new();
    toolbox.add(Rc::new(host));
    toolbox
}

fn names_offered(request: &Value) -> Vec<String> {
    request["tools"]
        .as_array()
        .into_iter()
        .flatten()
        .map(|t| t["function"]["name"].as_str().unwrap().to_string())
        .collect()
}

#[tokio::test]
async fn the_agent_runs_a_tool_and_answers() {
    let (url, seen) = mock(vec![
        call_body("c1", "fake__echo", "{\"text\":\"ping\"}"),
        text_body("The tool said echo: ping"),
    ])
    .await;
    let client = OpenAiClient::new(&url, None, RetryPolicy::none()).unwrap();
    let toolbox = toolbox(&[]).await;
    let mut messages = vec![ChatMessage::system("s"), ChatMessage::user("use it")];
    let mut events = Vec::new();
    let answer = run_agent(
        &client,
        "m",
        &mut messages,
        &toolbox,
        &ToolSelection::all(),
        5,
        |e| events.push(e),
    )
    .await
    .unwrap();
    assert_eq!(answer, "The tool said echo: ping");
    assert_eq!(messages[3].role, Role::Tool);
    assert_eq!(messages[3].content, "echo: ping");
    assert!(
        events
            .iter()
            .any(|e| matches!(e, AgentEvent::ToolStart(c) if c.name == "fake__echo"))
    );
    let requests = seen.lock().unwrap();
    assert_eq!(requests.len(), 2);
    assert_eq!(names_offered(&requests[0]).len(), 5);
}

#[tokio::test]
async fn switched_off_tools_are_not_offered_or_run() {
    let (url, seen) = mock(vec![
        call_body("c1", "fake__echo", "{\"text\":\"ping\"}"),
        text_body("ok"),
    ])
    .await;
    let client = OpenAiClient::new(&url, None, RetryPolicy::none()).unwrap();
    let toolbox = toolbox(&[]).await;
    let mut selection = ToolSelection::all();
    selection.tools_off.insert("mcp.fake.echo".into());
    let mut messages = vec![ChatMessage::user("go")];
    run_agent(&client, "m", &mut messages, &toolbox, &selection, 5, |_| {})
        .await
        .unwrap();
    let requests = seen.lock().unwrap();
    assert!(!names_offered(&requests[0]).contains(&"fake__echo".to_string()));
    assert!(messages[2].content.contains("switched off"));
}

#[tokio::test]
async fn the_step_limit_stops_a_loop() {
    let (url, seen) = mock(vec![call_body("c", "fake__echo", "{}")]).await;
    let client = OpenAiClient::new(&url, None, RetryPolicy::none()).unwrap();
    let toolbox = toolbox(&[]).await;
    let mut messages = vec![ChatMessage::user("loop")];
    let error = run_agent(
        &client,
        "m",
        &mut messages,
        &toolbox,
        &ToolSelection::all(),
        3,
        |_| {},
    )
    .await
    .unwrap_err();
    assert!(error.to_string().contains("3 steps"), "{error}");
    assert_eq!(seen.lock().unwrap().len(), 3);
}

#[tokio::test]
async fn environment_values_reach_the_server() {
    let toolbox = toolbox(&[("FAKE_VALUE", "from-env")]).await;
    let answer = imp_core::ToolHost::call(&toolbox, "fake__secret", "{}").await;
    assert_eq!(answer.as_deref(), Some("from-env"));
    assert_eq!(imp_core::ToolHost::call(&toolbox, "nope", "{}").await, None);
}
