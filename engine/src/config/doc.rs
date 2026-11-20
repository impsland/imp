//! The Markdown files of `.agents`: agents (`agents/NAME.md`), skills (`skills/NAME/SKILL.md`) and
//! commands (`commands/NAME.md`). Each is YAML front matter and a body, and is read and written without
//! losing the body or any front matter key the core does not know.

use crate::config::subst::{Sources, substitute_value};
use crate::config::{ModelRef, Rule};
use serde::de::DeserializeOwned;
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::BTreeMap;
use std::path::Path;

fn is_false(b: &bool) -> bool {
    !*b
}

/// The front matter of `text` (the YAML between the `---` lines at the top, if there are any) and the
/// text after it. `Err` when the front matter is opened and not closed.
pub fn split_front_matter(text: &str) -> Result<(Option<&str>, &str), String> {
    let text = text.strip_prefix('\u{feff}').unwrap_or(text);
    let Some(after) = text
        .strip_prefix("---\n")
        .or_else(|| text.strip_prefix("---\r\n"))
    else {
        return Ok((None, text));
    };
    let mut at = 0;
    for line in after.split_inclusive('\n') {
        if line.trim_end() == "---" {
            return Ok((Some(&after[..at]), &after[at + line.len()..]));
        }
        at += line.len();
    }
    Err("the front matter is not closed with a --- line".into())
}

/// The body as the files keep it: no blank lines before or whitespace after.
fn clean_body(body: &str) -> String {
    body.trim_start_matches(['\n', '\r']).trim_end().to_string()
}

/// Reads the front matter into `T` (after filling in `{env:}` and `{file:}` when `fill` is given) and
/// returns the body.
fn read_doc<T: DeserializeOwned + Default>(
    text: &str,
    fill: Option<(&Path, &dyn Sources, &mut Vec<String>)>,
) -> Result<(T, String), String> {
    let (head, body) = split_front_matter(text)?;
    let front = match head.filter(|h| !h.trim().is_empty()) {
        None => T::default(),
        Some(head) => {
            let mut value: Value = serde_yaml_ng::from_str(head)
                .map_err(|e| format!("the front matter is not valid: {e}"))?;
            if value.is_null() {
                return Ok((T::default(), clean_body(body)));
            }
            if let Some((base, sources, problems)) = fill {
                substitute_value(&mut value, base, sources, problems);
            }
            serde_json::from_value(value)
                .map_err(|e| format!("the front matter does not fit: {e}"))?
        }
    };
    Ok((front, clean_body(body)))
}

fn write_doc<T: Serialize>(front: &T, body: &str) -> String {
    let yaml = serde_yaml_ng::to_string(front).unwrap_or_default();
    let yaml = if yaml.trim() == "{}" {
        String::new()
    } else {
        yaml
    };
    let mut out = format!("---\n{yaml}---\n");
    let body = clean_body(body);
    if !body.is_empty() {
        out.push('\n');
        out.push_str(&body);
        out.push('\n');
    }
    out
}

// Agents

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Mode {
    /// An Imp you talk to.
    Primary,
    /// Only other Imps call it.
    Subagent,
    #[default]
    All,
}

/// Headers and body fields added to every request an agent makes.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
pub struct AgentRequest {
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub headers: BTreeMap<String, String>,
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub body: BTreeMap<String, Value>,
}

/// An agent: the front matter keys of the `.agents` v2 format, and the system prompt (the body).
/// The name is the file's name.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
pub struct Agent {
    #[serde(skip)]
    pub name: String,
    /// The text under the front matter: the system prompt.
    #[serde(skip)]
    pub body: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub description: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub mode: Option<Mode>,
    /// `provider/model#variant`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub model: Option<String>,
    /// The variant on its own, when `model` is inherited.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub variant: Option<String>,
    /// `#rrggbb`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub color: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub steps: Option<u32>,
    #[serde(default, skip_serializing_if = "is_false")]
    pub hidden: bool,
    #[serde(default, skip_serializing_if = "is_false")]
    pub disabled: bool,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub permissions: Vec<Rule>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub request: Option<AgentRequest>,
    /// The prompt, when it is not the body.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub system: Option<String>,
    #[serde(flatten)]
    pub extra: BTreeMap<String, Value>,
}

impl Agent {
    /// Reads an agent file as it is, without filling in references (use this to change a file).
    pub fn parse(name: &str, text: &str) -> Result<Self, String> {
        let (mut agent, body): (Self, String) = read_doc(text, None)?;
        agent.name = name.into();
        agent.body = body;
        Ok(agent)
    }

    /// Reads an agent file for use: `{env:}` and `{file:}` in the front matter are filled in, relative
    /// to `base` (the file's folder). What went wrong in filling is in `problems`.
    pub fn parse_filled(
        name: &str,
        text: &str,
        base: &Path,
        sources: &dyn Sources,
        problems: &mut Vec<String>,
    ) -> Result<Self, String> {
        let (mut agent, body): (Self, String) = read_doc(text, Some((base, sources, problems)))?;
        agent.name = name.into();
        agent.body = body;
        Ok(agent)
    }

    /// The file's text: front matter, then the body. Reading it gives the same agent.
    pub fn to_markdown(&self) -> String {
        write_doc(self, &self.body)
    }

    pub fn mode(&self) -> Mode {
        self.mode.unwrap_or_default()
    }

    /// The system prompt: the body, else `system`.
    pub fn prompt(&self) -> &str {
        if self.body.is_empty() {
            self.system.as_deref().unwrap_or_default()
        } else {
            &self.body
        }
    }

    /// An Imp you talk to (`primary` or `all`) that is loaded.
    pub fn is_imp(&self) -> bool {
        !self.disabled && matches!(self.mode(), Mode::Primary | Mode::All)
    }

    /// The model it uses: its own `model` (a `variant` fills in a missing `#variant`), else `default`
    /// with its `variant`. `Ok(None)` when neither names one.
    pub fn model_ref(
        &self,
        default: Option<&str>,
    ) -> Result<Option<ModelRef>, crate::config::ModelRefError> {
        let Some(text) = self.model.as_deref().or(default) else {
            return Ok(None);
        };
        let mut model = ModelRef::parse(text)?;
        if let Some(variant) = &self.variant {
            model.variant = Some(variant.clone());
        }
        Ok(Some(model))
    }

    /// What is wrong with the values (not with the YAML), in plain words.
    pub fn problems(&self) -> Vec<String> {
        let mut out = Vec::new();
        if !valid_agent_name(&self.name) {
            out.push(format!(
                "the agent name {:?} is not allowed: use 1 to 32 letters, digits, - and _.",
                self.name
            ));
        }
        if let Some(model) = &self.model
            && let Err(e) = ModelRef::parse(model)
        {
            out.push(e.to_string());
        }
        if let Some(color) = &self.color
            && !valid_color(color)
        {
            out.push(format!("color {color:?} is not #rrggbb."));
        }
        if self.steps == Some(0) {
            out.push("steps must be at least 1.".into());
        }
        out
    }
}

/// An agent's name is its file's name: 1 to 32 letters, digits, `-` and `_`, so it is safe as a file name.
pub fn valid_agent_name(name: &str) -> bool {
    (1..=32).contains(&name.len())
        && name
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_')
}

/// `#rrggbb`.
pub fn valid_color(color: &str) -> bool {
    color.len() == 7 && color.starts_with('#') && color[1..].chars().all(|c| c.is_ascii_hexdigit())
}

// Skills

/// A skill (Agent Skills): `skills/NAME/SKILL.md`.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
pub struct Skill {
    #[serde(default)]
    pub name: String,
    #[serde(default)]
    pub description: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub license: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub compatibility: Option<String>,
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub metadata: BTreeMap<String, Value>,
    #[serde(
        default,
        rename = "allowed-tools",
        skip_serializing_if = "Option::is_none"
    )]
    pub allowed_tools: Option<String>,
    #[serde(skip)]
    pub body: String,
    #[serde(flatten)]
    pub extra: BTreeMap<String, Value>,
}

impl Skill {
    /// Reads a `SKILL.md`. `folder` is its folder's name, which the skill's name must be (a skill
    /// without `name` takes it). The description is required.
    pub fn parse(folder: &str, text: &str) -> Result<Self, String> {
        let (mut skill, body): (Self, String) = read_doc(text, None)?;
        if skill.name.is_empty() {
            skill.name = folder.into();
        }
        skill.body = body;
        if !crate::agents::valid_skill_name(&skill.name) {
            return Err(format!(
                "the skill name {:?} is not allowed: use up to 64 lowercase letters, digits and dashes.",
                skill.name
            ));
        }
        if skill.name != folder {
            return Err(format!(
                "the skill's name {:?} must be the name of its folder, {folder:?}.",
                skill.name
            ));
        }
        if skill.description.trim().is_empty() {
            return Err("it has no description in its front matter, so the Imp could not know when to use it.".into());
        }
        Ok(skill)
    }

    pub fn to_markdown(&self) -> String {
        write_doc(self, &self.body)
    }
}

// Commands

/// A command: `commands/NAME.md`, run as `/NAME …`. The body is the message to send.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
pub struct Command {
    #[serde(skip)]
    pub name: String,
    #[serde(skip)]
    pub template: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub description: Option<String>,
    /// The agent that runs it.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub agent: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub model: Option<String>,
    /// Runs in a chat of its own.
    #[serde(default, skip_serializing_if = "is_false")]
    pub subtask: bool,
    #[serde(flatten)]
    pub extra: BTreeMap<String, Value>,
}

impl Command {
    pub fn parse(name: &str, text: &str) -> Result<Self, String> {
        let (mut command, body): (Self, String) = read_doc(text, None)?;
        if !valid_agent_name(name) {
            return Err(format!(
                "the command name {name:?} is not allowed: use 1 to 32 letters, digits, - and _."
            ));
        }
        command.name = name.into();
        command.template = body;
        Ok(command)
    }

    pub fn to_markdown(&self) -> String {
        write_doc(self, &self.template)
    }

    /// The message for `/name arguments`: `$ARGUMENTS` is all of `arguments`, `$1`, `$2`… are its
    /// words (nothing for a missing one). `` !`cmd` `` and `@path` are left for the caller, which
    /// needs the shell and the files.
    pub fn message(&self, arguments: &str) -> String {
        let words: Vec<&str> = arguments.split_whitespace().collect();
        let mut out = String::new();
        let mut rest = self.template.as_str();
        while let Some(at) = rest.find('$') {
            out.push_str(&rest[..at]);
            let after = &rest[at + 1..];
            if let Some(tail) = after.strip_prefix("ARGUMENTS") {
                out.push_str(arguments.trim());
                rest = tail;
                continue;
            }
            let digits = after.chars().take_while(char::is_ascii_digit).count();
            match after[..digits].parse::<usize>() {
                Ok(n) if n >= 1 => {
                    out.push_str(words.get(n - 1).copied().unwrap_or_default());
                    rest = &after[digits..];
                }
                _ => {
                    out.push('$');
                    rest = after;
                }
            }
        }
        out.push_str(rest);
        out
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::config::{Effect, Env};

    const AGENT: &str = "---\ndescription: Reviews changes\nmode: primary\nmodel: ollama/qwen3.8#high\ncolor: \"#e0533d\"\nsteps: 40\npermissions:\n- action: triggers\n  resource: '*'\n  effect: deny\nrequest:\n  headers:\n    X-Gateway-Tenant: engineering\nfuture: [1, 2]\n---\n\nReview the current changes.\n\nBe kind.\n";

    #[test]
    fn an_agent_reads_every_key() {
        let a = Agent::parse("review", AGENT).unwrap();
        assert_eq!(a.name, "review");
        assert_eq!(a.description.as_deref(), Some("Reviews changes"));
        assert_eq!(a.mode(), Mode::Primary);
        assert_eq!(a.color.as_deref(), Some("#e0533d"));
        assert_eq!(a.steps, Some(40));
        assert_eq!(a.permissions, [Rule::new("triggers", "*", Effect::Deny)]);
        assert_eq!(
            a.request.as_ref().unwrap().headers["X-Gateway-Tenant"],
            "engineering"
        );
        assert_eq!(a.body, "Review the current changes.\n\nBe kind.");
        assert_eq!(a.prompt(), a.body);
        assert!(a.problems().is_empty());
        assert!(a.is_imp());
        assert!(a.extra.contains_key("future"));
    }

    #[test]
    fn an_agent_round_trips() {
        let a = Agent::parse("review", AGENT).unwrap();
        let text = a.to_markdown();
        assert_eq!(Agent::parse("review", &text).unwrap(), a);
        assert_eq!(Agent::parse("review", &text).unwrap().to_markdown(), text);
        assert!(text.starts_with("---\ndescription: Reviews changes\nmode: primary\n"));
        assert!(
            text.ends_with("\n---\n\nReview the current changes.\n\nBe kind.\n")
                || text.contains("---\n\nReview")
        );
    }

    #[test]
    fn bodies_and_empty_front_matter() {
        let a = Agent::parse("x", "Just a prompt.\n").unwrap();
        assert_eq!(
            a,
            Agent {
                name: "x".into(),
                body: "Just a prompt.".into(),
                ..Agent::default()
            }
        );
        assert_eq!(a.to_markdown(), "---\n---\n\nJust a prompt.\n");
        assert_eq!(Agent::parse("x", &a.to_markdown()).unwrap(), a);
        let b = Agent::parse("x", "---\r\nmode: subagent\r\n---\r\nbody\r\n").unwrap();
        assert_eq!((b.mode(), b.body.as_str()), (Mode::Subagent, "body"));
        assert!(!b.is_imp());
        let c = Agent::parse("x", "---\nsystem: from front\n---\n").unwrap();
        assert_eq!(c.prompt(), "from front");
        assert_eq!(Agent::parse("x", "").unwrap().to_markdown(), "---\n---\n");
        // A body that holds --- lines and indentation stays.
        let tricky = Agent {
            name: "x".into(),
            body: "a\n---\n  indented\n```\n".trim_end().into(),
            ..Agent::default()
        };
        assert_eq!(Agent::parse("x", &tricky.to_markdown()).unwrap(), tricky);
    }

    #[test]
    fn bad_files_say_why() {
        assert!(
            Agent::parse("x", "---\nmode: boss\n---\n")
                .unwrap_err()
                .contains("does not fit")
        );
        assert!(Agent::parse("x", "---\nsteps: many\n---\n").is_err());
        assert!(
            Agent::parse("x", "---\nkey: [unclosed\n---\n")
                .unwrap_err()
                .contains("not valid")
        );
        assert!(
            Agent::parse("x", "---\nmode: all\n")
                .unwrap_err()
                .contains("not closed")
        );
        let a = Agent {
            name: "bad name".into(),
            model: Some("nope".into()),
            color: Some("red".into()),
            steps: Some(0),
            ..Agent::default()
        };
        assert_eq!(a.problems().len(), 4);
    }

    #[test]
    fn front_matter_is_filled_and_the_body_is_not() {
        let dir = tempfile::tempdir().unwrap();
        std::fs::write(dir.path().join("tenant"), "acme\n").unwrap();
        let env = Env::new(&[("M", "p/m")], None);
        let text = "---\nmodel: '{env:M}#low'\nrequest:\n  headers:\n    T: '{file:tenant}'\n    U: '{env:NOPE}'\n---\n{env:M} stays\n";
        let mut problems = Vec::new();
        let a = Agent::parse_filled("x", text, dir.path(), &env, &mut problems).unwrap();
        assert_eq!(a.model.as_deref(), Some("p/m#low"));
        assert_eq!(a.request.as_ref().unwrap().headers["T"], "acme");
        assert_eq!(a.request.unwrap().headers["U"], "");
        assert_eq!(a.body, "{env:M} stays");
        assert_eq!(problems.len(), 1);
        // The raw read keeps the references, so a change written back does not bake in a secret.
        assert_eq!(
            Agent::parse("x", text).unwrap().model.as_deref(),
            Some("{env:M}#low")
        );
    }

    #[test]
    fn the_model_comes_from_the_agent_or_the_default() {
        let mut a = Agent::default();
        assert_eq!(a.model_ref(None).unwrap(), None);
        assert_eq!(
            a.model_ref(Some("p/m")).unwrap().unwrap().to_string(),
            "p/m"
        );
        a.variant = Some("high".into());
        assert_eq!(
            a.model_ref(Some("p/m#low")).unwrap().unwrap().to_string(),
            "p/m#high"
        );
        a.model = Some("q/n".into());
        assert_eq!(
            a.model_ref(Some("p/m")).unwrap().unwrap().to_string(),
            "q/n#high"
        );
        a.model = Some("bad".into());
        assert!(a.model_ref(None).is_err());
    }

    #[test]
    fn names() {
        for ok in ["a", "Pip", "my-agent_2"] {
            assert!(valid_agent_name(ok));
        }
        for bad in ["", "a b", "../x", "a/b", &"x".repeat(33), "é"] {
            assert!(!valid_agent_name(bad), "{bad}");
        }
        assert!(valid_color("#aB09ef") && !valid_color("#abc") && !valid_color("aabbcc1"));
    }

    #[test]
    fn skills() {
        let text = "---\nname: notes\ndescription: Take notes\nlicense: MIT\nallowed-tools: Read Bash\nmetadata:\n  author: me\nx-more: 1\n---\n\n# Notes\nStep one.\n";
        let s = Skill::parse("notes", text).unwrap();
        assert_eq!(
            (
                s.name.as_str(),
                s.license.as_deref(),
                s.allowed_tools.as_deref()
            ),
            ("notes", Some("MIT"), Some("Read Bash"))
        );
        assert_eq!(s.body, "# Notes\nStep one.");
        assert_eq!(Skill::parse("notes", &s.to_markdown()).unwrap(), s);
        assert!(s.to_markdown().contains("allowed-tools: Read Bash"));
        assert!(
            Skill::parse("other", text)
                .unwrap_err()
                .contains("name of its folder")
        );
        assert!(
            Skill::parse("Bad_Name", "---\ndescription: d\n---\n")
                .unwrap_err()
                .contains("not allowed")
        );
        assert!(
            Skill::parse("n", "---\ndescription: '  '\n---\n")
                .unwrap_err()
                .contains("no description")
        );
        assert!(Skill::parse("n", "---\nname: n\n---\n").is_err());
        assert_eq!(
            Skill::parse("n", "---\ndescription: d\n---\n")
                .unwrap()
                .name,
            "n"
        );
    }

    #[test]
    fn commands() {
        let text = "---\ndescription: Fix it\nagent: review\nmodel: p/m\nsubtask: true\n---\nFix $1 in $2 ($ARGUMENTS) $3 $x $0 $\n";
        let c = Command::parse("fix", text).unwrap();
        assert_eq!((c.agent.as_deref(), c.subtask), (Some("review"), true));
        assert_eq!(Command::parse("fix", &c.to_markdown()).unwrap(), c);
        assert_eq!(
            c.message("bug  src/a.rs"),
            "Fix bug in src/a.rs (bug  src/a.rs)  $x $0 $"
        );
        assert_eq!(c.message(""), "Fix  in  ()  $x $0 $");
        assert!(Command::parse("../x", "").is_err());
    }
}
