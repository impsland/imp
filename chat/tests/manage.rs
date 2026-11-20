//! The command layer (`imp provider|auth|agent|model|mcp|permission|config|skill|command|project`) driven
//! through the real binary, with the files it writes read back: `imp.json`, `auth.json`, the agent files.

mod common;

use common::World;
use serde_json::json;

const KEY: &str = "sk-test-do-not-print-0123456789";

fn with_ollama(w: &World) {
    w.imp(&[
        "provider",
        "add",
        "ollama",
        "--url",
        "http://localhost:11434/v1",
    ]);
}

// Providers.

#[test]
fn a_provider_is_added_listed_changed_and_removed() {
    let w = World::new("provider");
    let added = w.imp(&[
        "provider",
        "add",
        "ollama",
        "--url",
        "http://localhost:11434/v1",
        "--name",
        "Ollama",
        "--header",
        "X-Gateway-Tenant=engineering",
        "--key-env",
        "OLLAMA_API_KEY",
    ]);
    assert!(added.out.contains("Added ollama"), "{}", added.out);
    assert_eq!(
        w.read_config()["providers"]["ollama"],
        json!({
            "name": "Ollama",
            "options": {
                "baseURL": "http://localhost:11434/v1",
                "apiKey": "{env:OLLAMA_API_KEY}",
                "headers": { "X-Gateway-Tenant": "engineering" }
            }
        })
    );
    // As a table: a header row, then one row per provider.
    let table = w.imp(&["provider", "list"]).out;
    let mut lines = table.lines();
    let head: Vec<&str> = lines.next().unwrap().split_whitespace().collect();
    assert_eq!(head, ["ID", "NAME", "URL", "KEY"]);
    let row: Vec<&str> = lines.next().unwrap().split_whitespace().collect();
    assert_eq!(
        row,
        [
            "ollama",
            "Ollama",
            "http://localhost:11434/v1",
            "env",
            "OLLAMA_API_KEY"
        ]
    );
    // As JSON: the shape other tools read.
    assert_eq!(
        w.imp(&["provider", "list", "--json"]).json(),
        json!([{
            "id": "ollama",
            "name": "Ollama",
            "url": "http://localhost:11434/v1",
            "key": "env OLLAMA_API_KEY",
            "headers": ["X-Gateway-Tenant"],
            "models": []
        }])
    );
    // Changes, one setting each; `-` takes a setting away.
    w.imp(&[
        "provider",
        "set",
        "ollama",
        "url",
        "https://ollama.example.com/v1",
    ]);
    w.imp(&["provider", "set", "ollama", "name", "-"]);
    w.imp(&["provider", "set", "ollama", "header.X-Gateway-Tenant", "-"]);
    w.imp(&["provider", "set", "ollama", "header.X-Other", "yes"]);
    w.imp(&["provider", "set", "ollama", "key-env", "-"]);
    assert_eq!(
        w.read_config()["providers"]["ollama"],
        json!({"options": {"baseURL": "https://ollama.example.com/v1", "headers": {"X-Other": "yes"}}})
    );
    assert_eq!(
        w.imp(&["provider", "list", "--json"]).json()[0]["key"],
        "none"
    );
    // Removing takes the saved key with it.
    w.imp_in(&["auth", "set", "ollama"], KEY);
    assert!(
        std::fs::read_to_string(w.auth_json())
            .unwrap()
            .contains(KEY)
    );
    let removed = w.imp(&["provider", "remove", "ollama", "--json"]).json();
    assert_eq!(removed["ok"], true);
    assert_eq!(removed["id"], "ollama");
    assert!(
        w.read_config()["providers"]
            .as_object()
            .is_none_or(|m| m.is_empty())
    );
    assert!(
        !std::fs::read_to_string(w.auth_json())
            .unwrap()
            .contains(KEY)
    );
    assert!(
        w.imp(&["provider", "list"])
            .out
            .contains("Nothing here yet.")
    );
}

#[test]
fn provider_mistakes_say_what_to_do() {
    let w = World::new("provider-bad");
    with_ollama(&w);
    let before = std::fs::read_to_string(w.imp_json()).unwrap();
    let dup = w.imp_fails(&["provider", "add", "ollama", "--url", "http://other/v1"]);
    assert!(
        dup.contains("There is already a provider ollama")
            && dup.contains("imp provider set ollama"),
        "{dup}"
    );
    let bad = w.imp_fails(&["provider", "add", "x", "--url", "localhost:11434"]);
    assert!(bad.contains("is not an address"), "{bad}");
    for id in ["a/b", "a#b", "a.b"] {
        let bad = w.imp_fails(&["provider", "add", id, "--url", "http://h/v1"]);
        assert!(
            bad.contains("is not a good name for a provider"),
            "{id}: {bad}"
        );
    }
    let bad = w.imp_fails(&[
        "provider",
        "add",
        "x",
        "--url",
        "http://h/v1",
        "--header",
        "novalue",
    ]);
    assert!(bad.contains("is not NAME=VALUE"), "{bad}");
    let bad = w.imp_fails(&[
        "provider",
        "add",
        "x",
        "--url",
        "http://h/v1",
        "--key-env",
        KEY,
    ]);
    assert!(!bad.contains(KEY), "a pasted key is not repeated: {bad}");
    assert!(bad.contains("imp auth set"), "{bad}");
    let bad = w.imp_fails(&["provider", "set", "nope", "name", "x"]);
    assert!(bad.contains("There is no provider nope"), "{bad}");
    let bad = w.imp_fails(&["provider", "set", "ollama", "colour", "x"]);
    assert!(bad.contains("is not a setting of a provider"), "{bad}");
    let bad = w.imp_fails(&["provider", "set", "ollama", "url", "-"]);
    assert!(bad.contains("needs its url"), "{bad}");
    let bad = w.imp_fails(&["provider", "remove", "nope"]);
    assert!(bad.contains("There is no provider nope"), "{bad}");
    // A provider needs its address.
    assert!(w.imp_fails(&["provider", "add", "x"]).contains("--url"));
    assert_eq!(std::fs::read_to_string(w.imp_json()).unwrap(), before);
}

// Keys.

#[test]
fn a_key_is_read_from_stdin_saved_privately_and_never_shown() {
    use std::os::unix::fs::PermissionsExt;
    let w = World::new("auth");
    with_ollama(&w);
    let set = w.imp_in(&["auth", "set", "ollama"], &format!("  {KEY}  \n"));
    assert!(set.ok, "{}", set.err);
    assert!(set.out.contains("Saved the key for ollama"), "{}", set.out);
    assert!(!set.out.contains(KEY) && !set.err.contains(KEY));
    let auth = std::fs::read_to_string(w.auth_json()).unwrap();
    assert!(auth.contains(KEY));
    assert_eq!(
        std::fs::metadata(w.auth_json())
            .unwrap()
            .permissions()
            .mode()
            & 0o777,
        0o600
    );
    assert!(!std::fs::read_to_string(w.imp_json()).unwrap().contains(KEY));
    // Everything that lists says only where the key is.
    for args in [
        &["auth", "list"][..],
        &["auth", "list", "--json"],
        &["provider", "list"],
        &["provider", "list", "--json"],
        &["config"],
        &["config", "get", "--json"],
        &["model"],
    ] {
        let run = w.imp(args);
        assert!(!run.out.contains(KEY) && !run.err.contains(KEY), "{args:?}");
    }
    assert_eq!(
        w.imp(&["auth", "list", "--json"]).json(),
        json!([{"kind": "provider", "name": "ollama", "key": "saved"}])
    );
    assert!(w.imp(&["auth", "list"]).out.contains("saved"));
    // A key in `imp.json` as `{env:...}` is where it comes from, even with a saved one.
    w.imp(&["provider", "set", "ollama", "key-env", "OLLAMA_API_KEY"]);
    assert_eq!(
        w.imp(&["auth", "list", "--json"]).json()[0]["key"],
        "env OLLAMA_API_KEY"
    );
    // Forgetting it.
    let cleared = w.imp(&["auth", "clear", "ollama"]);
    assert!(cleared.out.contains("Forgot the key of ollama"));
    assert!(
        !std::fs::read_to_string(w.auth_json())
            .unwrap()
            .contains(KEY)
    );
    let again = w.imp_fails(&["auth", "clear", "ollama"]);
    assert!(
        again.contains("There is no saved key for ollama"),
        "{again}"
    );
}

#[test]
fn a_key_that_cannot_be_saved_is_refused_without_a_trace() {
    let w = World::new("auth-bad");
    with_ollama(&w);
    let none = w.imp_in(&["auth", "set", "nope"], KEY);
    assert!(!none.ok);
    assert!(
        none.err.contains("There is no provider nope"),
        "{}",
        none.err
    );
    assert!(!none.err.contains(KEY) && !none.out.contains(KEY));
    let empty = w.imp_in(&["auth", "set", "ollama"], "\n");
    assert!(!empty.ok);
    assert!(empty.err.contains("The key is empty"), "{}", empty.err);
    assert!(!w.auth_json().exists());
}

// Agents.

#[test]
fn an_agent_is_made_shown_changed_renamed_and_removed() {
    let w = World::new("agent");
    with_ollama(&w);
    let made = w.imp(&[
        "agent",
        "new",
        "Pip",
        "--model",
        "ollama/qwen3#high",
        "--description",
        "A helper",
        "--color",
        "#e0533d",
    ]);
    assert!(made.out.contains("Made Pip"), "{}", made.out);
    // The file is the agent; imp.json holds what the file has no field for, starting with the id.
    let file = std::fs::read_to_string(w.agent_file("Pip")).unwrap();
    for part in [
        "model: ollama/qwen3#high",
        "description: A helper",
        "mode: primary",
        "#e0533d",
    ] {
        assert!(file.contains(part), "{part} missing:\n{file}");
    }
    let id = w.read_config()["imps"]["Pip"]["id"].clone();
    assert!(id.is_string());
    // List and show, as a table and as JSON.
    let list = w.imp(&["agent", "list"]).out;
    assert!(list.starts_with("NAME"), "{list}");
    assert!(
        list.contains("Pip") && list.contains("ollama/qwen3#high") && list.contains("A helper")
    );
    let listed = w.imp(&["agent", "list", "--json"]).json();
    let pip = &listed[0];
    assert_eq!(pip["name"], "Pip");
    assert_eq!(pip["mode"], "primary");
    assert_eq!(pip["model"], "ollama/qwen3#high");
    assert_eq!(pip["color"], "#e0533d");
    assert_eq!(pip["hidden"], false);
    assert_eq!(pip["scope"], "global");
    assert!(pip["path"].as_str().unwrap().ends_with("agents/Pip.md"));
    // A name is found in any case.
    let shown = w.imp(&["agent", "show", "pip", "--json"]).json();
    assert_eq!(shown["name"], "Pip");
    assert_eq!(shown["id"], id);
    assert_eq!(shown["permissions"], json!([]));
    assert!(
        w.imp(&["agent", "show", "Pip"])
            .out
            .contains("ollama/qwen3#high")
    );
    // Settings, one at a time; `-` clears.
    w.imp(&["agent", "set", "Pip", "description", "-"]);
    w.imp(&["agent", "set", "Pip", "steps", "40"]);
    w.imp(&["agent", "set", "Pip", "mode", "all"]);
    w.imp(&["agent", "set", "Pip", "prompt", "Count things."]);
    w.imp(&["agent", "set", "Pip", "hidden", "yes"]);
    let shown = w.imp(&["agent", "show", "Pip", "--json"]).json();
    assert_eq!(shown["description"], json!(null));
    assert_eq!(shown["steps"], 40);
    assert_eq!(shown["mode"], "all");
    assert_eq!(shown["prompt"], "Count things.");
    assert_eq!(shown["hidden"], true);
    // Hidden agents are left out of the list unless asked for.
    assert_eq!(w.imp(&["agent", "list", "--json"]).json(), json!([]));
    assert_eq!(
        w.imp(&["agent", "list", "--all", "--json"])
            .json()
            .as_array()
            .unwrap()
            .len(),
        1
    );
    w.imp(&["agent", "set", "Pip", "hidden", "-"]);
    // Rename: the file moves with its settings, and the Imp keeps its id.
    let renamed = w.imp(&["agent", "rename", "Pip", "Pop"]);
    assert!(
        renamed.out.contains("Pip is now called Pop"),
        "{}",
        renamed.out
    );
    assert!(!w.agent_file("Pip").exists() && w.agent_file("Pop").exists());
    let config = w.read_config();
    assert!(config["imps"].get("Pip").is_none());
    assert_eq!(config["imps"]["Pop"]["id"], id);
    // Remove: the file and its settings go.
    w.imp(&["agent", "remove", "Pop"]);
    assert!(!w.agent_file("Pop").exists());
    assert!(
        w.read_config()["imps"]
            .as_object()
            .is_none_or(|m| m.is_empty())
    );
    assert!(w.imp(&["agent", "list"]).out.contains("Nothing here yet."));
}

#[test]
fn agent_mistakes_say_what_is_wrong() {
    let w = World::new("agent-bad");
    with_ollama(&w);
    w.imp(&["agent", "new", "Pip", "--model", "ollama/qwen3"]);
    let file = std::fs::read_to_string(w.agent_file("Pip")).unwrap();
    let unknown = [
        &["agent", "show", "Nobody"][..],
        &["agent", "set", "Nobody", "steps", "3"],
        &["agent", "remove", "Nobody"],
        &["agent", "rename", "Nobody", "Other"],
        &["model", "ollama/x", "--agent", "Nobody"],
        &["mcp", "list", "--agent", "Nobody"],
        &["permission", "list", "--agent", "Nobody"],
        &[
            "permission",
            "add",
            "shell",
            "ls",
            "allow",
            "--agent",
            "Nobody",
        ],
    ];
    for args in unknown {
        let err = w.imp_fails(args);
        assert!(
            err.contains("There is no agent called Nobody"),
            "{args:?}: {err}"
        );
    }
    let err = w.imp_fails(&["agent", "new", "pip"]);
    assert!(
        err.contains("There is already an agent called pip"),
        "{err}"
    );
    for name in ["a b", "x/y", "", &"n".repeat(33)] {
        let err = w.imp_fails(&["agent", "new", name]);
        assert!(
            err.contains("is not a name for an agent"),
            "{name:?}: {err}"
        );
    }
    let err = w.imp_fails(&["agent", "new", "Bo", "--model", "qwen3"]);
    assert!(
        err.contains("provider/model"),
        "a bad model reference: {err}"
    );
    let err = w.imp_fails(&["agent", "new", "Bo", "--color", "red"]);
    assert!(err.contains("#rrggbb"), "{err}");
    let err = w.imp_fails(&["agent", "new", "Bo", "--mode", "boss"]);
    assert!(err.contains("is not a mode"), "{err}");
    let err = w.imp_fails(&["agent", "set", "Pip", "steps", "0"]);
    assert!(err.contains("not a number of steps"), "{err}");
    let err = w.imp_fails(&["agent", "set", "Pip", "hidden", "maybe"]);
    assert!(err.contains("not true or false"), "{err}");
    let err = w.imp_fails(&["agent", "set", "Pip", "colour", "x"]);
    assert!(err.contains("is not a setting of an agent"), "{err}");
    let err = w.imp_fails(&["agent", "set", "Pip", "model", "nothing"]);
    assert!(err.contains("provider/model"), "{err}");
    w.imp(&["agent", "new", "Bo"]);
    let err = w.imp_fails(&["agent", "rename", "Pip", "Bo"]);
    assert!(err.contains("already"), "{err}");
    let err = w.imp_fails(&["agent", "rename", "Pip", "a b"]);
    assert!(!err.is_empty());
    assert!(w.agent_file("Pip").exists() && !w.agent_file("a b").exists());
    // Nothing was changed by any of it.
    assert_eq!(std::fs::read_to_string(w.agent_file("Pip")).unwrap(), file);
}

// Models.

#[test]
fn the_default_model_and_an_agents_own_are_set() {
    let w = World::new("model");
    with_ollama(&w);
    w.imp(&["agent", "new", "Pip"]);
    // No model yet: the agent says why it is not ready.
    let shown = w.imp(&["model", "--json"]).json();
    assert_eq!(shown["default"], json!(null));
    assert_eq!(shown["agents"][0]["agent"], "Pip");
    assert!(shown["agents"][0]["status"].as_str().unwrap() != "ready");
    let set = w.imp(&["model", "ollama/qwen3#high"]);
    assert!(
        set.out.contains("The default model is ollama/qwen3#high"),
        "{}",
        set.out
    );
    assert_eq!(w.read_config()["model"], "ollama/qwen3#high");
    let shown = w.imp(&["model", "--json"]).json();
    assert_eq!(shown["default"], "ollama/qwen3#high");
    assert_eq!(shown["agents"][0]["model"], "ollama/qwen3#high");
    assert_eq!(shown["agents"][0]["status"], "ready");
    assert!(
        w.imp(&["model"])
            .out
            .starts_with("Default model: ollama/qwen3#high")
    );
    // An agent's own model is in its file, and `-` gives the default back.
    let own = w
        .imp(&["model", "ollama/llama4", "--agent", "Pip", "--json"])
        .json();
    assert_eq!(own["agent"], "Pip");
    assert_eq!(own["model"], "ollama/llama4");
    assert!(
        std::fs::read_to_string(w.agent_file("Pip"))
            .unwrap()
            .contains("model: ollama/llama4")
    );
    assert_eq!(w.read_config()["model"], "ollama/qwen3#high");
    assert_eq!(
        w.imp(&["model", "--agent", "Pip", "--json"]).json()["agents"][0]["model"],
        "ollama/llama4"
    );
    w.imp(&["model", "-", "--agent", "Pip"]);
    assert!(
        !std::fs::read_to_string(w.agent_file("Pip"))
            .unwrap()
            .contains("model:")
    );
}

#[test]
fn a_bad_model_is_refused_and_nothing_changes() {
    let w = World::new("model-bad");
    with_ollama(&w);
    w.imp(&["agent", "new", "Pip"]);
    for bad in ["qwen3", "ollama/", "/qwen3", "ollama/qwen3#"] {
        let err = w.imp_fails(&["model", bad]);
        assert!(!err.is_empty(), "{bad}");
    }
    let err = w.imp_fails(&["model", "qwen3"]);
    assert!(err.contains("provider/model"), "{err}");
    let err = w.imp_fails(&["model", "nowhere/qwen3"]);
    assert!(
        err.contains("There is no provider nowhere") && err.contains("imp provider add nowhere"),
        "{err}"
    );
    let err = w.imp_fails(&["model", "nowhere/qwen3", "--agent", "Pip"]);
    assert!(err.contains("There is no provider nowhere"), "{err}");
    assert!(w.read_config().get("model").is_none());
    assert!(
        !std::fs::read_to_string(w.agent_file("Pip"))
            .unwrap()
            .contains("model:")
    );
}

// MCP servers.

#[test]
fn mcp_servers_are_added_as_programs_or_addresses() {
    let w = World::new("mcp");
    w.imp(&[
        "mcp",
        "add",
        "files",
        "--command",
        "npx",
        "-y",
        "@modelcontextprotocol/server-filesystem",
        "/tmp",
    ]);
    w.imp(&[
        "mcp",
        "add",
        "web",
        "--url",
        "https://mcp.example.org/mcp",
        "--header",
        "Authorization=Bearer {env:SEARCH_KEY}",
    ]);
    w.imp(&[
        "mcp",
        "add",
        "tool",
        "--env",
        "A=b",
        "--command",
        "tool-server",
    ]);
    let config = w.read_config();
    assert_eq!(
        config["mcp"]["files"],
        json!({"type": "local", "command": ["npx", "-y", "@modelcontextprotocol/server-filesystem", "/tmp"]})
    );
    assert_eq!(
        config["mcp"]["web"],
        json!({"type": "remote", "url": "https://mcp.example.org/mcp", "headers": {"Authorization": "Bearer {env:SEARCH_KEY}"}})
    );
    assert_eq!(config["mcp"]["tool"]["environment"], json!({"A": "b"}));
    let listed = w.imp(&["mcp", "list", "--json"]).json();
    assert_eq!(
        listed[0],
        json!({"name": "files", "type": "local", "target": "npx -y @modelcontextprotocol/server-filesystem /tmp", "on": true, "signedIn": false})
    );
    assert_eq!(listed[2]["name"], "web");
    assert_eq!(listed[2]["type"], "remote");
    let table = w.imp(&["mcp", "list"]).out;
    assert_eq!(
        table
            .lines()
            .next()
            .unwrap()
            .split_whitespace()
            .collect::<Vec<_>>(),
        ["NAME", "TYPE", "TARGET", "STATE"]
    );
    // Settings of a server; each kind has its own.
    w.imp(&["mcp", "set", "files", "timeout", "5000"]);
    w.imp(&["mcp", "set", "files", "cwd", "/tmp"]);
    w.imp(&["mcp", "set", "files", "env.TOKEN", "x"]);
    w.imp(&["mcp", "set", "web", "url", "https://other.example.org/mcp"]);
    w.imp(&["mcp", "set", "web", "header.Authorization", "-"]);
    let config = w.read_config();
    assert_eq!(config["mcp"]["files"]["timeout"], 5000);
    assert_eq!(config["mcp"]["files"]["cwd"], "/tmp");
    assert_eq!(config["mcp"]["files"]["environment"], json!({"TOKEN": "x"}));
    assert_eq!(config["mcp"]["web"]["url"], "https://other.example.org/mcp");
    assert!(
        config["mcp"]["web"]
            .get("headers")
            .is_none_or(|h| h.as_object().unwrap().is_empty())
    );
    let err = w.imp_fails(&["mcp", "set", "web", "cwd", "/tmp"]);
    assert!(
        err.contains("is not a setting of this tool server"),
        "{err}"
    );
    let err = w.imp_fails(&["mcp", "set", "files", "timeout", "soon"]);
    assert!(err.contains("number of milliseconds"), "{err}");
    let err = w.imp_fails(&["mcp", "set", "nope", "cwd", "/"]);
    assert!(err.contains("There is no tool server nope"), "{err}");
    w.imp(&["mcp", "remove", "tool"]);
    assert!(w.read_config()["mcp"].get("tool").is_none());
    let err = w.imp_fails(&["mcp", "remove", "tool"]);
    assert!(err.contains("There is no tool server tool"), "{err}");
}

#[test]
fn mcp_mistakes_are_refused() {
    let w = World::new("mcp-bad");
    w.imp(&["mcp", "add", "files", "--command", "npx"]);
    let before = std::fs::read_to_string(w.imp_json()).unwrap();
    let err = w.imp_fails(&["mcp", "add", "files", "--command", "other"]);
    assert!(
        err.contains("There is already a tool server files"),
        "{err}"
    );
    let err = w.imp_fails(&["mcp", "add", "x"]);
    assert!(
        err.contains("--command PROGRAM ARGS or --url ADDRESS"),
        "{err}"
    );
    let err = w.imp_fails(&[
        "mcp",
        "add",
        "x",
        "--url",
        "https://h/mcp",
        "--command",
        "a",
    ]);
    assert!(err.contains("cannot be used with"), "{err}");
    let err = w.imp_fails(&["mcp", "add", "x", "--url", "ftp://h"]);
    assert!(err.contains("is not an address"), "{err}");
    let err = w.imp_fails(&["mcp", "add", "x", "--url", "https://h/mcp", "--env", "A=b"]);
    assert!(err.contains("--env is for a program"), "{err}");
    let err = w.imp_fails(&["mcp", "add", "x", "--header", "A=b", "--command", "a"]);
    assert!(
        err.contains("--header is for a server at an address"),
        "{err}"
    );
    // `--command` takes the rest of the line, so a flag after it belongs to the program.
    w.imp(&["mcp", "add", "rest", "--command", "prog", "--url", "x"]);
    assert_eq!(
        w.read_config()["mcp"]["rest"]["command"],
        json!(["prog", "--url", "x"])
    );
    w.imp(&["mcp", "remove", "rest"]);
    let err = w.imp_fails(&["mcp", "add", "a.b", "--command", "a"]);
    assert!(
        err.contains("is not a good name for a tool server"),
        "{err}"
    );
    let err = w.imp_fails(&["mcp", "enable", "nope"]);
    assert!(err.contains("There is no tool server nope"), "{err}");
    assert_eq!(std::fs::read_to_string(w.imp_json()).unwrap(), before);
}

#[test]
fn a_server_is_switched_off_for_everyone_or_for_one_agent_as_a_rule() {
    let w = World::new("mcp-enable");
    with_ollama(&w);
    w.imp(&["agent", "new", "Pip", "--model", "ollama/q"]);
    w.imp(&["agent", "new", "Bo", "--model", "ollama/q"]);
    w.imp(&["mcp", "add", "files", "--command", "npx"]);
    let state =
        |agent: &str| w.imp(&["mcp", "list", "--agent", agent, "--json"]).json()[0]["on"].clone();
    assert_eq!(state("Pip"), true);
    // Off for Pip: a `deny` rule on `mcp files/*` in Pip's file, and Bo keeps it.
    let off = w
        .imp(&["mcp", "disable", "files", "--agent", "Pip", "--json"])
        .json();
    assert_eq!(off["on"], false);
    assert_eq!(off["agent"], "Pip");
    assert_eq!(state("Pip"), false);
    assert_eq!(state("Bo"), true);
    let rules = w
        .imp(&["permission", "list", "--agent", "Pip", "--json"])
        .json();
    let own = rules
        .as_array()
        .unwrap()
        .iter()
        .find(|r| r["source"] == "agent")
        .unwrap();
    assert_eq!(own["action"], "mcp");
    assert_eq!(own["resource"], "files/*");
    assert_eq!(own["effect"], "deny");
    assert!(
        std::fs::read_to_string(w.agent_file("Pip"))
            .unwrap()
            .contains("files/*")
    );
    assert!(
        !std::fs::read_to_string(w.agent_file("Bo"))
            .unwrap()
            .contains("files/*")
    );
    // On again.
    w.imp(&["mcp", "enable", "files", "--agent", "Pip"]);
    assert_eq!(state("Pip"), true);
    // Off for everyone: the server's own switch.
    w.imp(&["mcp", "disable", "files"]);
    assert_eq!(w.read_config()["mcp"]["files"]["disabled"], true);
    assert_eq!(state("Bo"), false);
    assert_eq!(w.imp(&["mcp", "list", "--json"]).json()[0]["on"], false);
    assert!(w.imp(&["mcp", "list"]).out.contains("off"));
    w.imp(&["mcp", "enable", "files"]);
    assert_eq!(state("Bo"), true);
    assert_eq!(w.imp(&["mcp", "list"]).out.matches(" on").count(), 1);
}

// Permissions.

#[test]
fn permission_rules_are_added_listed_and_removed_for_everyone_or_one_agent() {
    let w = World::new("permission");
    with_ollama(&w);
    w.imp(&["agent", "new", "Pip", "--model", "ollama/q"]);
    w.imp(&["permission", "add", "shell", "rm -rf *", "deny"]);
    w.imp(&["permission", "add", "read", "~/secrets/*", "ask"]);
    w.imp(&[
        "permission",
        "add",
        "triggers",
        "*",
        "deny",
        "--agent",
        "Pip",
    ]);
    assert_eq!(
        w.read_config()["permissions"],
        json!([
            {"action": "shell", "resource": "rm -rf *", "effect": "deny"},
            {"action": "read", "resource": "~/secrets/*", "effect": "ask"}
        ])
    );
    assert!(
        std::fs::read_to_string(w.agent_file("Pip"))
            .unwrap()
            .contains("triggers")
    );
    // Everyone's list: the built-in defaults (no number), then imp.json's, numbered from 1.
    let all = w.imp(&["permission", "list", "--json"]).json();
    let all = all.as_array().unwrap();
    let defaults = all.iter().filter(|r| r["source"] == "default").count();
    assert!(defaults > 0);
    assert!(all[..defaults].iter().all(|r| r["index"].is_null()));
    assert_eq!(
        all[defaults],
        json!({"index": 1, "action": "shell", "resource": "rm -rf *", "effect": "deny", "source": "imp.json"})
    );
    assert_eq!(all[defaults + 1]["index"], 2);
    assert_eq!(all.len(), defaults + 2);
    let table = w.imp(&["permission", "list"]).out;
    assert_eq!(
        table
            .lines()
            .next()
            .unwrap()
            .split_whitespace()
            .collect::<Vec<_>>(),
        ["#", "ACTION", "RESOURCE", "EFFECT", "FROM"]
    );
    // An agent's list ends with its own rules, numbered for `remove --agent`.
    let pip = w
        .imp(&["permission", "list", "--agent", "Pip", "--json"])
        .json();
    let last = pip.as_array().unwrap().last().unwrap().clone();
    assert_eq!(
        last,
        json!({"index": 1, "action": "triggers", "resource": "*", "effect": "deny", "source": "agent"})
    );
    assert_eq!(pip.as_array().unwrap().len(), defaults + 3);
    // Removing is by number; the rest keep their order.
    let removed = w.imp(&["permission", "remove", "1"]);
    assert!(
        removed.out.contains("Removed: deny shell rm -rf *"),
        "{}",
        removed.out
    );
    assert_eq!(w.read_config()["permissions"][0]["action"], "read");
    w.imp(&["permission", "remove", "1", "--agent", "Pip"]);
    assert!(
        !std::fs::read_to_string(w.agent_file("Pip"))
            .unwrap()
            .contains("triggers")
    );
}

#[test]
fn permission_mistakes_are_refused() {
    let w = World::new("permission-bad");
    with_ollama(&w);
    w.imp(&["agent", "new", "Pip", "--model", "ollama/q"]);
    let err = w.imp_fails(&["permission", "add", "dance", "*", "allow"]);
    assert!(
        err.contains("is not something rules cover") && err.contains("shell"),
        "{err}"
    );
    let err = w.imp_fails(&["permission", "add", "shell", "ls", "maybe"]);
    assert!(err.contains("is not allow, ask or deny"), "{err}");
    for index in ["0", "1", "9"] {
        let err = w.imp_fails(&["permission", "remove", index]);
        assert!(err.contains(&format!("There is no rule {index}")), "{err}");
        let err = w.imp_fails(&["permission", "remove", index, "--agent", "Pip"]);
        assert!(err.contains(&format!("There is no rule {index}")), "{err}");
    }
    assert!(
        w.imp_fails(&["permission", "remove", "x"])
            .contains("invalid value")
    );
    assert!(
        w.read_config()
            .get("permissions")
            .is_none_or(|p| p.as_array().unwrap().is_empty())
    );
}

// Settings by key.

#[test]
fn a_setting_is_read_and_written_by_its_dotted_key() {
    let w = World::new("config");
    let path = w.imp(&["config", "path", "--json"]).json();
    assert_eq!(path["config"], w.imp_json().display().to_string());
    assert_eq!(path["auth"], w.auth_json().display().to_string());
    assert_eq!(
        w.imp(&["config", "path"]).out.trim(),
        w.imp_json().display().to_string()
    );
    // A number stays a number, text stays text.
    w.imp(&["config", "set", "requests.retries", "5"]);
    w.imp(&["config", "set", "model", "ollama/qwen3"]);
    let config = w.read_config();
    assert_eq!(config["requests"]["retries"], 5);
    assert_eq!(config["model"], "ollama/qwen3");
    assert_eq!(
        w.imp(&["config", "get", "requests.retries"]).out.trim(),
        "5"
    );
    assert_eq!(
        w.imp(&["config", "get", "model"]).out.trim(),
        "ollama/qwen3"
    );
    assert_eq!(
        w.imp(&["config", "get", "requests.retries", "--json"])
            .json(),
        json!({"key": "requests.retries", "value": 5})
    );
    assert_eq!(
        w.imp(&["config", "get", "requests", "--json"]).json()["value"],
        json!({"retries": 5})
    );
    // Without a key, everything (also what `imp config` alone shows).
    let all = w.imp(&["config", "get", "--json"]).json();
    assert_eq!(all["key"], json!(null));
    assert_eq!(all["value"]["model"], "ollama/qwen3");
    assert!(w.imp(&["config"]).out.contains("ollama/qwen3"));
    // A dot in a name is escaped.
    w.imp(&[
        "config",
        "set",
        r"providers.my\.host.options.baseURL",
        "http://h/v1",
    ]);
    assert_eq!(
        w.read_config()["providers"]["my.host"]["options"]["baseURL"],
        "http://h/v1"
    );
    assert_eq!(
        w.imp(&["config", "get", r"providers.my\.host.options.baseURL"])
            .out
            .trim(),
        "http://h/v1"
    );
    w.imp(&["config", "unset", "requests.retries"]);
    assert!(
        w.imp_fails(&["config", "get", "requests.retries"])
            .contains("is not set")
    );
}

#[test]
fn config_mistakes_are_refused_and_the_file_is_kept() {
    let w = World::new("config-bad");
    w.imp(&["config", "set", "requests.retries", "5"]);
    let before = std::fs::read_to_string(w.imp_json()).unwrap();
    let err = w.imp_fails(&["config", "get", "nothing.here"]);
    assert!(err.contains("nothing.here is not set"), "{err}");
    for key in ["a..b", ".a", "a."] {
        let err = w.imp_fails(&["config", "set", key, "1"]);
        assert!(err.contains("is not a key"), "{key}: {err}");
    }
    // Something that does not fit what `imp.json` holds is refused, whole.
    let err = w.imp_fails(&["config", "set", "requests.retries", "\"many\""]);
    assert!(err.contains("does not fit"), "{err}");
    let err = w.imp_fails(&["config", "set", "model.deeper", "1"]);
    assert!(!err.is_empty());
    let err = w.imp_fails(&["config", "unset", "nothing"]);
    assert!(err.contains("nothing is not set"), "{err}");
    assert_eq!(std::fs::read_to_string(w.imp_json()).unwrap(), before);
    w.imp(&["config", "unset", "requests.retries"]);
    assert!(
        w.imp_fails(&["config", "get", "requests.retries"])
            .contains("is not set")
    );
}

// Skills, commands and projects.

#[test]
fn skills_and_commands_are_listed_and_shown() {
    let w = World::new("library");
    w.home_agents(
        "skills/review/SKILL.md",
        "---\nname: review\ndescription: Review a change\n---\n1. Read the diff.\n",
    );
    w.home_agents(
        "commands/ship.md",
        "---\ndescription: Ship it\nagent: Pip\n---\nShip $ARGUMENTS.\n",
    );
    w.in_work(
        ".agents/skills/notes/SKILL.md",
        "---\nname: notes\ndescription: Keep notes\n---\nWrite it down.\n",
    );
    let skills = w.imp(&["skill", "list", "--json"]).json();
    let skills = skills.as_array().unwrap();
    assert_eq!(skills.len(), 2);
    let review = skills.iter().find(|s| s["name"] == "review").unwrap();
    assert_eq!(review["description"], "Review a change");
    assert_eq!(review["scope"], "global");
    let notes = skills.iter().find(|s| s["name"] == "notes").unwrap();
    assert_eq!(notes["scope"], "project");
    let table = w.imp(&["skill", "list"]).out;
    assert!(
        table.starts_with("NAME") && table.contains("Keep notes"),
        "{table}"
    );
    let shown = w.imp(&["skill", "show", "review", "--json"]).json();
    assert_eq!(shown["body"].as_str().unwrap().trim(), "1. Read the diff.");
    assert!(
        w.imp(&["skill", "show", "review"])
            .out
            .contains("1. Read the diff.")
    );
    let err = w.imp_fails(&["skill", "show", "nope"]);
    assert!(err.contains("There is no skill nope"), "{err}");
    let commands = w.imp(&["command", "list", "--json"]).json();
    assert_eq!(commands[0]["name"], "ship");
    assert_eq!(commands[0]["description"], "Ship it");
    assert!(w.imp(&["command", "list"]).out.contains("/ship"));
    for name in ["ship", "/ship"] {
        let shown = w.imp(&["command", "show", name, "--json"]).json();
        assert_eq!(shown["agent"], "Pip");
        assert_eq!(
            shown["template"].as_str().unwrap().trim(),
            "Ship $ARGUMENTS."
        );
    }
    let err = w.imp_fails(&["command", "show", "nope"]);
    assert!(err.contains("There is no command nope"), "{err}");
}

#[test]
fn a_folders_settings_wait_for_trust_and_trust_is_given_and_taken_back() {
    let w = World::new("project");
    // Without settings in the folder there is nothing to trust.
    let shown = w.imp(&["project", "--json"]).json();
    assert_eq!(shown["hasSettings"], false);
    assert!(w.imp(&["project"]).out.contains("nothing to trust"));
    let err = w.imp_fails(&["project", "trust"]);
    assert!(err.contains("no .agents/imp.json to trust"), "{err}");
    w.in_work(
        ".agents/imp.json",
        r#"{"providers":{"folder":{"options":{"baseURL":"http://127.0.0.1:1/v1"}}}}"#,
    );
    w.in_work(".agents/AGENTS.md", "Be brief.");
    w.imp(&["agent", "new", "Pip"]);
    let shown = w.imp(&["project", "show", "--json"]).json();
    assert_eq!(shown["hasSettings"], true);
    assert_eq!(shown["trusted"], false);
    assert!(w.imp(&["project"]).out.contains("waiting for trust"));
    // The folder's service is not known until it is trusted: no model can use it.
    let err = w.imp_fails(&["model", "folder/x", "--agent", "Pip"]);
    assert!(err.contains("There is no provider folder"), "{err}");
    let trusted = w.imp(&["project", "trust", "--json"]).json();
    assert_eq!(trusted["trusted"], true);
    assert_eq!(w.imp(&["project", "--json"]).json()["trusted"], true);
    assert!(w.imp(&["project"]).out.contains("trusted"));
    w.imp(&["model", "folder/x", "--agent", "Pip"]);
    // The folder's service is the folder's: the person's own file has none.
    assert!(
        w.read_config()
            .get("providers")
            .is_none_or(|p| p.as_object().unwrap().is_empty())
    );
    // A change to the file asks again.
    w.in_work(
        ".agents/imp.json",
        r#"{"providers":{"folder":{"options":{"baseURL":"http://elsewhere.example/v1"}}}}"#,
    );
    assert_eq!(w.imp(&["project", "--json"]).json()["trusted"], false);
    // Taking trust back.
    w.imp(&["project", "trust"]);
    assert_eq!(w.imp(&["project", "--json"]).json()["trusted"], true);
    let untrusted = w.imp(&["project", "untrust"]);
    assert!(
        untrusted.out.contains("No longer using"),
        "{}",
        untrusted.out
    );
    assert_eq!(w.imp(&["project", "--json"]).json()["trusted"], false);
    // Notes and the rest of the folder are read at once, trusted or not.
    assert_eq!(
        w.imp(&["project", "--json"]).json()["notes"]
            .as_array()
            .unwrap()
            .len(),
        1
    );
}
