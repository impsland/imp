//! The rules around the shared `.agents/` layout that are not about the files themselves (those are in
//! `config`): a skill's name and description for the system text, what goes in the system text (the
//! `AGENTS.md` instructions and the list of skills), and the `use_skill` tool.
//!
//! Finding the folders and reading the files is `config::load`. The vectors are
//! `spec/fixtures/agents.json`.

use crate::chat::ToolSpec;
use crate::config::doc::{Skill, split_front_matter};
use serde_json::json;

/// The most bytes of `AGENTS.md` text put in the system text, all files together.
pub const MOST_INSTRUCTIONS: usize = 32 * 1024;
/// The most skills listed in the system text.
pub const MOST_SKILLS: usize = 100;
/// The tool that reads a skill, and its group (for switching it off: `own.skills.use_skill`).
pub const SKILL_TOOL: &str = "use_skill";
pub const SKILL_GROUP: &str = "skills";
/// The longest skill description kept, in characters.
pub(crate) const MOST_DESCRIPTION: usize = 1024;

// Names and values.

/// Whether `name` can be an environment variable name. This also keeps a pasted key out of a file.
pub fn valid_env_name(name: &str) -> bool {
    let mut chars = name.chars();
    chars
        .next()
        .is_some_and(|c| c.is_ascii_alphabetic() || c == '_')
        && chars.all(|c| c.is_ascii_alphanumeric() || c == '_')
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

/// A skill as the system text lists it: its name and when to use it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SkillSpec {
    pub name: String,
    pub description: String,
}

impl SkillSpec {
    /// Reads a `SKILL.md` (see [`Skill::parse`]). Its description is one line, cut at
    /// [`MOST_DESCRIPTION`] characters.
    pub fn parse(folder: &str, text: &str) -> Result<Self, String> {
        Skill::parse(folder, text).map(|s| Self::from(&s))
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
    let body = split_front_matter(text).map_or(text, |(_, body)| body);
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
#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::Value;

    fn fixture() -> Value {
        serde_json::from_str(include_str!("../../spec/fixtures/agents.json")).unwrap()
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
    fn names() {
        assert!(valid_env_name("IMP_API_KEY") && !valid_env_name("1ABC") && !valid_env_name(""));
        assert!(
            valid_skill_name("pdf-notes") && !valid_skill_name("Pdf") && !valid_skill_name("a--b")
        );
    }
}
