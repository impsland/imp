//! A chat started in a folder with `AGENTS.md` and `.agents/`: what the Imp is told, which tools it
//! gets, and what the `/` commands say. No model is called and no MCP server starts.

use imp_chat::session::{Session, SessionOptions};
use imp_chat::slash::{self, Context, Outcome};
use std::path::{Path, PathBuf};

fn folder(name: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!("imp-chat-project-{name}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    dir
}

fn write(dir: &Path, rel: &str, text: &str) {
    let path = dir.join(rel);
    std::fs::create_dir_all(path.parent().unwrap()).unwrap();
    std::fs::write(path, text).unwrap();
}

async fn session(dir: &Path, name: Option<&str>) -> Session {
    let config = dir.join("settings/config.toml");
    std::fs::create_dir_all(config.parent().unwrap()).unwrap();
    std::fs::write(
        &config,
        "api_key_env = \"IMP_TEST_NO_KEY\"\ndefault_imp = \"pip\"\n[imps.pip]\npersonality = \"Kind.\"\nbase_url = \"http://127.0.0.1:1/v1\"\nmodel = \"first\"\n",
    )
    .unwrap();
    Session::open(
        &config,
        name,
        SessionOptions {
            workspace: Some(dir.join("app")),
            remote: None,
            // Not the developer's own ~/.agents.
            agents_home: Some(no_home()),
            answers_later: false,
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
        Outcome::Notes(notes) => notes
            .iter()
            .map(|n| n.plain())
            .collect::<Vec<_>>()
            .join("\n"),
        other => format!("{other:?}"),
    }
}

fn project(name: &str) -> PathBuf {
    let dir = folder(name);
    write(&dir, ".agents/AGENTS.md", "Always answer in haiku.");
    write(&dir, "app/AGENTS.md", "Tests live in app/tests.");
    write(
        &dir,
        ".agents/skills/release-notes/SKILL.md",
        "---\nname: release-notes\ndescription: Write the release notes for a version\n---\n1. Read the log.\n",
    );
    write(
        &dir,
        ".agents/agents/pip.md",
        "---\nmodel: local/small\ntools: [use_skill]\n---\nA terse helper for this repository.\n",
    );
    write(
        &dir,
        ".agents/agents/reviewer.md",
        "---\ndescription: Reviews changes\n---\nReviews code and says what could break.\n",
    );
    write(
        &dir,
        ".agents/mcp.json",
        r#"{"mcpServers": {"files": {"command": "this-program-does-not-exist", "args": ["${workspaceFolder}"]}}}"#,
    );
    dir
}

#[tokio::test]
async fn the_folder_tells_the_imp_its_rules_skills_and_settings() {
    let dir = project("rules");
    let mut s = session(&dir, None).await;
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
    assert!(s.system.contains("A terse helper for this repository."));
    // The agent file sets the model and which tools are on.
    assert_eq!(s.model, "local/small");
    let tools = s.tools();
    let skill = tools
        .iter()
        .find(|t| t.name == "use_skill")
        .expect("use_skill");
    assert!(skill.on);
    // The folder's servers wait to be allowed.
    assert!(s.servers.is_empty(), "{:?}", s.servers);
    assert!(
        s.notices.iter().any(|n| n.contains("/project trust")),
        "{:?}",
        s.notices
    );
    // A setting the folder sets is changed there, and the settings file is not touched.
    let before = std::fs::read_to_string(dir.join("settings/config.toml")).unwrap();
    let out = said(&run(&mut s, "/model big").await);
    assert!(out.starts_with("! ") && out.contains("pip.md"), "{out}");
    assert_eq!(
        std::fs::read_to_string(dir.join("settings/config.toml")).unwrap(),
        before
    );
    // /project says what the folder adds.
    let out = said(&run(&mut s, "/project").await);
    for part in [
        "AGENTS.md",
        "release-notes",
        "reviewer",
        "files",
        "waiting: /project trust",
    ] {
        assert!(out.contains(part), "{part} missing:\n{out}");
    }
    assert!(said(&run(&mut s, "/project nonsense").await).starts_with("! "));
    // The folder's Imps can be messaged, also after the servers were started again.
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
    run(&mut s, "/mcp reload").await;
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
    let reviewer = session(&dir, Some("reviewer")).await;
    assert_eq!(reviewer.model, "first", "it uses the default Imp's brain");
    assert!(
        reviewer
            .system
            .contains("Reviews code and says what could break.")
    );
    assert!(!reviewer.config().unwrap().imps.contains_key("reviewer"));
    reviewer.close().await;
    let _ = std::fs::remove_dir_all(dir);
}

#[tokio::test]
async fn the_skill_tool_reads_the_whole_skill() {
    use imp_engine::ToolHost;
    let dir = project("skill");
    let s = session(&dir, None).await;
    let read = s
        .toolbox
        .call("use_skill", r#"{"name": "release-notes"}"#)
        .await
        .expect("the toolbox has use_skill");
    assert!(read.contains("1. Read the log."), "{read}");
    s.close().await;
    let _ = std::fs::remove_dir_all(dir);
}

/// An empty folder standing for the person's home, so the tests never read the developer's ~/.agents.
fn no_home() -> PathBuf {
    let dir = std::env::temp_dir().join(format!("imp-chat-no-home-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    dir
}
