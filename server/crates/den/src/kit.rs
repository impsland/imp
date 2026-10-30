//! Kit validation: the same limits and rules as Imp itself (`Kit.swift`) and the old registry
//! builder, applied to a kit before the Den keeps it.

use std::collections::HashSet;

use serde::{Deserialize, Serialize};
use serde_json::{Map, Value};
use sha2::{Digest, Sha256};

use crate::error::Violation;

pub const MAX_BYTES: usize = 512 * 1024;
const MAX_IMPS: usize = 20;
const MAX_TRIGGERS: usize = 50;
const MAX_SERVERS: usize = 20;
const MAX_ANIMATIONS: usize = 50;
const MAX_BEATS: usize = 24;
const MIN_BEAT: f64 = 0.05;
const MAX_BEAT: f64 = 6.0;
const MAX_TOTAL: f64 = 20.0;
const MAX_PROBLEMS: usize = 25;

const MOODS: [&str; 20] = [
    "idle",
    "listening",
    "thinking",
    "happy",
    "love",
    "sad",
    "error",
    "sleepy",
    "annoyed",
    "surprised",
    "dizzy",
    "mean",
    "working",
    "content",
    "giggly",
    "scared",
    "curious",
    "shy",
    "excited",
    "bored",
];
const GLYPHS: [&str; 7] = [
    "notes", "question", "exclaim", "idea", "sweat", "heart", "sparkles",
];
const MOVES: [&str; 10] = [
    "spin",
    "flip",
    "roll",
    "bounce",
    "shake",
    "sway",
    "wobble",
    "float",
    "nod",
    "headshake",
];
const TRAITS: [(&str, f64, f64); 8] = [
    ("lids", 0.0, 0.6),
    ("slant", -1.0, 1.0),
    ("eyes", -0.4, 0.4),
    ("squint", -1.0, 1.0),
    ("horns", -30.0, 30.0),
    ("blush", 0.0, 1.0),
    ("tilt", -12.0, 12.0),
    ("tempo", 0.6, 1.6),
];
const SECRET_HINTS: [&str; 7] = [
    "key",
    "token",
    "secret",
    "password",
    "auth",
    "sig",
    "credential",
];

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum Kind {
    Imp,
    Animation,
    Trigger,
    Tool,
    Kit,
}

impl Kind {
    pub fn as_str(self) -> &'static str {
        match self {
            Kind::Imp => "imp",
            Kind::Animation => "animation",
            Kind::Trigger => "trigger",
            Kind::Tool => "tool",
            Kind::Kit => "kit",
        }
    }

    pub fn parse(s: &str) -> Option<Self> {
        [
            Kind::Imp,
            Kind::Animation,
            Kind::Trigger,
            Kind::Tool,
            Kind::Kit,
        ]
        .into_iter()
        .find(|k| k.as_str() == s)
    }
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize)]
pub struct Counts {
    pub imps: usize,
    pub animations: usize,
    pub triggers: usize,
    pub tools: usize,
}

/// A kit that passed, ready to store.
#[derive(Debug)]
pub struct Checked {
    pub name: String,
    pub about: String,
    pub kind: Kind,
    pub runs_programs: bool,
    pub counts: Counts,
    /// The kit as kept: compact, without a `registry` block.
    pub text: String,
    pub sha256: String,
}

struct Problems(Vec<Violation>);

impl Problems {
    fn add(&mut self, pointer: &str, detail: impl Into<String>) {
        if self.0.len() < MAX_PROBLEMS {
            self.0.push(Violation {
                pointer: pointer.to_owned(),
                detail: detail.into(),
            });
        }
    }
}

fn is_number(v: &Value) -> Option<f64> {
    v.as_f64().filter(|n| n.is_finite())
}

fn pointer_part(s: &str) -> String {
    s.replace('~', "~0").replace('/', "~1")
}

pub fn check(mut kit: Value) -> Result<Checked, Vec<Violation>> {
    let mut problems = Problems(Vec::new());
    let Some(root) = kit.as_object_mut() else {
        return Err(vec![Violation {
            pointer: String::new(),
            detail: "a kit is a JSON object".to_owned(),
        }]);
    };
    root.remove("registry");

    match root.get("imp").and_then(Value::as_u64) {
        Some(1..=3) => {}
        _ => problems.add("/imp", "the format version must be 1, 2 or 3"),
    }
    let name = match root.get("name").and_then(Value::as_str).map(str::trim) {
        Some(n) if !n.is_empty() && n.chars().count() <= 80 => n.to_owned(),
        _ => {
            problems.add("/name", "a name of 1 to 80 characters is required");
            String::new()
        }
    };
    let about = match root.get("about") {
        None | Some(Value::Null) => String::new(),
        Some(Value::String(s)) if s.chars().count() <= 4000 => s.trim().to_owned(),
        Some(_) => {
            problems.add("/about", "must be text of at most 4000 characters");
            String::new()
        }
    };

    let servers = match root.get("mcpServers") {
        None | Some(Value::Null) => None,
        Some(Value::Object(map)) => Some(map),
        Some(_) => {
            problems.add("/mcpServers", "must be an object");
            None
        }
    };
    if let Some(servers) = servers {
        if servers.len() > MAX_SERVERS {
            problems.add(
                "/mcpServers",
                format!("{} tools, at most {MAX_SERVERS}", servers.len()),
            );
        }
        for (key, server) in servers {
            check_server(key, server, &mut problems);
        }
    }
    let server_names: HashSet<&str> = servers
        .map(|m| m.keys().map(String::as_str).collect())
        .unwrap_or_default();

    let imps = list(root, "imps", MAX_IMPS, "Imps", &mut problems);
    let triggers = list(root, "triggers", MAX_TRIGGERS, "triggers", &mut problems);
    let animations = list(
        root,
        "animations",
        MAX_ANIMATIONS,
        "animations",
        &mut problems,
    );

    for (i, trigger) in triggers.iter().enumerate() {
        if !trigger.is_object() {
            problems.add(&format!("/triggers/{i}"), "must be an object");
        }
    }
    let mut all_animations = animations.len();
    let mut all_triggers = triggers.len();
    let mut used_servers: HashSet<&str> = HashSet::new();
    for (i, anim) in animations.iter().enumerate() {
        check_animation(anim, &format!("/animations/{i}"), &mut problems);
    }
    for (i, imp) in imps.iter().enumerate() {
        let at = format!("/imps/{i}");
        let Some(imp) = imp.as_object() else {
            problems.add(&at, "must be an object");
            continue;
        };
        match imp.get("name").and_then(Value::as_str).map(str::trim) {
            Some(n) if !n.is_empty() => {}
            _ => problems.add(&format!("{at}/name"), "an Imp needs a name"),
        }
        match imp.get("chats") {
            None | Some(Value::Null) => {}
            Some(Value::Array(chats)) if chats.is_empty() => {}
            Some(_) => problems.add(
                &format!("{at}/chats"),
                "chats are private and don't belong in a shared kit",
            ),
        }
        if let Some(traits) = imp.get("traits").filter(|t| !t.is_null()) {
            check_traits(traits, &format!("{at}/traits"), &mut problems);
        }
        if let Some(own) = imp.get("animations").filter(|a| !a.is_null()) {
            match own.as_array() {
                Some(own) => {
                    all_animations += own.len();
                    for (n, anim) in own.iter().enumerate() {
                        check_animation(anim, &format!("{at}/animations/{n}"), &mut problems);
                    }
                }
                None => problems.add(&format!("{at}/animations"), "must be a list"),
            }
        }
        if let Some(own) = imp.get("triggers").filter(|t| !t.is_null()) {
            match own.as_array() {
                Some(own) if own.len() <= MAX_TRIGGERS && own.iter().all(Value::is_object) => {
                    all_triggers += own.len()
                }
                _ => problems.add(
                    &format!("{at}/triggers"),
                    format!("must be a list of at most {MAX_TRIGGERS} objects"),
                ),
            }
        }
        if let Some(names) = imp.get("mcpServers").filter(|t| !t.is_null()) {
            match names.as_array() {
                Some(names) => {
                    for name in names {
                        match name.as_str() {
                            Some(n) if server_names.contains(n) => {
                                used_servers.insert(n);
                            }
                            _ => problems.add(
                                &format!("{at}/mcpServers"),
                                "names a tool that isn't in the kit's mcpServers",
                            ),
                        }
                    }
                }
                None => problems.add(&format!("{at}/mcpServers"), "must be a list of tool names"),
            }
        }
        if let Some(url) = imp
            .get("brain")
            .and_then(|b| b.pointer("/service/baseURL"))
            .and_then(Value::as_str)
            && let Some(problem) = url_problem(url)
        {
            problems.add(&format!("{at}/brain/service/baseURL"), problem);
        }
    }
    if all_animations > MAX_ANIMATIONS {
        problems.add(
            "/animations",
            format!("{all_animations} animations, at most {MAX_ANIMATIONS} per kit"),
        );
    }

    let loose_tools = server_names
        .iter()
        .filter(|n| !used_servers.contains(*n))
        .count();
    let counts = Counts {
        imps: imps.len(),
        animations: all_animations,
        triggers: all_triggers,
        tools: server_names.len(),
    };
    if counts.imps + counts.animations + counts.triggers + counts.tools == 0
        && problems.0.is_empty()
    {
        problems.add(
            "",
            "a kit needs at least one Imp, trigger, tool or animation",
        );
    }
    let kind = match (imps.len(), animations.len(), triggers.len(), loose_tools) {
        (1, 0, 0, 0) => Kind::Imp,
        (0, a, 0, 0) if a > 0 => Kind::Animation,
        (0, 0, t, 0) if t > 0 => Kind::Trigger,
        (0, 0, 0, t) if t > 0 => Kind::Tool,
        _ => Kind::Kit,
    };
    let runs_programs = servers.is_some_and(|m| m.values().any(|s| s.get("command").is_some()));

    if !problems.0.is_empty() {
        return Err(problems.0);
    }
    let text = serde_json::to_string(&kit).map_err(|_| {
        vec![Violation {
            pointer: String::new(),
            detail: "can't be written as JSON".to_owned(),
        }]
    })?;
    if text.len() > MAX_BYTES {
        return Err(vec![Violation {
            pointer: String::new(),
            detail: format!("larger than {} KB", MAX_BYTES / 1024),
        }]);
    }
    let sha256 = hex::encode(Sha256::digest(text.as_bytes()));
    Ok(Checked {
        name,
        about,
        kind,
        runs_programs,
        counts,
        text,
        sha256,
    })
}

/// An optional list, at most `max` long. Anything else is a problem and counts as empty.
fn list<'a>(
    root: &'a Map<String, Value>,
    key: &str,
    max: usize,
    what: &str,
    problems: &mut Problems,
) -> &'a [Value] {
    match root.get(key) {
        None | Some(Value::Null) => &[],
        Some(Value::Array(items)) if items.len() <= max => items,
        Some(Value::Array(items)) => {
            problems.add(
                &format!("/{key}"),
                format!("{} {what}, at most {max}", items.len()),
            );
            &[]
        }
        Some(_) => {
            problems.add(&format!("/{key}"), "must be a list");
            &[]
        }
    }
}

fn check_traits(traits: &Value, at: &str, problems: &mut Problems) {
    let Some(traits) = traits.as_object() else {
        problems.add(at, "must be an object");
        return;
    };
    for (key, lo, hi) in TRAITS {
        if let Some(v) = traits.get(key)
            && !is_number(v).is_some_and(|n| (lo..=hi).contains(&n))
        {
            problems.add(
                &format!("{at}/{key}"),
                format!("must be a number from {lo} to {hi}"),
            );
        }
    }
}

fn check_animation(anim: &Value, at: &str, problems: &mut Problems) {
    let Some(anim) = anim.as_object() else {
        problems.add(at, "must be an object");
        return;
    };
    match anim.get("name").and_then(Value::as_str).map(str::trim) {
        Some(n) if !n.is_empty() && n.chars().count() <= 40 => {}
        _ => problems.add(
            &format!("{at}/name"),
            "a name of 1 to 40 characters is required",
        ),
    }
    let Some(beats) = anim
        .get("beats")
        .and_then(Value::as_array)
        .filter(|b| (1..=MAX_BEATS).contains(&b.len()))
    else {
        problems.add(
            &format!("{at}/beats"),
            format!("needs 1 to {MAX_BEATS} beats"),
        );
        return;
    };
    let mut total = 0.0;
    for (n, beat) in beats.iter().enumerate() {
        let at = format!("{at}/beats/{n}");
        let Some(beat) = beat.as_object() else {
            problems.add(&at, "must be an object");
            continue;
        };
        match beat
            .get("duration")
            .and_then(is_number)
            .filter(|d| (MIN_BEAT..=MAX_BEAT).contains(d))
        {
            Some(d) => total += d,
            None => problems.add(
                &format!("{at}/duration"),
                format!("must be a number from {MIN_BEAT} to {MAX_BEAT} seconds"),
            ),
        }
        for (key, allowed) in [
            ("mood", &MOODS[..]),
            ("glyph", &GLYPHS[..]),
            ("move", &MOVES[..]),
        ] {
            if let Some(v) = beat.get(key)
                && !v.as_str().is_some_and(|s| allowed.contains(&s))
            {
                problems.add(&format!("{at}/{key}"), format!("unknown {key}"));
            }
        }
        if let Some(look) = beat.get("look").filter(|l| !l.is_null()) {
            let ok = look.as_array().is_some_and(|l| {
                l.len() == 2
                    && l.iter()
                        .all(|x| is_number(x).is_some_and(|n| (-1.0..=1.0).contains(&n)))
            });
            if !ok {
                problems.add(
                    &format!("{at}/look"),
                    "must be [x, y] with each from -1 to 1",
                );
            }
        }
        for (key, lo, hi) in [("tilt", -30.0, 30.0), ("stretch", -0.3, 0.3)] {
            if let Some(v) = beat.get(key)
                && !is_number(v).is_some_and(|n| (lo..=hi).contains(&n))
            {
                problems.add(
                    &format!("{at}/{key}"),
                    format!("must be a number from {lo} to {hi}"),
                );
            }
        }
        for key in ["hop", "reverse"] {
            if beat.get(key).is_some_and(|v| !v.is_boolean()) {
                problems.add(&format!("{at}/{key}"), "must be true or false");
            }
        }
        if let Some(v) = beat.get("times")
            && !v.as_i64().is_some_and(|t| (1..=8).contains(&t))
        {
            problems.add(&format!("{at}/times"), "must be a whole number from 1 to 8");
        }
    }
    if total > MAX_TOTAL + 1e-9 {
        problems.add(
            &format!("{at}/beats"),
            format!("{total:.1} s long, at most {MAX_TOTAL} s"),
        );
    }
}

fn check_server(key: &str, server: &Value, problems: &mut Problems) {
    let at = format!("/mcpServers/{}", pointer_part(key));
    if key.trim().is_empty() || key.chars().count() > 64 {
        problems.add(&at, "tool names have 1 to 64 characters");
    }
    let Some(server) = server.as_object() else {
        problems.add(&at, "must be an object");
        return;
    };
    let command = server.get("command");
    let url = server.get("url");
    match (command, url) {
        (Some(_), Some(_)) => problems.add(&at, "has both a command and a url"),
        (None, None) => problems.add(&at, "needs a command or a url"),
        (Some(c), None) => {
            if !c.as_str().is_some_and(|c| !c.trim().is_empty()) {
                problems.add(&format!("{at}/command"), "must be text");
            }
        }
        (None, Some(u)) => match u.as_str() {
            Some(u) => {
                if let Some(problem) = url_problem(u) {
                    problems.add(&format!("{at}/url"), problem);
                }
            }
            None => problems.add(&format!("{at}/url"), "must be text"),
        },
    }
    if let Some(args) = server.get("args").filter(|a| !a.is_null())
        && !args
            .as_array()
            .is_some_and(|a| a.iter().all(Value::is_string))
    {
        problems.add(&format!("{at}/args"), "must be a list of text");
    }
    for field in ["env", "headers"] {
        let Some(values) = server.get(field).filter(|v| !v.is_null()) else {
            continue;
        };
        let Some(values) = values.as_object() else {
            problems.add(&format!("{at}/{field}"), "must be an object");
            continue;
        };
        for (name, value) in values {
            if value.as_str() != Some("") {
                problems.add(
                    &format!("{at}/{field}/{}", pointer_part(name)),
                    "must be empty, a kit holds no secrets",
                );
            }
        }
    }
}

/// What's wrong with an address in a kit, if anything: not http(s), credentials in it, or a query
/// parameter named like a secret.
fn url_problem(url: &str) -> Option<String> {
    let rest = url
        .strip_prefix("https://")
        .or_else(|| url.strip_prefix("http://"));
    let Some(rest) = rest else {
        return Some("must start with https:// or http://".to_owned());
    };
    let rest = rest.split('#').next().unwrap_or_default();
    let (before_query, query) = match rest.split_once('?') {
        Some((a, q)) => (a, Some(q)),
        None => (rest, None),
    };
    let authority = before_query.split('/').next().unwrap_or_default();
    if authority.is_empty() || authority.contains(char::is_whitespace) {
        return Some("has no host".to_owned());
    }
    if authority.contains('@') {
        return Some("must not carry a user name or password".to_owned());
    }
    for pair in query.unwrap_or_default().split('&') {
        let name = pair
            .split('=')
            .next()
            .unwrap_or_default()
            .to_ascii_lowercase();
        if SECRET_HINTS.iter().any(|hint| name.contains(hint)) {
            return Some(format!(
                "has a query parameter ({name}) that looks like a secret"
            ));
        }
    }
    None
}

#[cfg(test)]
mod tests {
    use serde_json::json;

    use super::*;

    fn problems_of(kit: Value) -> Vec<String> {
        check(kit)
            .expect_err("kit should fail")
            .into_iter()
            .map(|v| format!("{} {}", v.pointer, v.detail))
            .collect()
    }

    fn animation(beats: Value) -> Value {
        json!({ "imp": 3, "name": "n", "animations": [{ "name": "a", "beats": beats }] })
    }

    #[test]
    fn kinds() {
        let tool = json!({ "imp": 1, "name": "n", "mcpServers": { "s": { "url": "https://x.example/mcp" } } });
        assert_eq!(check(tool).expect("tool").kind, Kind::Tool);
        let imp = json!({ "imp": 2, "name": "n", "imps": [{ "name": "Pip" }] });
        assert_eq!(check(imp).expect("imp").kind, Kind::Imp);
        let two = json!({ "imp": 2, "name": "n", "imps": [{ "name": "Pip" }, { "name": "Pop" }] });
        assert_eq!(check(two).expect("kit").kind, Kind::Kit);
        let anim = animation(json!([{ "duration": 1.0 }]));
        assert_eq!(check(anim).expect("animation").kind, Kind::Animation);
    }

    #[test]
    fn imp_with_its_own_tool_is_still_an_imp() {
        let kit = json!({ "imp": 2, "name": "n", "imps": [{ "name": "Pip", "mcpServers": ["s"] }],
            "mcpServers": { "s": { "command": "npx", "args": ["x"] } } });
        let checked = check(kit).expect("imp");
        assert_eq!(checked.kind, Kind::Imp);
        assert!(checked.runs_programs);
    }

    #[test]
    fn registry_block_is_dropped() {
        let kit = json!({ "imp": 1, "name": "n", "triggers": [{ "when": "x" }], "registry": { "author": "a" } });
        assert!(!check(kit).expect("trigger").text.contains("registry"));
    }

    #[test]
    fn secrets_are_refused() {
        let env = json!({ "imp": 1, "name": "n", "mcpServers": { "s": { "command": "x", "env": { "API_KEY": "sk-1" } } } });
        assert!(problems_of(env)[0].contains("/mcpServers/s/env/API_KEY"));
        let query = json!({ "imp": 1, "name": "n", "mcpServers": { "s": { "url": "https://x.example/mcp?api_key=1" } } });
        assert!(problems_of(query)[0].contains("looks like a secret"));
        let user = json!({ "imp": 1, "name": "n", "mcpServers": { "s": { "url": "https://u:p@x.example/" } } });
        assert!(problems_of(user)[0].contains("user name"));
        let empty = json!({ "imp": 1, "name": "n", "mcpServers": { "s": { "command": "x", "env": { "API_KEY": "" } } } });
        assert!(check(empty).is_ok());
    }

    #[test]
    fn animations_are_checked() {
        assert!(
            problems_of(animation(json!([])))
                .iter()
                .any(|p| p.contains("1 to 24 beats"))
        );
        assert!(
            problems_of(animation(json!([{ "duration": 0.01 }])))
                .iter()
                .any(|p| p.contains("duration"))
        );
        assert!(
            problems_of(animation(json!([{ "duration": 1, "mood": "grumpy" }])))
                .iter()
                .any(|p| p.contains("mood"))
        );
        assert!(
            problems_of(animation(json!([{ "duration": 1, "times": 9 }])))
                .iter()
                .any(|p| p.contains("times"))
        );
        let long = json!(
            (0..5)
                .map(|_| json!({ "duration": 5.0 }))
                .collect::<Vec<_>>()
        );
        assert!(
            problems_of(animation(long))
                .iter()
                .any(|p| p.contains("at most 20"))
        );
    }

    #[test]
    fn limits_and_basics() {
        assert!(problems_of(json!([])).len() == 1);
        assert!(
            problems_of(json!({ "imp": 4, "name": "n", "triggers": [{}] }))[0].contains("/imp")
        );
        assert!(problems_of(json!({ "imp": 1, "triggers": [{}] }))[0].contains("/name"));
        assert!(problems_of(json!({ "imp": 1, "name": "n" }))[0].contains("at least one"));
        let imps: Vec<Value> = (0..21)
            .map(|i| json!({ "name": format!("i{i}") }))
            .collect();
        assert!(
            problems_of(json!({ "imp": 2, "name": "n", "imps": imps }))[0].contains("at most 20")
        );
        let chats = json!({ "imp": 2, "name": "n", "imps": [{ "name": "p", "chats": [{ "title": "x" }] }] });
        assert!(problems_of(chats)[0].contains("private"));
        let traits =
            json!({ "imp": 3, "name": "n", "imps": [{ "name": "p", "traits": { "lids": 0.9 } }] });
        assert!(problems_of(traits)[0].contains("lids"));
    }
}
