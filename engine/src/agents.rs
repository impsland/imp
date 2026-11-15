//! The rules of the shared `.agents/` layout that coding agents read, with no I/O: the front matter of
//! Markdown files, an Imp described by `agents/NAME.md`, a skill (`skills/NAME/SKILL.md`), what goes
//! in the system text (the `AGENTS.md` instructions and the list of skills), the `use_skill` tool,
//! `${NAME}` values, and the digest of what a project asks the person to trust.
//!
//! Finding the folders, reading the files and remembering what was trusted are each app's own work.
//! The vectors are `spec/fixtures/agents.json`.

use crate::chat::ToolSpec;
use crate::workspace::checksum;
use serde_json::json;

/// The most bytes of `AGENTS.md` text put in the system text, all files together.
pub const MOST_INSTRUCTIONS: usize = 32 * 1024;
/// The most skills listed in the system text.
pub const MOST_SKILLS: usize = 100;
/// The tool that reads a skill, and its group (for switching it off: `own.skills.use_skill`).
pub const SKILL_TOOL: &str = "use_skill";
pub const SKILL_GROUP: &str = "skills";
/// The longest skill description kept, in characters.
const MOST_DESCRIPTION: usize = 1024;

// Front matter.

/// The `key: value` lines between `---` lines at the top of a Markdown file. A small part of YAML:
/// plain and quoted text, `[a, b]` and `- item` lists, `|` and `>` blocks, and `#` comments.
#[derive(Debug, Default, Clone, PartialEq)]
pub struct FrontMatter(Vec<(String, FrontValue)>);

#[derive(Debug, Clone, PartialEq)]
enum FrontValue {
    Text(String),
    List(Vec<String>),
}

impl FrontMatter {
    fn get(&self, key: &str) -> Option<&FrontValue> {
        self.0.iter().find(|(k, _)| k == key).map(|(_, v)| v)
    }

    /// A value as text. A list reads as its items joined with commas.
    pub fn text(&self, key: &str) -> Option<String> {
        match self.get(key)? {
            FrontValue::Text(t) => Some(t.clone()),
            FrontValue::List(items) => Some(items.join(", ")),
        }
    }

    /// A value as a list. Text reads as items split at commas.
    pub fn list(&self, key: &str) -> Option<Vec<String>> {
        let items = match self.get(key)? {
            FrontValue::List(items) => items.clone(),
            FrontValue::Text(t) => t.split(',').map(|s| s.trim().to_string()).collect(),
        };
        Some(items.into_iter().filter(|s| !s.is_empty()).collect())
    }
}

/// The front matter of `text` and the rest of it. Text without front matter has an empty one.
pub fn front_matter(text: &str) -> (FrontMatter, &str) {
    let text = text.strip_prefix('\u{feff}').unwrap_or(text);
    let Some(after) = text
        .strip_prefix("---\n")
        .or_else(|| text.strip_prefix("---\r\n"))
    else {
        return (FrontMatter::default(), text);
    };
    let mut end = None;
    let mut at = 0;
    for line in after.split_inclusive('\n') {
        if line.trim_end() == "---" {
            end = Some((at, at + line.len()));
            break;
        }
        at += line.len();
    }
    let Some((head_end, body_start)) = end else {
        return (FrontMatter::default(), text);
    };
    (parse_front(&after[..head_end]), &after[body_start..])
}

fn parse_front(head: &str) -> FrontMatter {
    let lines: Vec<&str> = head.lines().collect();
    let mut out = Vec::new();
    let mut i = 0;
    while i < lines.len() {
        let line = lines[i];
        i += 1;
        if line.trim().is_empty() || line.trim_start().starts_with('#') || line.starts_with(' ') {
            continue;
        }
        let Some((key, value)) = line.split_once(':') else {
            continue;
        };
        let key = key.trim().to_string();
        let value = value.trim();
        // The lines under the key that are indented, or blank.
        let mut nested = Vec::new();
        while i < lines.len()
            && (lines[i].starts_with(' ')
                || lines[i].starts_with('\t')
                || lines[i].trim().is_empty())
        {
            nested.push(lines[i]);
            i += 1;
        }
        let parsed = if value.is_empty() || value.starts_with('|') || value.starts_with('>') {
            let items: Vec<String> = nested
                .iter()
                .filter_map(|l| {
                    l.trim()
                        .strip_prefix("- ")
                        .or_else(|| (l.trim() == "-").then_some(""))
                })
                .map(|s| unquote(s.trim()))
                .collect();
            if value.is_empty() && !items.is_empty() {
                FrontValue::List(items)
            } else {
                let parts: Vec<&str> = nested.iter().map(|l| l.trim()).collect();
                let joined = if value.starts_with('|') {
                    parts.join("\n")
                } else {
                    parts.join(" ")
                };
                FrontValue::Text(joined.trim().to_string())
            }
        } else if let Some(inner) = value.strip_prefix('[').and_then(|v| v.strip_suffix(']')) {
            FrontValue::List(
                inner
                    .split(',')
                    .map(|s| unquote(s.trim()))
                    .filter(|s| !s.is_empty())
                    .collect(),
            )
        } else {
            let mut text = unquote(value);
            // A plain value that goes on over indented lines.
            if !value.starts_with('"') && !value.starts_with('\'') {
                for l in &nested {
                    if !l.trim().is_empty() {
                        text.push(' ');
                        text.push_str(l.trim());
                    }
                }
            }
            FrontValue::Text(text)
        };
        out.push((key, parsed));
    }
    FrontMatter(out)
}

fn unquote(s: &str) -> String {
    let s = s.trim();
    for q in ['"', '\''] {
        let Some(rest) = s.strip_prefix(q) else {
            continue;
        };
        // The closing quote, past escaped ones. What follows it (a comment) is dropped.
        let mut end = None;
        let mut chars = rest.char_indices().peekable();
        while let Some((i, c)) = chars.next() {
            if q == '"' && c == '\\' {
                chars.next();
            } else if c == q {
                if q == '\'' && chars.peek().is_some_and(|(_, n)| *n == '\'') {
                    chars.next();
                } else {
                    end = Some(i);
                    break;
                }
            }
        }
        let Some(end) = end else {
            continue;
        };
        let inner = &rest[..end];
        return if q == '"' {
            inner.replace("\\\"", "\"").replace("\\n", "\n")
        } else {
            inner.replace("''", "'")
        };
    }
    // A comment after a plain value.
    match s.find(" #") {
        Some(at) => s[..at].trim_end().to_string(),
        None => s.to_string(),
    }
}

// Names and values.

/// Whether `name` can be an environment variable name. This also keeps a pasted key out of a file.
pub fn valid_env_name(name: &str) -> bool {
    let mut chars = name.chars();
    chars
        .next()
        .is_some_and(|c| c.is_ascii_alphabetic() || c == '_')
        && chars.all(|c| c.is_ascii_alphanumeric() || c == '_')
}

/// The NAME of `${NAME}` or `$NAME`.
pub fn env_reference(value: &str) -> Option<&str> {
    let value = value.trim();
    let name = value
        .strip_prefix("${")
        .and_then(|v| v.strip_suffix('}'))
        .or_else(|| value.strip_prefix('$'))?;
    valid_env_name(name).then_some(name)
}

/// Fills in `${NAME}` and `${NAME:-default}` from `env`. An unset or empty variable without a
/// default is empty. `${` that is not a variable stays as it is.
pub fn fill_env(value: &str, env: &impl Fn(&str) -> Option<String>) -> String {
    let mut out = String::new();
    let mut rest = value;
    while let Some(start) = rest.find("${") {
        out.push_str(&rest[..start]);
        let after = &rest[start + 2..];
        let Some(end) = after.find('}') else {
            out.push_str(&rest[start..]);
            return out;
        };
        let inner = &after[..end];
        let (name, default) = match inner.split_once(":-") {
            Some((n, d)) => (n, Some(d)),
            None => (inner, None),
        };
        if valid_env_name(name) {
            let found = env(name).filter(|v| !v.is_empty());
            out.push_str(&found.or(default.map(str::to_string)).unwrap_or_default());
        } else {
            out.push_str(&rest[start..start + 3 + end]);
        }
        rest = &after[end + 1..];
    }
    out.push_str(rest);
    out
}

/// A skill name as the Agent Skills format allows it: up to 64 lowercase letters, digits and single dashes.
pub fn valid_skill_name(name: &str) -> bool {
    (1..=64).contains(&name.len())
        && name
            .chars()
            .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '-')
        && !name.starts_with('-')
        && !name.ends_with('-')
        && !name.contains("--")
}

// Agents.

/// An Imp as `agents/NAME.md` describes it. What is left out keeps the Imp's own setting.
#[derive(Debug, Clone, PartialEq, Default)]
pub struct AgentSpec {
    pub name: String,
    pub description: Option<String>,
    pub model: Option<String>,
    /// The text under the front matter (or `personality:`): how the Imp behaves.
    pub personality: Option<String>,
    /// Only these tools are offered, by name, id or group (`read_file`, `mcp.files.read_file`, `mcp.files`).
    pub tools: Option<Vec<String>>,
    /// These tools are never offered, in the same forms.
    pub tools_off: Vec<String>,
    pub hue: Option<f64>,
    /// The service address, without a slash at the end.
    pub base_url: Option<String>,
    /// The environment variable that holds the service's key. A key itself is never read from a file.
    pub api_key_env: Option<String>,
    /// The Imp a chat in the folder talks to when none is named.
    pub default: bool,
}

impl AgentSpec {
    /// Reads an agent file. `stem` (the file name without `.md`) names the Imp when the front matter
    /// does not. The error is a sentence about the file, which never repeats a value that may be a key.
    pub fn parse(stem: &str, text: &str) -> Result<Self, String> {
        let (front, body) = front_matter(text);
        let hue = match front.text("hue") {
            Some(h) => Some(
                h.parse::<f64>()
                    .ok()
                    .filter(|h| (0.0..=1.0).contains(h))
                    .ok_or("hue is a number from 0 to 1.")?,
            ),
            None => None,
        };
        let base_url = match front.text("base_url").filter(|u| !u.is_empty()) {
            Some(u) if u.starts_with("http://") || u.starts_with("https://") => {
                Some(u.trim_end_matches('/').to_string())
            }
            Some(_) => return Err("base_url must start with http:// or https://.".into()),
            None => None,
        };
        let api_key_env = match (front.text("api_key_env"), front.text("api_key")) {
            (Some(name), _) if valid_env_name(&name) => Some(name),
            (Some(_), _) => {
                return Err(
                    "api_key_env is the NAME of an environment variable, such as OPENROUTER_API_KEY."
                        .into(),
                );
            }
            (None, Some(value)) => Some(
                env_reference(&value)
                    .ok_or(
                        "write api_key as ${NAME}, the environment variable that holds the key. A key is never written in a file.",
                    )?
                    .to_string(),
            ),
            (None, None) => None,
        };
        let body = body.trim();
        let personality = if body.is_empty() {
            front.text("personality")
        } else {
            Some(body.to_string())
        };
        Ok(Self {
            name: front.text("name").unwrap_or_else(|| stem.to_string()),
            description: front.text("description"),
            model: front
                .text("model")
                .filter(|m| !m.is_empty() && m != "inherit"),
            personality,
            tools: front.list("tools"),
            tools_off: front
                .list("disallowedTools")
                .or_else(|| front.list("tools_off"))
                .unwrap_or_default(),
            hue,
            base_url,
            api_key_env,
            default: front.text("default").as_deref() == Some("true"),
        })
    }

    /// Whether it lets the Imp use a tool, by its id, the name the model sees (with or without the
    /// server's prefix), or its group. Without a `tools` list, every tool.
    pub fn allows(&self, id: &str, name: &str, group: &str) -> bool {
        let Some(tools) = &self.tools else {
            return true;
        };
        let short = name.rsplit("__").next().unwrap_or(name);
        tools.iter().any(|t| {
            let t = t.trim();
            t == "*" || t == id || t == name || t == short || t == group
        })
    }

    /// Whether it sets the Imp's `key` (`model`, `personality`, `hue`, `base_url`, `api_key_env`).
    pub fn sets(&self, key: &str) -> bool {
        match key {
            "model" => self.model.is_some(),
            "personality" => self.personality.is_some(),
            "hue" => self.hue.is_some(),
            "base_url" | "url" => self.base_url.is_some(),
            "api_key_env" => self.api_key_env.is_some(),
            _ => false,
        }
    }

    /// It names a service or a key, which a project's file may only do once the person trusts it.
    pub fn needs_trust(&self) -> bool {
        self.base_url.is_some() || self.api_key_env.is_some()
    }
}

// Skills.

/// A skill: its name and when to use it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SkillSpec {
    pub name: String,
    pub description: String,
}

impl SkillSpec {
    /// Reads a `SKILL.md`. `folder` (its folder's name) names the skill when the front matter does not.
    pub fn parse(folder: &str, text: &str) -> Result<Self, String> {
        let (front, _) = front_matter(text);
        let name = front.text("name").unwrap_or_else(|| folder.to_string());
        let description = front
            .text("description")
            .filter(|d| !d.trim().is_empty())
            .ok_or("it has no description in its front matter, so the Imp could not know when to use it.")?;
        if !valid_skill_name(&name) {
            return Err(format!(
                "the skill name {name:?} is not allowed: use up to 64 lowercase letters, digits and dashes."
            ));
        }
        let description = description.split_whitespace().collect::<Vec<_>>().join(" ");
        Ok(Self {
            name,
            description: description.chars().take(MOST_DESCRIPTION).collect(),
        })
    }
}

/// The tool that reads a skill, offering the skills by name.
pub fn skill_tool(names: &[String]) -> ToolSpec {
    ToolSpec {
        name: SKILL_TOOL.into(),
        description: "Read the instructions of a skill listed in the system text, before doing the work it is for.".into(),
        parameters: json!({
            "type": "object",
            "properties": {"name": {"type": "string", "enum": names}},
            "required": ["name"],
        }),
    }
}

/// What the model gets for a skill: the text of its `SKILL.md` without the front matter, where its
/// folder is, and the other files in it.
pub fn skill_text(name: &str, folder: &str, text: &str, files: &[String]) -> String {
    let (_, body) = front_matter(text);
    let mut out = format!(
        "Skill {name} (its folder is {folder}; paths in it are relative to that folder)\n\n{}",
        body.trim()
    );
    if !files.is_empty() {
        out.push_str("\n\nFiles in the skill's folder:\n");
        for f in files {
            out.push_str(&format!("- {f}\n"));
        }
    }
    out
}

// The system text.

/// One `AGENTS.md`: how to name it to the model, and its text.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Instructions {
    pub label: String,
    pub text: String,
}

/// What became of an `AGENTS.md` that did not fit in [`MOST_INSTRUCTIONS`].
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum LeftOut {
    Cut(String),
    Dropped(String),
}

/// The instructions that fit in [`MOST_INSTRUCTIONS`], in order, and the ones cut short or left out.
/// Blank ones are skipped.
pub fn fit_instructions(all: Vec<Instructions>) -> (Vec<Instructions>, Vec<LeftOut>) {
    let mut kept = Vec::new();
    let mut left = Vec::new();
    let mut used = 0;
    for doc in all {
        let text = doc.text.trim();
        if text.is_empty() {
            continue;
        }
        let room = MOST_INSTRUCTIONS.saturating_sub(used);
        if room == 0 {
            left.push(LeftOut::Dropped(doc.label));
            continue;
        }
        let mut text = text.to_string();
        if text.len() > room {
            let mut cut = room;
            while !text.is_char_boundary(cut) {
                cut -= 1;
            }
            text.truncate(cut);
            left.push(LeftOut::Cut(doc.label.clone()));
        }
        used += text.len();
        kept.push(Instructions {
            label: doc.label,
            text,
        });
    }
    (kept, left)
}

/// What goes after who the Imp is in the system text: the instructions, then the list of skills.
/// It stays the same for the whole chat, so a service that caches the start of a request reuses it.
pub fn prompt(instructions: &[Instructions], skills: &[SkillSpec]) -> String {
    let mut out = String::new();
    if !instructions.is_empty() {
        out.push_str(
            "\n\n# Project instructions\n\nThe person keeps these notes (AGENTS.md) for AI helpers working in their files. Follow them for the work you do here. Where they disagree, the notes of the folder nearer the chat's folder win, and what the person says in the chat wins over all of them.",
        );
        for doc in instructions {
            out.push_str(&format!(
                "\n\n<instructions file=\"{}\">\n{}\n</instructions>",
                doc.label, doc.text
            ));
        }
    }
    if !skills.is_empty() {
        out.push_str(&format!(
            "\n\n# Skills\n\nSkills are written instructions for particular kinds of work. When what you are asked matches a skill's description, call the tool {SKILL_TOOL} with its name before you start, and follow what it says. Do not call it for skills that do not apply.\n"
        ));
        for skill in skills.iter().take(MOST_SKILLS) {
            out.push_str(&format!("\n- {}: {}", skill.name, skill.description));
        }
    }
    out
}

/// The digest of what a project asks the person to trust: its MCP config file as it is, and the
/// service and key variable of each of its Imps that names one. None when it asks for nothing. Any
/// change gives another digest, so it waits to be trusted again.
pub fn trust_digest(mcp_config: Option<&str>, agents: &[&AgentSpec]) -> Option<String> {
    let mut asked = mcp_config.unwrap_or_default().to_string();
    let mut asking: Vec<&&AgentSpec> = agents.iter().filter(|a| a.needs_trust()).collect();
    asking.sort_by(|a, b| a.name.cmp(&b.name));
    for agent in asking {
        asked.push_str(&format!(
            "\nagent {}\nbase_url {}\napi_key_env {}\n",
            agent.name,
            agent.base_url.as_deref().unwrap_or(""),
            agent.api_key_env.as_deref().unwrap_or("")
        ));
    }
    (!asked.is_empty()).then(|| checksum(asked.as_bytes()))
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::Value;

    fn fixture() -> Value {
        serde_json::from_str(include_str!("../../spec/fixtures/agents.json")).unwrap()
    }

    #[test]
    fn front_matter_vectors() {
        for case in fixture()["front_matter"].as_array().unwrap() {
            let (front, body) = front_matter(case["text"].as_str().unwrap());
            for (key, want) in case["text_values"].as_object().unwrap() {
                assert_eq!(
                    front.text(key).map(Value::from).unwrap_or(Value::Null),
                    *want,
                    "{} {key}",
                    case["name"]
                );
            }
            for (key, want) in case["lists"].as_object().into_iter().flatten() {
                let got: Option<Vec<String>> = front.list(key);
                assert_eq!(serde_json::json!(got), *want, "{} {key}", case["name"]);
            }
            assert_eq!(body, case["body"].as_str().unwrap(), "{}", case["name"]);
        }
    }

    #[test]
    fn agent_vectors() {
        for case in fixture()["agents"].as_array().unwrap() {
            let got = AgentSpec::parse(
                case["stem"].as_str().unwrap(),
                case["text"].as_str().unwrap(),
            );
            match case.get("error") {
                Some(error) => {
                    let e = got.expect_err(case["name"].as_str().unwrap());
                    assert!(e.contains(error.as_str().unwrap()), "{}: {e}", case["name"]);
                    if let Some(secret) = case.get("never_says") {
                        assert!(!e.contains(secret.as_str().unwrap()), "{e}");
                    }
                }
                None => {
                    let a = got.unwrap();
                    let want = &case["agent"];
                    let got = serde_json::json!({
                        "name": a.name, "description": a.description, "model": a.model,
                        "personality": a.personality, "tools": a.tools, "tools_off": a.tools_off,
                        "hue": a.hue, "base_url": a.base_url, "api_key_env": a.api_key_env,
                        "default": a.default,
                    });
                    for (key, value) in want.as_object().unwrap() {
                        assert_eq!(got[key], *value, "{} {key}", case["name"]);
                    }
                }
            }
        }
    }

    #[test]
    fn skill_vectors() {
        for case in fixture()["skills"].as_array().unwrap() {
            let got = SkillSpec::parse(
                case["folder"].as_str().unwrap(),
                case["text"].as_str().unwrap(),
            );
            match case.get("error") {
                Some(error) => {
                    let e = got.unwrap_err();
                    assert!(e.contains(error.as_str().unwrap()), "{}: {e}", case["name"]);
                }
                None => {
                    let s = got.unwrap();
                    assert_eq!(s.name, case["skill"]["name"].as_str().unwrap());
                    assert_eq!(
                        s.description,
                        case["skill"]["description"].as_str().unwrap()
                    );
                }
            }
        }
    }

    #[test]
    fn value_vectors() {
        let f = fixture();
        let env = f["values"]["env"].clone();
        let lookup = |n: &str| env.get(n).and_then(Value::as_str).map(str::to_string);
        for case in f["values"]["cases"].as_array().unwrap() {
            assert_eq!(
                fill_env(case["value"].as_str().unwrap(), &lookup),
                case["filled"].as_str().unwrap(),
                "{case}"
            );
        }
    }

    #[test]
    fn tools_lists_allow_by_name_id_or_group() {
        let agent = AgentSpec {
            tools: Some(vec!["read_file".into(), "mcp.web".into()]),
            ..AgentSpec::default()
        };
        assert!(agent.allows("mcp.files.read_file", "files__read_file", "mcp.files"));
        assert!(agent.allows("mcp.web.get", "web__get", "mcp.web"));
        assert!(!agent.allows("mcp.files.write", "files__write", "mcp.files"));
        assert!(AgentSpec::default().allows("a", "b", "c"));
    }

    #[test]
    fn instructions_fit_and_the_prompt_lists_skills() {
        let big = "x".repeat(MOST_INSTRUCTIONS - 10);
        let (kept, left) = fit_instructions(vec![
            Instructions {
                label: "a".into(),
                text: big,
            },
            Instructions {
                label: "blank".into(),
                text: "  ".into(),
            },
            Instructions {
                label: "b".into(),
                text: "é".repeat(20),
            },
            Instructions {
                label: "c".into(),
                text: "more".into(),
            },
        ]);
        assert_eq!(kept.len(), 2);
        assert!(kept[1].text.len() <= 10);
        assert_eq!(
            left,
            [LeftOut::Cut("b".into()), LeftOut::Dropped("c".into())]
        );
        let text = prompt(
            &[Instructions {
                label: "AGENTS.md".into(),
                text: "Be brief.".into(),
            }],
            &[SkillSpec {
                name: "notes".into(),
                description: "Take notes".into(),
            }],
        );
        assert!(text.contains("<instructions file=\"AGENTS.md\">\nBe brief.\n</instructions>"));
        assert!(text.contains("- notes: Take notes"));
        assert!(text.contains(SKILL_TOOL));
        assert_eq!(prompt(&[], &[]), "");
        let read = skill_text(
            "notes",
            "/s/notes",
            "---\nname: notes\n---\nStep one.",
            &["t.md".into()],
        );
        assert!(read.contains("Step one.") && read.contains("- t.md") && !read.contains("name:"));
        assert_eq!(
            skill_tool(&["notes".into()]).parameters["properties"]["name"]["enum"],
            json!(["notes"])
        );
    }

    #[test]
    fn the_trust_digest_changes_with_what_is_asked() {
        let quiet = AgentSpec {
            name: "a".into(),
            model: Some("m".into()),
            ..AgentSpec::default()
        };
        assert_eq!(trust_digest(None, &[&quiet]), None);
        let asking = AgentSpec {
            name: "b".into(),
            base_url: Some("http://x/v1".into()),
            ..AgentSpec::default()
        };
        let one = trust_digest(Some("{}"), &[&asking, &quiet]).unwrap();
        assert_eq!(one, trust_digest(Some("{}"), &[&quiet, &asking]).unwrap());
        let moved = AgentSpec {
            base_url: Some("http://y/v1".into()),
            ..asking.clone()
        };
        assert_ne!(one, trust_digest(Some("{}"), &[&moved]).unwrap());
        assert_ne!(one, trust_digest(Some("{ }"), &[&asking]).unwrap());
        assert_eq!(trust_digest(None, &[&asking]).unwrap().len(), 64);
    }
}
