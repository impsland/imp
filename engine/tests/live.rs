//! Live API (opt-in): `IMP_LIVE_TESTS=1 cargo test -p imp-engine --test live -- --nocapture`.
//! Talks to the real service in ./.env (`OPENAI_BASE_URL`, `OPENAI_API_KEY`, `OPENAI_MODEL`), and makes
//! real pictures and speech through the AI presets' MCP servers (@dtst/img, @dtst/tts) with the models
//! in `OPENAI_IMAGE_MODEL` and `OPENAI_SPEECH_MODEL` (and `OPENAI_VOICE` if the speech model needs one).
//! Costs a few cents.
//! This is the path the command line takes: the core's HTTP client, its stdio MCP transport and its agent loop.

use imp_engine::{
    AgentEvent, ChatMessage, McpEndpoint, McpHost, McpSecrets, McpServerSpec, OpenAiClient,
    RetryPolicy, Role, ToolSelection, run_agent,
};
use std::collections::HashMap;
use std::path::PathBuf;
use std::time::Duration;

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

/// A stdio server that starts in `dir`, as a user sets it up.
fn server(
    env: &HashMap<String, String>,
    name: &str,
    package: &str,
    dir: &std::path::Path,
    extra: &[(&str, &str)],
) -> McpServerSpec {
    let mut vars = vec![
        (
            "OPENAI_BASE_URL".to_string(),
            env["OPENAI_BASE_URL"].clone(),
        ),
        ("OPENAI_API_KEY".to_string(), env["OPENAI_API_KEY"].clone()),
    ];
    vars.extend(extra.iter().map(|(k, v)| (k.to_string(), v.to_string())));
    McpServerSpec {
        name: name.to_string(),
        endpoint: McpEndpoint::Command {
            command: "/bin/sh".to_string(),
            args: [
                "-c",
                r#"cd "$1" && exec npx -y "$2""#,
                "sh",
                dir.to_str().unwrap(),
                package,
            ]
            .map(String::from)
            .to_vec(),
            env: McpSecrets(vars),
        },
    }
}

fn folder() -> PathBuf {
    let dir = std::env::temp_dir().join(format!("imp-engine-live-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    dir
}

#[tokio::test]
async fn a_plain_chat_streams_an_answer() {
    let Some(env) = live() else { return };
    let (client, model) = client(&env);
    let host = McpHost::connect(&[], Duration::from_secs(5)).await.0;
    let mut messages = vec![ChatMessage::new(
        Role::User,
        "Reply with exactly the word: pong",
    )];
    let mut streamed = 0;
    let answer = run_agent(
        &client,
        &model,
        &mut messages,
        &host,
        &ToolSelection::default(),
        4,
        |e| {
            if let AgentEvent::Stream(_) = e {
                streamed += 1
            }
        },
    )
    .await
    .expect("answer");
    println!("live core: chat answered {answer:?} after {streamed} stream events");
    assert!(answer.to_lowercase().contains("pong"), "{answer}");
    assert!(streamed > 0);
}

#[tokio::test]
async fn an_imp_draws_and_speaks_with_its_tools() {
    let Some(env) = live() else { return };
    let (client, model) = client(&env);
    let dir = folder();
    let value = |name: &str| {
        env.get(name)
            .filter(|v| !v.is_empty())
            .unwrap_or_else(|| panic!("{name} is not in .env"))
            .as_str()
    };
    let mut speech = vec![("OPENAI_MODEL", value("OPENAI_SPEECH_MODEL"))];
    if let Some(voice) = env.get("OPENAI_VOICE").filter(|v| !v.is_empty()) {
        speech.push(("OPENAI_VOICE", voice.as_str()));
    }
    let specs = [
        server(
            &env,
            "img",
            "@dtst/img",
            &dir,
            &[("OPENAI_MODEL", value("OPENAI_IMAGE_MODEL"))],
        ),
        server(&env, "tts", "@dtst/tts", &dir, &speech),
    ];
    let (host, problems) = McpHost::connect(&specs, Duration::from_secs(120)).await;
    assert!(problems.is_empty(), "{problems:?}");

    let mut messages = vec![
        ChatMessage::new(
            Role::System,
            "You are Pip, a small helper. Use your tools when asked. Answer in one short sentence.",
        ),
        ChatMessage::new(
            Role::User,
            "Please draw a tiny yellow star with your picture tool, then say \"Hello from Pip\" aloud with your speech tool.",
        ),
    ];
    let mut results: Vec<(String, String)> = Vec::new();
    let answer = run_agent(
        &client,
        &model,
        &mut messages,
        &host,
        &ToolSelection::default(),
        6,
        |e| {
            if let AgentEvent::ToolResult { name, content, .. } = e {
                results.push((name, content))
            }
        },
    )
    .await
    .expect("answer");
    host.close().await;

    let made: Vec<(String, u64)> = std::fs::read_dir(&dir)
        .map(|d| {
            d.flatten()
                .map(|e| {
                    let len = e.metadata().map(|m| m.len()).unwrap_or(0);
                    (e.file_name().to_string_lossy().into_owned(), len)
                })
                .collect()
        })
        .unwrap_or_default();
    let _ = std::fs::remove_dir_all(&dir);
    for (name, content) in &results {
        let short: String = content.chars().take(300).collect();
        println!("live core: {name} -> {}", short.replace('\n', " | "));
    }
    println!("live core: files made {made:?}");
    println!("live core: reply {answer:?}");

    let used = |tool: &str| results.iter().any(|(n, _)| n.contains(tool));
    assert!(used("generate_image"), "{results:?}");
    assert!(used("generate_speech"), "{results:?}");
    let failed: Vec<&String> = results
        .iter()
        .filter(|(_, c)| c.starts_with("Error"))
        .map(|(n, _)| n)
        .collect();
    assert!(failed.is_empty(), "failed: {failed:?}");
    assert!(made.iter().any(|(_, len)| *len > 1000), "{made:?}");
}
