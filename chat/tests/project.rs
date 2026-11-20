//! A chat started in a folder with `AGENTS.md` and `.agents/`: what the Imp is told, which tools it
//! gets, what waits for trust and what the `/` commands say. No model is called and no MCP server starts.

mod common;

use common::World;
use imp_chat::session::{Session, SessionOptions};
use imp_chat::settings::Settings;
use imp_chat::slash::{self, Context, Outcome};

/// A world whose project (`work`, a git folder) has agents, a skill, a command, notes and a tool server,
/// and where the chat starts in `work/app`.
fn project(tag: &str) -> (World, Settings) {
    let w = World::new(tag);
    w.write_config(
        r#"{"model":"mock/first","providers":{"mock":{"options":{"baseURL":"http://127.0.0.1:1/v1"}},"local":{"options":{"baseURL":"http://127.0.0.1:1/v1"}}}}"#,
    );
    w.agent("pip", "description: Kind", "Kind.");
    w.in_work(".agents/AGENTS.md", "Always answer in haiku.");
    w.in_work("app/AGENTS.md", "Tests live in app/tests.");
    w.in_work(
        ".agents/skills/release-notes/SKILL.md",
        "---\nname: release-notes\ndescription: Write the release notes for a version\n---\n1. Read the log.\n",
    );
    w.in_work(
        ".agents/agents/pip.md",
        "---\nmodel: local/small\n---\nA terse helper for this repository.\n",
    );
    w.in_work(
        ".agents/agents/reviewer.md",
        "---\ndescription: Reviews changes\n---\nReviews code and says what could break.\n",
    );
    w.in_work(
        ".agents/commands/ship.md",
        "---\ndescription: Ship it\n---\nShip $ARGUMENTS.\n",
    );
    w.in_work(
        ".agents/imp.json",
        r#"{"mcp":{"files":{"type":"local","command":["this-program-does-not-exist","${workspaceFolder}"]}}}"#,
    );
    let settings = Settings::new(w.env(&[]), w.work.join("app"), Some(w.data.clone())).unwrap();
    (w, settings)
}

async fn open(settings: &Settings, name: Option<&str>) -> Session {
    Session::open(settings, name, SessionOptions::default())
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
        Outcome::Notes(notes) => notes
            .iter()
            .map(|n| n.plain())
            .collect::<Vec<_>>()
            .join("\n"),
        other => format!("{other:?}"),
    }
}

#[tokio::test]
async fn the_folder_tells_the_imp_its_rules_skills_and_agent() {
    let (w, settings) = project("rules");
    let s = open(&settings, Some("pip")).await;
    // AGENTS.md from the project's folder down to the chat's, and the skills by name, in the system text.
    let haiku = s
        .system
        .find("Always answer in haiku.")
        .expect("root rules");
    let tests = s
        .system
        .find("Tests live in app/tests.")
        .expect("app rules");
    assert!(haiku < tests, "the nearer folder comes last");
    assert!(
        s.system
            .contains("- release-notes: Write the release notes for a version")
    );
    assert!(
        !s.system.contains("Read the log."),
        "a skill's text waits for use_skill"
    );
    // The project's agent file wins over the person's own of the same name, model and prompt.
    assert!(s.system.contains("A terse helper for this repository."));
    assert!(!s.system.contains("Kind."));
    assert_eq!(s.model, "small");
    assert_eq!(s.model_label, "local/small");
    let tools = s.tools();
    assert!(
        tools.iter().any(|t| t.name == "use_skill" && t.on),
        "{tools:?}"
    );
    assert!(s.system.contains(&w.work.join("app").display().to_string()));
    s.close().await;
}

#[tokio::test]
async fn the_folders_services_and_servers_wait_to_be_trusted() {
    let (w, settings) = project("trust");
    let mut s = open(&settings, Some("pip")).await;
    assert!(s.servers.is_empty(), "{:?}", s.servers);
    assert!(
        s.notices.iter().any(|n| n.contains("/project trust")),
        "{:?}",
        s.notices
    );
    let out = said(&run(&mut s, "/project").await);
    assert!(out.contains("waiting for trust"), "{out}");
    // Trusting in the chat starts the folder's server, and the chat takes it at once. The program does not
    // exist: the server is listed with the reason and the chat goes on.
    let out = said(&run(&mut s, "/project trust").await);
    assert!(out.contains("Trusting the settings of"), "{out}");
    assert_eq!(s.servers.len(), 1, "{:?}", s.servers);
    assert_eq!(s.servers[0].name, "files");
    assert!(s.servers[0].tools.is_err());
    assert!(
        s.servers[0]
            .target
            .contains(&w.work.join("app").display().to_string())
    );
    assert!(s.notices.is_empty(), "{:?}", s.notices);
    assert!(
        std::fs::read_to_string(w.data.join("trusted_folders.json"))
            .unwrap()
            .contains("work")
    );
    // The person's own settings file never got the folder's server.
    assert!(w.read_config()["mcp"].is_null());
    let out = said(&run(&mut s, "/project untrust").await);
    assert!(out.contains("No longer using"), "{out}");
    assert!(s.servers.is_empty());
    s.close().await;
}

#[tokio::test]
async fn a_project_agent_is_changed_in_its_file_not_by_a_command() {
    let (w, settings) = project("agentfile");
    let mut s = open(&settings, Some("pip")).await;
    let file = w.work.join(".agents/agents/pip.md");
    let before = std::fs::read_to_string(&file).unwrap();
    let config_before = std::fs::read_to_string(w.imp_json()).unwrap();
    let out = said(&run(&mut s, "/model mock/big --agent pip").await);
    assert!(out.starts_with("! ") && out.contains("pip.md"), "{out}");
    assert_eq!(std::fs::read_to_string(&file).unwrap(), before);
    assert_eq!(
        std::fs::read_to_string(w.imp_json()).unwrap(),
        config_before
    );
    // The default model is the person's own and can change: the project's agent keeps its own.
    let out = said(&run(&mut s, "/model mock/big").await);
    assert!(out.contains("mock/big"), "{out}");
    assert_eq!(s.model, "small");
    assert_eq!(w.read_config()["model"], "mock/big");
    s.close().await;
}

#[tokio::test]
async fn the_project_command_says_what_the_folder_adds() {
    let (_w, settings) = project("show");
    let mut s = open(&settings, Some("pip")).await;
    let out = said(&run(&mut s, "/project").await);
    for part in [
        "AGENTS.md",
        "release-notes",
        "reviewer",
        "ship",
        "imp.json",
        "waiting for trust",
    ] {
        assert!(out.contains(part), "{part} missing:\n{out}");
    }
    assert!(said(&run(&mut s, "/project nonsense").await).starts_with("! "));
    s.close().await;
}

#[tokio::test]
async fn the_folders_imps_can_be_messaged_and_talked_to() {
    let (w, settings) = project("imps");
    let mut s = open(&settings, Some("pip")).await;
    let targets = |s: &Session| {
        use imp_engine::ToolHost;
        s.toolbox
            .tools()
            .into_iter()
            .find(|t| t.spec.name == "imp_message")
            .map(|t| t.spec.parameters["properties"]["to"]["enum"].to_string())
            .unwrap_or_default()
    };
    assert!(targets(&s).contains("reviewer"), "{}", targets(&s));
    // Also after the servers were started again.
    run(&mut s, "/mcp list").await;
    s.reconnect_tools().await.unwrap();
    assert!(targets(&s).contains("reviewer"), "{}", targets(&s));
    // An Imp that only the folder has is listed and can be talked to.
    let out = said(&run(&mut s, "/imp").await);
    assert!(
        out.contains("reviewer") && out.contains("from this folder"),
        "{out}"
    );
    assert_eq!(
        run(&mut s, "/imp reviewer").await,
        Outcome::Switch("reviewer".into())
    );
    s.close().await;
    let reviewer = open(&settings, Some("reviewer")).await;
    assert_eq!(reviewer.model, "first", "it uses the default model");
    assert!(
        reviewer
            .system
            .contains("Reviews code and says what could break.")
    );
    // Every Imp gets an id in imp.json, the folder's too, so other devices know it by the same one.
    assert!(w.read_config()["imps"]["reviewer"]["id"].is_string());
    reviewer.close().await;
}

#[tokio::test]
async fn the_skill_tool_reads_the_whole_skill() {
    use imp_engine::ToolHost;
    let (_w, settings) = project("skill");
    let s = open(&settings, Some("pip")).await;
    let read = s
        .toolbox
        .call("use_skill", r#"{"name": "release-notes"}"#)
        .await
        .expect("the toolbox has use_skill");
    assert!(read.contains("1. Read the log."), "{read}");
    s.close().await;
}

#[tokio::test]
async fn skills_and_commands_of_the_folder_are_listed_and_shown() {
    let (_w, settings) = project("library");
    let mut s = open(&settings, Some("pip")).await;
    let out = said(&run(&mut s, "/skill").await);
    assert!(
        out.contains("release-notes") && out.contains("project"),
        "{out}"
    );
    let out = said(&run(&mut s, "/skill show release-notes").await);
    assert!(out.contains("1. Read the log."), "{out}");
    let out = said(&run(&mut s, "/command show ship").await);
    assert!(out.contains("Ship $ARGUMENTS."), "{out}");
    s.close().await;
}
