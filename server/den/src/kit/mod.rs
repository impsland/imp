//! Document validation: the same limits and rules as Imp itself (`Kit.swift`), applied to a document
//! before the Den keeps it. Animation/trait, tool and skill rules live in the submodules.
//! The vocabulary the rules need (moods, glyphs, moves, trait ranges) is written out in `animation`.

use std::collections::HashSet;

use serde::{Deserialize, Serialize};
use serde_json::{Map, Value};
use sha2::{Digest, Sha256};

use crate::error::{Error, Violation};

mod animation;
mod format;
mod skills;
mod tools;
mod trigger;

pub use format::reference;

use animation::{check_animation, check_traits};
use skills::{MAX_SKILLS, check_skills};
use tools::{check_server, url_problem};

/// The newest document `format` this Den reads.
pub const MAX_FORMAT: i64 = 1;
/// Largest document of an `imp`, `animation`, `trigger` or `tool`.
pub const MAX_ITEM_BYTES: usize = 64 * 1024;
/// Largest document of a `kit`.
pub const MAX_KIT_BYTES: usize = 256 * 1024;
const MAX_IMPS: usize = 20;
const MAX_TRIGGERS: usize = 50;
const MAX_SERVERS: usize = 20;
const MAX_ANIMATIONS: usize = 50;
const MAX_PROBLEMS: usize = 25;

/// The type of an item.
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
    pub const ALL: [Kind; 5] = [
        Kind::Imp,
        Kind::Animation,
        Kind::Trigger,
        Kind::Tool,
        Kind::Kit,
    ];

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
        Self::ALL.into_iter().find(|k| k.as_str() == s)
    }

    /// The largest document of this type, in bytes.
    pub fn max_bytes(self) -> usize {
        if self == Kind::Kit {
            MAX_KIT_BYTES
        } else {
            MAX_ITEM_BYTES
        }
    }
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize)]
pub struct Counts {
    pub imps: usize,
    pub animations: usize,
    pub triggers: usize,
    pub tools: usize,
    #[serde(default)]
    pub skills: usize,
}

/// A document that passed, ready to store.
#[derive(Debug)]
pub struct Checked {
    pub name: String,
    pub about: String,
    pub format: i64,
    pub runs_programs: bool,
    pub counts: Counts,
    /// The document as kept: compact, with sorted keys.
    pub text: String,
    pub sha256: String,
}

pub(super) struct Problems(Vec<Violation>);

impl Problems {
    pub(super) fn add(&mut self, pointer: &str, detail: impl Into<String>) {
        if self.0.len() < MAX_PROBLEMS {
            self.0.push(Violation {
                pointer: pointer.to_owned(),
                detail: detail.into(),
            });
        }
    }
}

pub(super) fn is_number(v: &Value) -> Option<f64> {
    v.as_f64().filter(|n| n.is_finite())
}

/// A whole number, written as `2` or `2.0`: JSON has one number type, so both are the same value.
pub(super) fn whole_number(v: &Value) -> Option<i64> {
    v.as_i64().or_else(|| {
        is_number(v)
            .filter(|n| n.fract() == 0.0 && n.abs() < 2f64.powi(53))
            .map(|n| n as i64)
    })
}

pub(super) fn pointer_part(s: &str) -> String {
    s.replace('~', "~0").replace('/', "~1")
}

/// The document as compact JSON with the keys of every object in sorted order.
pub fn canonical(value: &Value) -> String {
    fn write(value: &Value, out: &mut String) {
        match value {
            Value::Object(map) => {
                let mut keys: Vec<&String> = map.keys().collect();
                keys.sort();
                out.push('{');
                for (i, key) in keys.into_iter().enumerate() {
                    if i > 0 {
                        out.push(',');
                    }
                    out.push_str(&Value::String(key.clone()).to_string());
                    out.push(':');
                    write(&map[key], out);
                }
                out.push('}');
            }
            Value::Array(items) => {
                out.push('[');
                for (i, item) in items.iter().enumerate() {
                    if i > 0 {
                        out.push(',');
                    }
                    write(item, out);
                }
                out.push(']');
            }
            other => out.push_str(&other.to_string()),
        }
    }
    let mut out = String::new();
    write(value, &mut out);
    out
}

fn invalid(pointer: &str, detail: &str) -> Error {
    Error::invalid(pointer, detail)
}

/// Checks `doc` as an item of type `kind`. A failure is `validation-failed` (with up to 25 problems) or
/// `unsupported-format`.
pub fn check(doc: Value, kind: Kind) -> Result<Checked, Error> {
    let mut problems = Problems(Vec::new());
    let Some(root) = doc.as_object() else {
        return Err(invalid("", "a document is a JSON object"));
    };

    let format = match root.get("format") {
        None | Some(Value::Null) => {
            problems.add("/format", "required: the integer 1");
            0
        }
        Some(v) => match whole_number(v) {
            Some(n) if n > MAX_FORMAT => {
                return Err(Error::UnsupportedFormat(format!(
                    "This Den reads kit format {MAX_FORMAT} at most."
                )));
            }
            Some(n) if n >= 1 => n,
            _ => {
                problems.add("/format", "must be a whole number, 1 or more");
                0
            }
        },
    };

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
    let skills = list(root, "skills", MAX_SKILLS, "skills", &mut problems);
    check_skills(skills, &mut problems);

    for (i, trigger) in triggers.iter().enumerate() {
        trigger::check_trigger(trigger, &format!("/triggers/{i}"), &mut problems);
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
                Some(own) if own.len() <= MAX_TRIGGERS => {
                    all_triggers += own.len();
                    for (n, trig) in own.iter().enumerate() {
                        trigger::check_trigger(trig, &format!("{at}/triggers/{n}"), &mut problems);
                    }
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
            format!("{all_animations} animations, at most {MAX_ANIMATIONS} per document"),
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
        skills: skills.len(),
    };
    check_shape(
        kind,
        &Shape {
            imps: imps.len(),
            animations: animations.len(),
            triggers: triggers.len(),
            tools: server_names.len(),
            loose_tools,
            skills: skills.len(),
        },
        &mut problems,
    );
    let runs_programs = !skills.is_empty()
        || servers.is_some_and(|m| m.values().any(|s| s.get("command").is_some()));

    if !problems.0.is_empty() {
        return Err(Error::Invalid(problems.0));
    }
    let text = canonical(&doc);
    if text.len() > kind.max_bytes() {
        return Err(invalid(
            "",
            &format!(
                "a {} is at most {} KB, this one is {} KB",
                kind.as_str(),
                kind.max_bytes() / 1024,
                text.len().div_ceil(1024)
            ),
        ));
    }
    let sha256 = hex::encode(Sha256::digest(text.as_bytes()));
    Ok(Checked {
        name,
        about,
        format,
        runs_programs,
        counts,
        text,
        sha256,
    })
}

/// How many of each thing sit at the top level of a document.
struct Shape {
    imps: usize,
    animations: usize,
    triggers: usize,
    tools: usize,
    /// Tools no Imp of the document lists.
    loose_tools: usize,
    skills: usize,
}

/// A document must be what its type says (see the table in `spec/PROTOCOL.md`).
fn check_shape(kind: Kind, s: &Shape, problems: &mut Problems) {
    let only = |problems: &mut Problems, key: &str, n: usize, why: &str| {
        if n > 0 {
            problems.add(&format!("/{key}"), why.to_owned());
        }
    };
    let exactly_one = |problems: &mut Problems, key: &str, n: usize, what: &str| {
        if n != 1 {
            problems.add(
                &format!("/{key}"),
                format!("{what} holds exactly one entry here, this has {n}"),
            );
        }
    };
    let no = |kind: Kind| format!("a {} holds no such entries", kind.as_str());
    match kind {
        Kind::Imp => {
            exactly_one(problems, "imps", s.imps, "an imp");
            only(
                problems,
                "animations",
                s.animations,
                "an imp's animations go inside the Imp",
            );
            only(
                problems,
                "triggers",
                s.triggers,
                "an imp's triggers go inside the Imp",
            );
            only(problems, "skills", s.skills, "skills belong in a kit");
            only(
                problems,
                "mcpServers",
                s.loose_tools,
                "an imp holds only the tools that Imp lists",
            );
        }
        Kind::Animation => {
            exactly_one(problems, "animations", s.animations, "an animation");
            only(problems, "imps", s.imps, &no(kind));
            only(problems, "triggers", s.triggers, &no(kind));
            only(problems, "mcpServers", s.tools, &no(kind));
            only(problems, "skills", s.skills, "skills belong in a kit");
        }
        Kind::Trigger => {
            exactly_one(problems, "triggers", s.triggers, "a trigger");
            if s.animations > 1 {
                problems.add(
                    "/animations",
                    "a trigger holds at most the one animation it plays",
                );
            }
            only(problems, "imps", s.imps, &no(kind));
            only(problems, "mcpServers", s.tools, &no(kind));
            only(problems, "skills", s.skills, "skills belong in a kit");
        }
        Kind::Tool => {
            exactly_one(problems, "mcpServers", s.tools, "a tool");
            only(problems, "imps", s.imps, &no(kind));
            only(problems, "animations", s.animations, &no(kind));
            only(problems, "triggers", s.triggers, &no(kind));
            only(problems, "skills", s.skills, "skills belong in a kit");
        }
        Kind::Kit => {
            if s.imps + s.animations + s.triggers + s.tools + s.skills == 0 && problems.0.is_empty()
            {
                problems.add(
                    "",
                    "a kit needs at least one Imp, animation, trigger, tool or skill",
                );
            }
        }
    }
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

#[cfg(test)]
mod tests;
