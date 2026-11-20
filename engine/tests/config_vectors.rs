//! Checks the shared configuration against the vectors in `spec/fixtures/config/`: `vectors.json`, the
//! sample `imp.json` and its canonical form, and a home folder with `~/.agents` and a project.

use imp_engine::config::{
    Agent, Command, Effect, Env, ImpConfig, ModelRef, Rule, Skill, TrustStore, decide,
    default_rules, effective_rules, glob_match, group_enabled, load, parse_config, set_group,
    substitute, to_json,
};
use serde_json::Value;
use std::path::{Path, PathBuf};

fn fixtures() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("../spec/fixtures/config")
}

fn vectors() -> Value {
    serde_json::from_str(&std::fs::read_to_string(fixtures().join("vectors.json")).unwrap())
        .unwrap()
}

fn rules(v: &Value) -> Vec<Rule> {
    serde_json::from_value(v.clone()).unwrap()
}

fn effect(text: &str) -> Effect {
    serde_json::from_value(Value::from(text)).unwrap()
}

#[test]
fn model_refs() {
    for case in vectors()["model_refs"].as_array().unwrap() {
        let text = case["text"].as_str().unwrap();
        match ModelRef::parse(text) {
            Ok(r) => {
                assert!(case.get("error").is_none(), "{text}");
                assert_eq!(Value::from(r.provider.as_str()), case["provider"], "{text}");
                assert_eq!(Value::from(r.model.as_str()), case["model"], "{text}");
                assert_eq!(serde_json::json!(r.variant), case["variant"], "{text}");
                assert_eq!(r.to_string(), text);
            }
            Err(_) => assert_eq!(case["error"], true, "{text}"),
        }
    }
}

#[test]
fn globs() {
    for case in vectors()["globs"].as_array().unwrap() {
        let (p, t) = (
            case["pattern"].as_str().unwrap(),
            case["text"].as_str().unwrap(),
        );
        assert_eq!(
            glob_match(p, t),
            case["matches"].as_bool().unwrap(),
            "{p:?} {t:?}"
        );
    }
}

#[test]
fn substitution() {
    let v = vectors();
    let env = &v["substitution"]["env"];
    let vars: Vec<(&str, &str)> = env
        .as_object()
        .unwrap()
        .iter()
        .map(|(k, v)| (k.as_str(), v.as_str().unwrap()))
        .collect();
    let env = Env::new(&vars, None);
    for case in v["substitution"]["cases"].as_array().unwrap() {
        let mut problems = Vec::new();
        let out = substitute(
            case["input"].as_str().unwrap(),
            Path::new("/"),
            &env,
            &mut problems,
        );
        assert_eq!(out, case["output"].as_str().unwrap(), "{case}");
        assert_eq!(
            problems.len() as u64,
            case["problems"].as_u64().unwrap(),
            "{case}"
        );
    }
}

#[test]
fn decisions_and_defaults() {
    let v = vectors();
    for case in v["decide"].as_array().unwrap() {
        let r = case.get("rules").map(rules).unwrap_or_default();
        let single = [case.clone()];
        let checks = case
            .get("checks")
            .and_then(Value::as_array)
            .map_or(&single[..], Vec::as_slice);
        for check in checks {
            let (a, res) = (
                check["action"].as_str().unwrap(),
                check["resource"].as_str().unwrap(),
            );
            assert_eq!(
                decide(&r, a, res),
                effect(check["effect"].as_str().unwrap()),
                "{} {a} {res}",
                case["name"]
            );
        }
    }
    assert_eq!(default_rules(), [Rule::new("computer", "*", Effect::Deny)]);
    for case in v["defaults"].as_array().unwrap() {
        let group = case["group"].as_str().unwrap();
        assert_eq!(
            group_enabled(&ImpConfig::default(), &Agent::default(), group),
            case["enabled"].as_bool().unwrap(),
            "{group}"
        );
    }
}

#[test]
fn set_group_vectors() {
    for case in vectors()["set_group"].as_array().unwrap() {
        let config = ImpConfig {
            permissions: rules(&case["config"]),
            ..ImpConfig::default()
        };
        let mut agent = Agent {
            permissions: rules(&case["before"]),
            ..Agent::default()
        };
        set_group(
            &config,
            &mut agent,
            case["group"].as_str().unwrap(),
            case["on"].as_bool().unwrap(),
        );
        assert_eq!(agent.permissions, rules(&case["after"]), "{}", case["name"]);
        let all = effective_rules(&config, &agent);
        let enabled = decide(&all, case["group"].as_str().unwrap(), "*") != Effect::Deny;
        assert_eq!(enabled, case["on"].as_bool().unwrap(), "{}", case["name"]);
    }
}

#[test]
fn the_sample_imp_json_has_one_canonical_form() {
    let dir = fixtures();
    let sample = std::fs::read_to_string(dir.join("home/.config/imp/imp.json")).unwrap();
    let canonical = std::fs::read_to_string(dir.join("imp.canonical.json")).unwrap();
    let (config, diags) = parse_config(&sample, None, None);
    assert!(diags.is_empty(), "{diags:?}");
    assert_eq!(to_json(&config), canonical);
    let (again, _) = parse_config(&canonical, None, None);
    assert_eq!(again, config);
    assert_eq!(to_json(&again), canonical);
}

#[test]
fn the_sample_markdown_files_round_trip() {
    let home = fixtures().join("home/.agents");
    for entry in std::fs::read_dir(home.join("agents")).unwrap() {
        let path = entry.unwrap().path();
        let name = path.file_stem().unwrap().to_string_lossy().to_string();
        let agent = Agent::parse(&name, &std::fs::read_to_string(&path).unwrap()).unwrap();
        assert_eq!(
            Agent::parse(&name, &agent.to_markdown()).unwrap(),
            agent,
            "{name}"
        );
    }
    let text = std::fs::read_to_string(home.join("skills/notes/SKILL.md")).unwrap();
    let skill = Skill::parse("notes", &text).unwrap();
    assert_eq!(Skill::parse("notes", &skill.to_markdown()).unwrap(), skill);
    let text = std::fs::read_to_string(home.join("commands/fix.md")).unwrap();
    let command = Command::parse("fix", &text).unwrap();
    assert_eq!(
        Command::parse("fix", &command.to_markdown()).unwrap(),
        command
    );
    assert_eq!(
        command.message("a.rs b"),
        "Fix a.rs in b. Everything: a.rs b"
    );
}

fn names<T>(map: &std::collections::BTreeMap<String, T>) -> Vec<&str> {
    map.keys().map(String::as_str).collect()
}

fn strings(v: &Value) -> Vec<&str> {
    v.as_array()
        .unwrap()
        .iter()
        .map(|s| s.as_str().unwrap())
        .collect()
}

#[test]
fn loading_the_sample_home() {
    let v = vectors();
    let want = &v["load"];
    let home = fixtures().join("home");
    let vars = [
        (
            "IMP_CONFIG_HOME",
            home.join(".config/imp").to_str().unwrap().to_string(),
        ),
        (
            "OLLAMA_API_KEY",
            want["env"]["OLLAMA_API_KEY"].as_str().unwrap().to_string(),
        ),
    ];
    let vars: Vec<(&str, &str)> = vars.iter().map(|(k, v)| (*k, v.as_str())).collect();
    let env = Env::new(&vars, Some(&home));
    let trust_dir = tempfile::tempdir().unwrap();
    let trust = TrustStore::at(trust_dir.path().join("trusted.json"));

    // The Mac app: ~/.agents only.
    let g = &want["global"];
    let mac = load(&env, None, &trust);
    assert_eq!(mac.diagnostics, [], "{:?}", mac.diagnostics);
    assert_eq!(mac.config.model.as_deref(), g["model"].as_str());
    assert_eq!(names(&mac.agents), strings(&g["agents"]));
    assert_eq!(
        mac.imps()
            .map(|a| a.value.name.as_str())
            .collect::<Vec<_>>(),
        strings(&g["imps"])
    );
    assert_eq!(names(&mac.skills), strings(&g["skills"]));
    assert_eq!(names(&mac.commands), strings(&g["commands"]));
    assert_eq!(
        mac.instructions
            .iter()
            .map(|i| i.text.as_str())
            .collect::<Vec<_>>(),
        strings(&g["instructions"])
    );
    assert_eq!(
        mac.config.providers["ollama"].options.api_key.as_deref(),
        g["ollama_key"].as_str()
    );
    assert_eq!(
        mac.auth.key_for("ollama", None).as_deref(),
        Some("sk-from-auth")
    );
    assert_eq!(
        mac.agents["review"].value.description.as_deref(),
        Some("Reviews changes (yours)")
    );

    // The terminal app in a project, before and after trusting it.
    let p = &want["project"];
    let start = home.join(p["start"].as_str().unwrap());
    let before = load(&env, Some(&start), &trust);
    let u = &p["untrusted"];
    assert_eq!(before.config.model.as_deref(), u["model"].as_str());
    assert_eq!(names(&before.config.mcp), strings(&u["mcp"]));
    assert_eq!(
        before.agents["review"].value.description.as_deref(),
        u["review"].as_str()
    );
    assert_eq!(
        before
            .instructions
            .iter()
            .map(|i| i.text.as_str())
            .collect::<Vec<_>>(),
        strings(&p["instructions"])
    );
    let project = before.project.unwrap();
    assert!(!project.trusted);
    trust.set(&project.root, project.digest.as_deref()).unwrap();
    let after = load(&env, Some(&start), &trust);
    let t = &p["trusted"];
    assert_eq!(after.config.model.as_deref(), t["model"].as_str());
    assert_eq!(names(&after.config.mcp), strings(&t["mcp"]));
    assert_eq!(
        after.config.permissions.len() as u64,
        t["permissions"].as_u64().unwrap()
    );
}

fn server_names(v: &Value) -> Vec<String> {
    v.as_array()
        .map(|a| {
            a.iter()
                .filter_map(|s| s.as_str().map(str::to_string))
                .collect()
        })
        .unwrap_or_default()
}

#[test]
fn tool_calls_are_classified() {
    for case in vectors()["gate"].as_array().unwrap() {
        let p = imp_engine::config::classify(
            case["tool_id"].as_str(),
            case["tool"].as_str().unwrap(),
            case["arguments"].as_str().unwrap_or(""),
            &server_names(&case["servers"]),
        );
        assert_eq!(
            (p.action.as_str(), p.resource.as_str()),
            (
                case["action"].as_str().unwrap(),
                case["resource"].as_str().unwrap()
            ),
            "{}",
            case["name"]
        );
    }
}

#[test]
fn tool_calls_are_decided_by_the_rules() {
    for case in vectors()["gate_decide"].as_array().unwrap() {
        let (got, _) = imp_engine::config::judge(
            &rules(&case["rules"]),
            case["home"].as_str(),
            case["tool_id"].as_str(),
            case["tool"].as_str().unwrap(),
            case["arguments"].as_str().unwrap_or(""),
            &server_names(&case["servers"]),
        );
        assert_eq!(
            got,
            effect(case["effect"].as_str().unwrap()),
            "{}",
            case["name"]
        );
    }
}
