//! The `/` commands of a chat against a real session and the real files. No model is called: the commands
//! change settings, and each change is in the files afterwards and in the session.

mod common;

use common::World;
use imp_chat::session::{Session, SessionOptions, expand, mcp_specs};
use imp_chat::slash::{self, Context, Outcome};
use imp_engine::McpEndpoint;
use std::path::Path;

async fn session(w: &World) -> Session {
    w.write_config(
        r#"{"model":"mock/first","providers":{"mock":{"options":{"baseURL":"http://127.0.0.1:1/v1"}}}}"#,
    );
    w.agent("slashtest", "description: Kind", "Kind.");
    w.agent("other", "description: Dry", "Dry.");
    Session::open(&w.settings(), Some("slashtest"), SessionOptions::default())
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

async fn run_with_key(session: &mut Session, line: &str, key: &str) -> Outcome {
    let mut device = None;
    slash::run_with_secret(
        line,
        Context {
            session,
            device: &mut device,
            device_options: None,
            visiting: None,
            history: &[],
        },
        Some(key.to_string()),
    )
    .await
}

fn said(outcome: &Outcome) -> String {
    match outcome {
        Outcome::Notes(notes) | Outcome::Sent(notes) => notes
            .iter()
            .map(|n| n.plain())
            .collect::<Vec<_>>()
            .join("\n"),
        other => format!("{other:?}"),
    }
}

#[tokio::test]
async fn model_address_and_prompt_change_and_are_saved() {
    let w = World::new("settings");
    let mut s = session(&w).await;
    assert!(said(&run(&mut s, "/model").await).contains("mock/first"));
    // The default model is in imp.json, an agent's own is in its file. The session takes either at once.
    assert!(said(&run(&mut s, "/model mock/second").await).contains("mock/second"));
    assert_eq!(s.model, "second");
    assert_eq!(w.read_config()["model"], "mock/second");
    assert!(
        said(&run(&mut s, "/model mock/third#high --agent slashtest").await)
            .contains("mock/third#high")
    );
    assert_eq!(s.model, "third");
    assert_eq!(s.model_label, "mock/third#high");
    assert!(
        std::fs::read_to_string(w.agent_file("slashtest"))
            .unwrap()
            .contains("model: mock/third#high")
    );
    assert!(said(&run(&mut s, "/model nowhere/x").await).starts_with("! "));
    assert!(said(&run(&mut s, "/provider set mock url ftp://nope").await).starts_with("! "));
    run(
        &mut s,
        "/provider set mock url https://openrouter.ai/api/v1/",
    )
    .await;
    assert_eq!(
        w.read_config()["providers"]["mock"]["options"]["baseURL"],
        "https://openrouter.ai/api/v1/"
    );
    assert_eq!(s.resolved.base_url, "https://openrouter.ai/api/v1/");
    run(
        &mut s,
        "/agent set slashtest prompt \"Short answers, lots of jokes.\"",
    )
    .await;
    assert!(s.system.contains("lots of jokes"));
    assert!(
        s.system.contains(&w.work.display().to_string()),
        "the Imp knows its folder"
    );
    s.close().await;
}

#[tokio::test]
async fn a_key_is_typed_hidden_and_never_shown() {
    let w = World::new("key");
    let mut s = session(&w).await;
    let list = said(&run(&mut s, "/auth").await);
    assert!(list.contains("mock") && list.contains("none"), "{list}");
    // The command does not take a key from the line: it asks the front end for one to type hidden, and
    // nothing is saved until it comes back with it.
    match run(&mut s, "/auth set mock").await {
        Outcome::Secret { prompt, line } => {
            assert_eq!(
                (prompt.as_str(), line.as_str()),
                ("Key for mock", "/auth set mock")
            );
        }
        other => panic!("a key is asked for, not taken from the line: {other:?}"),
    }
    assert!(!w.auth_json().exists());
    let saved = said(&run_with_key(&mut s, "/auth set mock", "sk-typed-hidden").await);
    assert!(
        saved.contains("Saved") && !saved.contains("sk-typed-hidden"),
        "{saved}"
    );
    assert_eq!(s.resolved.api_key.as_deref(), Some("sk-typed-hidden"));
    // A key pasted where a variable name belongs is refused without being echoed or written.
    let bad = said(&run(&mut s, "/provider set mock key-env sk-oops-123").await);
    assert!(
        bad.starts_with("! ") && !bad.contains("sk-oops-123"),
        "{bad}"
    );
    assert!(
        !std::fs::read_to_string(w.imp_json())
            .unwrap()
            .contains("sk-oops")
    );
    // A key saved elsewhere is used by the chat once it is taken again, and listed as saved.
    w.settings()
        .store
        .update_auth(|a| {
            a.providers.insert(
                "mock".into(),
                imp_engine::config::ProviderAuth {
                    key: "sk-saved-456".into(),
                },
            );
        })
        .unwrap();
    let said_so = s
        .sync()
        .await
        .unwrap()
        .expect("another app changed auth.json");
    assert!(said_so.starts_with("Settings changed"), "{said_so}");
    assert_eq!(s.resolved.api_key.as_deref(), Some("sk-saved-456"));
    let list = said(&run(&mut s, "/auth").await);
    assert!(
        list.contains("saved") && !list.contains("sk-saved-456"),
        "{list}"
    );
    s.close().await;
}

#[tokio::test]
async fn mcp_servers_are_added_listed_switched_and_removed() {
    let w = World::new("mcp");
    let mut s = session(&w).await;
    assert!(said(&run(&mut s, "/mcp").await).contains("Nothing here yet"));
    run(
        &mut s,
        "/mcp add files --command imp-test-no-such-program -y @modelcontextprotocol/server-filesystem .",
    )
    .await;
    // The program does not exist: the server is listed with the reason, and the chat goes on.
    assert_eq!(s.servers.len(), 1, "{:?}", s.servers);
    assert!(s.servers[0].tools.is_err());
    assert!(!s.warnings.is_empty());
    let server = &w.read_config()["mcp"]["files"];
    assert_eq!(server["type"], "local");
    assert_eq!(
        server["command"],
        serde_json::json!([
            "imp-test-no-such-program",
            "-y",
            "@modelcontextprotocol/server-filesystem",
            "."
        ])
    );
    // Off for this Imp: a rule in its file, and the session stops using the server.
    assert!(said(&run(&mut s, "/mcp disable files --agent slashtest").await).contains("off"));
    assert!(s.servers.is_empty(), "{:?}", s.servers);
    assert!(
        std::fs::read_to_string(w.agent_file("slashtest"))
            .unwrap()
            .contains("files/*")
    );
    run(&mut s, "/mcp enable files --agent slashtest").await;
    assert_eq!(s.servers.len(), 1);
    assert!(said(&run(&mut s, "/mcp remove files").await).contains("Removed"));
    assert!(said(&run(&mut s, "/mcp remove files").await).starts_with("! "));
    assert!(
        w.read_config()["mcp"]
            .as_object()
            .is_none_or(|m| m.is_empty())
    );
    assert!(s.servers.is_empty());
    s.close().await;
}

#[tokio::test]
async fn permissions_switch_tools_off_and_imps_and_unknown_commands() {
    let w = World::new("tools");
    let mut s = session(&w).await;
    // Two Imps: the message tool is there and a rule of the Imp takes it away.
    assert!(said(&run(&mut s, "/tools").await).contains("own.personality.imp_message"));
    let on = s.tools();
    assert!(on.iter().all(|t| t.on), "{on:?}");
    run(&mut s, "/permission add message '*' deny --agent slashtest").await;
    assert!(
        s.tools()
            .iter()
            .any(|t| t.id == "own.personality.imp_message" && !t.on)
    );
    assert!(said(&run(&mut s, "/permission add nonsense x deny").await).starts_with("! "));
    run(&mut s, "/permission remove 1 --agent slashtest").await;
    assert!(s.tools().iter().all(|t| t.on));
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
    s.close().await;
}

#[tokio::test]
async fn a_file_is_not_edited_from_a_chat() {
    let w = World::new("edit");
    let mut s = session(&w).await;
    let out = said(&run(&mut s, "/agent edit slashtest").await);
    assert!(out.starts_with("! ") && out.contains("terminal"), "{out}");
    s.close().await;
}

#[test]
fn the_folder_of_the_chat_fills_in_the_arguments() {
    let dir = Path::new("/work/project");
    let home = Path::new("/home/me");
    assert_eq!(
        expand("${workspaceFolder}", dir, Some(home)),
        "/work/project"
    );
    assert_eq!(
        expand("--root=${cwd}/notes", dir, Some(home)),
        "--root=/work/project/notes"
    );
    assert_eq!(expand(".", dir, Some(home)), ".");
    assert_eq!(expand("~", dir, Some(home)), "/home/me");
    assert_eq!(expand("~/notes", dir, Some(home)), "/home/me/notes");
    assert_eq!(expand("~/notes", dir, None), "~/notes");
    let w = World::new("specs");
    w.write_config(
        r#"{"mcp":{"files":{"type":"local","command":["npx","-y","@modelcontextprotocol/server-filesystem","${workspaceFolder}"],"environment":{"A":"b"}},"web":{"type":"remote","url":"https://x.example/mcp","headers":{"X":"y"}}}}"#,
    );
    let loaded = w.settings().load();
    let specs = mcp_specs(
        &loaded,
        &["files".into(), "web".into(), "gone".into()],
        dir,
        Some(home),
    );
    assert_eq!(specs.len(), 2, "a name nobody has is left out");
    let McpEndpoint::Command { command, args, .. } = &specs[0].endpoint else {
        panic!("a command")
    };
    assert_eq!(command, "npx");
    assert_eq!(args.last().map(String::as_str), Some("/work/project"));
    assert!(
        matches!(&specs[1].endpoint, McpEndpoint::Http { url, .. } if url == "https://x.example/mcp")
    );
}

#[tokio::test]
async fn a_change_made_by_another_app_is_taken_and_said_once() {
    let w = World::new("reload");
    let mut s = session(&w).await;
    assert_eq!(s.sync().await.unwrap(), None, "nothing changed yet");
    // Another app changes the default model in imp.json, and adds a command and a skill.
    w.write_config(
        r#"{"model":"mock/elsewhere","providers":{"mock":{"options":{"baseURL":"http://127.0.0.1:1/v1"}}}}"#,
    );
    let said_so = s.sync().await.unwrap().expect("the file changed");
    assert_eq!(said_so, "Settings changed: model is now mock/elsewhere.");
    assert_eq!(s.model, "elsewhere");
    assert_eq!(s.sync().await.unwrap(), None, "said once");
    // /help takes a change before it lists, and says it first.
    w.write_config(
        r#"{"model":"mock/again","providers":{"mock":{"options":{"baseURL":"http://127.0.0.1:1/v1"}}}}"#,
    );
    let help = said(&run(&mut s, "/help").await);
    assert!(
        help.starts_with("Settings changed: model is now mock/again."),
        "{help}"
    );
    assert_eq!(s.model, "again");
    // A new Imp file of the agents folder is noticed too, and a change that cannot be taken is the error.
    w.agent("third", "description: New", "New.");
    let said_so = s.sync().await.unwrap().unwrap();
    assert!(said_so.contains("Imps"), "{said_so}");
    std::fs::remove_file(w.agent_file("slashtest")).unwrap();
    let gone = s.sync().await.unwrap_err();
    assert!(gone.0.contains("no longer there"), "{}", gone.0);
    assert_eq!(s.sync().await.unwrap(), None, "the failure is said once");
    s.close().await;
}

#[tokio::test]
async fn a_chat_and_the_command_line_are_one_grammar_over_one_configuration() {
    let w = World::new("parity");
    let mut s = session(&w).await;
    // What a chat changes, the command line reads, and the other way around.
    run(
        &mut s,
        "/provider add local --url http://localhost:11434/v1",
    )
    .await;
    let listed = w.imp(&["provider", "list", "--json"]).json().to_string();
    assert!(listed.contains("local"), "{listed}");
    w.imp(&["agent", "new", "Cli", "--model", "local/m"]);
    assert!(said(&run(&mut s, "/agent list").await).contains("Cli"));
    // The same words are refused with the same sentence.
    for (line, args) in [
        (
            "/agent new Bad --model local/m --mode bogus",
            vec![
                "agent", "new", "Bad", "--model", "local/m", "--mode", "bogus",
            ],
        ),
        (
            "/provider set local nope x",
            vec!["provider", "set", "local", "nope", "x"],
        ),
        (
            "/permission add nonsense x deny",
            vec!["permission", "add", "nonsense", "x", "deny"],
        ),
    ] {
        let cli = w.imp_fails(&args);
        let sentence = cli.trim().trim_start_matches("imp: ");
        let chat = said(&run(&mut s, line).await);
        assert!(
            chat.starts_with("! ") && chat.contains(sentence),
            "{line}: {chat} vs {sentence}"
        );
    }
    // What the grammar does not list is not a command: the old per-setting ones are gone.
    for old in [
        "/base_url x",
        "/api_key x",
        "/api_key_env X",
        "/personality x",
        "/settings",
    ] {
        let out = said(&run(&mut s, old).await);
        assert!(out.starts_with("! "), "{old}: {out}");
    }
    s.close().await;
}
