//! The `/` commands of a chat against a real session and settings file. No model is called: the commands
//! change settings, and each change is in the file afterwards.

use imp_cli::config::Config;
use imp_cli::session::{Session, SessionOptions, expand, mcp_specs_in};
use imp_cli::slash::{self, Context, NoteKind, Outcome};
use imp_core::McpEndpoint;
use std::path::{Path, PathBuf};

fn folder(name: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!("imp-cli-slash-{name}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    dir
}

async fn session(dir: &Path) -> Session {
    let config = dir.join("config.toml");
    std::fs::write(
        &config,
        "api_key_env = \"IMP_TEST_NO_KEY\"\n[imps.slashtest]\npersonality = \"Kind.\"\nbase_url = \"http://127.0.0.1:1/v1\"\nmodel = \"first\"\n\n[imps.other]\npersonality = \"Dry.\"\nbase_url = \"http://127.0.0.1:1/v1\"\nmodel = \"m\"\n",
    )
    .unwrap();
    Session::open(
        &config,
        Some("slashtest"),
        SessionOptions {
            workspace: Some(dir.to_path_buf()),
            remote: None,
        },
    )
    .await
    .unwrap()
}

async fn run(session: &mut Session, line: &str) -> Outcome {
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
    .await
}

fn said(outcome: &Outcome) -> String {
    match outcome {
        Outcome::Notes(notes) | Outcome::Sent(notes) => notes
            .iter()
            .map(|n| match n.kind {
                NoteKind::Problem => format!("! {}", n.text),
                _ => n.text.clone(),
            })
            .collect::<Vec<_>>()
            .join("\n"),
        other => format!("{other:?}"),
    }
}

#[tokio::test]
async fn model_address_and_personality_change_and_are_saved() {
    let dir = folder("settings");
    let mut s = session(&dir).await;
    assert!(said(&run(&mut s, "/model").await).contains("first"));
    assert!(said(&run(&mut s, "/model openai/gpt-6-luna").await).contains("Saved"));
    assert_eq!(s.model, "openai/gpt-6-luna");
    assert!(said(&run(&mut s, "/base_url ftp://nope").await).starts_with("! "));
    run(&mut s, "/url https://openrouter.ai/api/v1/").await;
    run(&mut s, "/personality Short answers, lots of jokes.").await;
    let config = Config::load(&s.path).unwrap();
    let imp = &config.imps["slashtest"];
    assert_eq!(imp.model, "openai/gpt-6-luna");
    assert_eq!(imp.base_url, "https://openrouter.ai/api/v1");
    assert_eq!(imp.personality, "Short answers, lots of jokes.");
    assert!(s.system.contains("lots of jokes"));
    assert!(
        s.system.contains(&dir.display().to_string()),
        "the Imp knows its folder"
    );
    let _ = std::fs::remove_dir_all(&dir);
}

#[tokio::test]
async fn a_key_given_in_the_chat_is_used_and_never_saved_to_the_file() {
    let dir = folder("key");
    let mut s = session(&dir).await;
    assert!(said(&run(&mut s, "/api_key").await).contains("no API key"));
    let shown = said(&run(&mut s, "/api_key sk-test-123").await);
    assert!(!shown.contains("sk-test-123"));
    assert!(said(&run(&mut s, "/api_key").await).contains("this chat"));
    assert!(
        !std::fs::read_to_string(&s.path)
            .unwrap()
            .contains("sk-test")
    );
    assert!(said(&run(&mut s, "/api_key_env sk-oops").await).starts_with("! "));
    let _ = std::fs::remove_dir_all(&dir);
}

#[tokio::test]
async fn mcp_servers_are_added_listed_and_removed() {
    let dir = folder("mcp");
    let mut s = session(&dir).await;
    assert!(said(&run(&mut s, "/mcp").await).contains("has no MCP servers"));
    let added = said(
        &run(
            &mut s,
            "/mcp add files imp-test-no-such-program -y @modelcontextprotocol/server-filesystem .",
        )
        .await,
    );
    assert!(added.contains("Added the MCP server files"), "{added}");
    // The program does not exist: the server is listed with the reason, and the chat goes on.
    assert!(added.contains("! "), "{added}");
    let config = Config::load(&s.path).unwrap();
    let server = &config.imps["slashtest"].mcp_servers["files"];
    assert_eq!(server.command.as_deref(), Some("imp-test-no-such-program"));
    assert_eq!(server.args.last().map(String::as_str), Some("."));
    assert!(said(&run(&mut s, "/mcp remove files").await).contains("Removed"));
    assert!(said(&run(&mut s, "/mcp remove files").await).starts_with("! "));
    assert!(
        Config::load(&s.path).unwrap().imps["slashtest"]
            .mcp_servers
            .is_empty()
    );
    let _ = std::fs::remove_dir_all(&dir);
}

#[tokio::test]
async fn tools_imps_and_unknown_commands() {
    let dir = folder("tools");
    let mut s = session(&dir).await;
    // Two Imps: the message tool is there and can be switched off by id.
    assert!(said(&run(&mut s, "/tools").await).contains("own.troupe.imp_message"));
    run(&mut s, "/tools off own.troupe.imp_message").await;
    assert!(said(&run(&mut s, "/tools").await).contains("off  own.troupe.imp_message"));
    assert!(said(&run(&mut s, "/tools off nope").await).starts_with("! "));
    run(&mut s, "/tools on own.troupe.imp_message").await;
    assert!(
        Config::load(&s.path).unwrap().imps["slashtest"]
            .tools_off
            .is_empty()
    );
    assert!(said(&run(&mut s, "/imp").await).contains("other"));
    assert_eq!(
        run(&mut s, "/imp other").await,
        Outcome::Switch("other".into())
    );
    assert_eq!(run(&mut s, "/clear").await, Outcome::Clear);
    assert_eq!(run(&mut s, "/exit").await, Outcome::Quit);
    let unknown = said(&run(&mut s, "/modle x").await);
    assert!(unknown.contains("Did you mean /model?"), "{unknown}");
    let devices = said(&run(&mut s, "/devices").await);
    assert!(devices.contains("full-screen chat"), "{devices}");
    assert!(said(&run(&mut s, "/help").await).contains("/mcp"));
    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn the_folder_of_the_chat_fills_in_the_arguments() {
    let dir = Path::new("/work/project");
    assert_eq!(expand("${workspaceFolder}", dir), "/work/project");
    assert_eq!(
        expand("--root=${cwd}/notes", dir),
        "--root=/work/project/notes"
    );
    assert_eq!(expand(".", dir), ".");
    let config = Config::parse(
        "[imps.a]\npersonality=\"p\"\nbase_url=\"u\"\nmodel=\"m\"\n[imps.a.mcp_servers.files]\ncommand=\"npx\"\nargs=[\"-y\",\"@modelcontextprotocol/server-filesystem\",\"${workspaceFolder}\"]\n",
    )
    .unwrap();
    let specs = mcp_specs_in(&config.imps["a"], dir, |_| None, |_| None);
    let McpEndpoint::Command { args, .. } = &specs[0].endpoint else {
        panic!("a command")
    };
    assert_eq!(args.last().map(String::as_str), Some("/work/project"));
}
