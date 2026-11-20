//! Runs the real `imp` binary. Settings live in a temporary folder and no real service is called.

use std::io::Write;
use std::path::{Path, PathBuf};
use std::process::{Command, Output, Stdio};

const SECRET: &str = "sk-test-do-not-print-0123456789";

/// A settings folder and a home folder of their own, so no test touches another's agents or the developer's.
fn temp_config(tag: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!("imp-chat-bin-{}-{tag}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(dir.join("home")).unwrap();
    dir
}

fn imp(root: &Path, args: &[&str], stdin: &str) -> Output {
    let mut child = Command::new(env!("CARGO_BIN_EXE_imp"))
        .env("HOME", root.join("home"))
        .env("IMP_CONFIG_HOME", root.join("cfg"))
        .env("IMP_API_KEY", SECRET)
        .args(args)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    child
        .stdin
        .take()
        .unwrap()
        .write_all(stdin.as_bytes())
        .unwrap();
    child.wait_with_output().unwrap()
}

fn text(bytes: &[u8]) -> String {
    String::from_utf8_lossy(bytes).to_string()
}

#[test]
fn help_is_friendly() {
    let out = Command::new(env!("CARGO_BIN_EXE_imp"))
        // A home of its own: the program never touches the developer's settings or moves their files.
        .env("HOME", test_home())
        .arg("--help")
        .output()
        .unwrap();
    assert!(out.status.success());
    let help = text(&out.stdout);
    assert!(help.contains("Talk to your Imps from a terminal"), "{help}");
    for word in ["agent", "provider", "permission", "chat", "Getting started"] {
        assert!(help.contains(word), "{word} missing in {help}");
    }
    assert!(!help.contains(';'));
}

#[test]
fn no_arguments_starts_chat_like_imp_chat() {
    // A home of its own: the program never touches the developer's settings or moves their files.
    let run = |args: &[&str]| {
        Command::new(env!("CARGO_BIN_EXE_imp"))
            .args(args)
            .env("HOME", test_home())
            .output()
            .unwrap()
    };
    let bare = run(&[]);
    let chat = run(&["chat"]);
    assert_eq!(bare.status.code(), chat.status.code());
    assert_eq!(text(&bare.stderr), text(&chat.stderr));
    assert!(!text(&bare.stderr).contains("Usage"));
}

#[test]
fn making_listing_and_removing_agents() {
    let root = temp_config("flow");
    let provider = imp(
        &root,
        &[
            "provider",
            "add",
            "ollama",
            "--url",
            "http://localhost:11434/v1",
        ],
        "",
    );
    assert!(provider.status.success(), "{}", text(&provider.stderr));
    let made = imp(
        &root,
        &[
            "agent",
            "new",
            "Pip",
            "--model",
            "ollama/tiny#high",
            "--description",
            "Brisk.",
        ],
        "",
    );
    assert!(made.status.success(), "{}", text(&made.stderr));
    let file = root.join("home/.agents/agents/Pip.md");
    let saved = std::fs::read_to_string(&file).unwrap();
    assert!(
        saved.contains("ollama/tiny#high") && saved.contains("Brisk."),
        "{saved}"
    );
    let list = text(&imp(&root, &["agent", "list"], "").stdout);
    assert!(
        list.contains("Pip") && list.contains("ollama/tiny#high"),
        "{list}"
    );
    let json = text(&imp(&root, &["agent", "list", "--json"], "").stdout);
    assert!(json.contains("\"Pip\""), "{json}");

    let duplicate = imp(&root, &["agent", "new", "Pip", "--model", "ollama/x"], "");
    assert!(!duplicate.status.success());
    assert!(text(&duplicate.stderr).contains("already an agent called Pip"));
    let bad = imp(
        &root,
        &[
            "agent", "new", "Zed", "--model", "ollama/x", "--mode", "bogus",
        ],
        "",
    );
    assert!(!bad.status.success());

    let set = imp(&root, &["config", "set", "default_agent", "Pip"], "");
    assert!(set.status.success(), "{}", text(&set.stderr));
    assert!(text(&imp(&root, &["config", "get", "default_agent"], "").stdout).contains("Pip"));

    assert!(imp(&root, &["agent", "remove", "Pip"], "").status.success());
    assert!(!file.exists());
    assert!(!text(&imp(&root, &["agent", "list"], "").stdout).contains("Pip"));
}

#[test]
fn keys_are_never_printed_or_written_in_the_settings() {
    let root = temp_config("keys");
    let made = imp(
        &root,
        &[
            "provider",
            "add",
            "ollama",
            "--url",
            "http://localhost:11434/v1",
            "--key-env",
            "IMP_API_KEY",
        ],
        "",
    );
    assert!(made.status.success(), "{}", text(&made.stderr));
    let shown = imp(&root, &["auth", "list"], "");
    assert!(shown.status.success());
    let (out, err) = (text(&shown.stdout), text(&shown.stderr));
    assert!(out.contains("env IMP_API_KEY"), "{out}");
    assert!(!out.contains(SECRET) && !err.contains(SECRET));
    let settings = root.join("cfg/imp.json");
    assert!(!std::fs::read_to_string(&settings).unwrap().contains(SECRET));

    // A key pasted where a variable name belongs is refused without being echoed.
    let bad = imp(&root, &["provider", "set", "ollama", "key-env", SECRET], "");
    assert!(!bad.status.success());
    assert!(!text(&bad.stdout).contains(SECRET) && !text(&bad.stderr).contains(SECRET));
    let bad = imp(
        &root,
        &[
            "provider",
            "add",
            "x",
            "--url",
            "http://x/v1",
            "--key-env",
            SECRET,
        ],
        "",
    );
    assert!(!bad.status.success());
    assert!(!text(&bad.stderr).contains(SECRET));
    assert!(!std::fs::read_to_string(&settings).unwrap().contains(SECRET));

    // A key read from standard input goes to auth.json alone, and is never shown again.
    let saved = imp(&root, &["auth", "set", "ollama"], "sk-typed-key-9876\n");
    assert!(saved.status.success(), "{}", text(&saved.stderr));
    assert!(!text(&saved.stdout).contains("sk-typed-key-9876"));
    assert!(
        !std::fs::read_to_string(&settings)
            .unwrap()
            .contains("sk-typed-key-9876")
    );
    let auth = std::fs::read_to_string(root.join("cfg/auth.json")).unwrap();
    assert!(auth.contains("sk-typed-key-9876"));
    let list = text(&imp(&root, &["auth", "list"], "").stdout);
    assert!(!list.contains("sk-typed-key-9876"), "{list}");
}

#[test]
fn chatting_without_an_imp_explains_what_to_do() {
    let root = temp_config("empty");
    let out = imp(&root, &["chat"], "hi\n");
    assert!(!out.status.success());
    assert!(text(&out.stderr).contains("imp agent new"));
}

#[test]
fn serve_help_explains_the_hop_and_a_den_flag_is_refused() {
    let out = Command::new(env!("CARGO_BIN_EXE_imp"))
        // A home of its own: the program never touches the developer's settings or moves their files.
        .env("HOME", test_home())
        .args(["serve", "--help"])
        .output()
        .unwrap();
    assert!(out.status.success());
    let help = text(&out.stdout);
    for word in ["--hop-port", "--host", "keeps nothing"] {
        assert!(help.contains(word), "{word} missing in {help}");
    }
    let out = Command::new(env!("CARGO_BIN_EXE_imp"))
        // A home of its own: the program never touches the developer's settings or moves their files.
        .env("HOME", test_home())
        .args(["serve", "--den-port", "9000"])
        .env_remove("IMP_DATA_DIR")
        .output()
        .unwrap();
    assert!(!out.status.success());
    assert!(text(&out.stderr).contains("unexpected argument"));
}

/// An empty home folder for the program under test.
fn test_home() -> PathBuf {
    let dir = std::env::temp_dir().join(format!("imp-chat-bin-home-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    dir
}
