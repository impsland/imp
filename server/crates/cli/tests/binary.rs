//! Runs the real `imp` binary. Settings live in a temporary folder and no real service is called.

use std::io::Write;
use std::path::PathBuf;
use std::process::{Command, Output, Stdio};

const SECRET: &str = "sk-test-do-not-print-0123456789";

fn temp_config(tag: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!("imp-cli-bin-{}-{tag}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    dir.join("config.toml")
}

fn imp(config: &PathBuf, args: &[&str], stdin: &str) -> Output {
    let mut child = Command::new(env!("CARGO_BIN_EXE_imp"))
        .arg("--config")
        .arg(config)
        .args(args)
        .env("IMP_API_KEY", SECRET)
        .env_remove("IMP_CONFIG")
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
        .arg("--help")
        .output()
        .unwrap();
    assert!(out.status.success());
    let help = text(&out.stdout);
    assert!(help.contains("Talk to your Imps from a terminal"), "{help}");
    for word in ["config", "imp", "chat", "Getting started"] {
        assert!(help.contains(word), "{word} missing in {help}");
    }
    assert!(!help.contains(';'));
}

#[test]
fn no_arguments_shows_help() {
    let out = Command::new(env!("CARGO_BIN_EXE_imp")).output().unwrap();
    assert!(!out.status.success());
    assert!(text(&out.stderr).contains("Usage"));
}

#[test]
fn making_listing_and_removing_imps() {
    let config = temp_config("flow");
    let made = imp(
        &config,
        &[
            "imp",
            "new",
            "pip",
            "--model",
            "tiny",
            "--url",
            "http://localhost:11434/v1",
            "--personality",
            "Brisk.",
        ],
        "",
    );
    assert!(made.status.success(), "{}", text(&made.stderr));
    let list = text(&imp(&config, &["imp", "list"], "").stdout);
    assert!(list.contains("* pip"), "{list}");
    assert!(list.contains("tiny"));
    assert!(list.contains("http://localhost:11434/v1"));

    let duplicate = imp(&config, &["imp", "new", "pip", "--model", "x"], "");
    assert!(!duplicate.status.success());

    // Asked for what is missing.
    let asked = imp(
        &config,
        &["imp", "new", "zed"],
        "Calm.\nhttps://example.com/v1\nbig\n",
    );
    assert!(asked.status.success(), "{}", text(&asked.stderr));
    let saved = std::fs::read_to_string(&config).unwrap();
    assert!(
        saved.contains("Calm.")
            && saved.contains("https://example.com/v1")
            && saved.contains("big")
    );

    let set = imp(&config, &["config", "set", "default_imp", "zed"], "");
    assert!(set.status.success());
    assert!(text(&imp(&config, &["imp", "list"], "").stdout).contains("* zed"));

    assert!(imp(&config, &["imp", "remove", "zed"], "").status.success());
    assert!(!text(&imp(&config, &["imp", "list"], "").stdout).contains("zed"));
}

#[test]
fn keys_are_never_printed_or_written() {
    let config = temp_config("keys");
    let made = imp(&config, &["imp", "new", "pip", "--model", "m"], "");
    assert!(made.status.success());
    let shown = imp(&config, &["config"], "");
    assert!(shown.status.success());
    let (out, err) = (text(&shown.stdout), text(&shown.stderr));
    assert!(
        out.contains("found in the environment variable IMP_API_KEY"),
        "{out}"
    );
    assert!(!out.contains(SECRET) && !err.contains(SECRET));
    for output in [&made.stdout, &made.stderr] {
        assert!(!text(output).contains(SECRET));
    }
    assert!(!std::fs::read_to_string(&config).unwrap().contains(SECRET));

    // A key pasted where a variable name belongs is refused without being echoed.
    let bad = imp(&config, &["config", "set", "api_key_env", SECRET], "");
    assert!(!bad.status.success());
    assert!(!text(&bad.stdout).contains(SECRET) && !text(&bad.stderr).contains(SECRET));
    let bad = imp(
        &config,
        &["imp", "new", "x", "--model", "m", "--api-key-env", SECRET],
        "",
    );
    assert!(!bad.status.success());
    assert!(!text(&bad.stderr).contains(SECRET));
    assert!(!std::fs::read_to_string(&config).unwrap().contains(SECRET));
}

#[test]
fn chatting_without_an_imp_explains_what_to_do() {
    let config = temp_config("empty");
    let out = imp(&config, &["chat"], "hi\n");
    assert!(!out.status.success());
    assert!(text(&out.stderr).contains("imp imp new"));
}

#[test]
fn serve_help_explains_the_choices_and_a_wrong_mix_is_refused() {
    let out = Command::new(env!("CARGO_BIN_EXE_imp"))
        .args(["serve", "--help"])
        .output()
        .unwrap();
    assert!(out.status.success());
    let help = text(&out.stdout);
    for word in ["--den-only", "--hop-only", "does not need The Den"] {
        assert!(help.contains(word), "{word} missing in {help}");
    }
    let out = Command::new(env!("CARGO_BIN_EXE_imp"))
        .args(["serve", "--hop-only", "--den-port", "9000"])
        .env_remove("IMP_DATA_DIR")
        .output()
        .unwrap();
    assert!(!out.status.success());
    assert!(text(&out.stderr).contains("cannot be used with"));
}
