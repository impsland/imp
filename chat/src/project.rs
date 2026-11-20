//! What a folder adds to a chat, beyond the configuration (`crate::settings`): the skills the Imp can read
//! with the `use_skill` tool, and the custom commands the folder (or `~/.agents`) offers. The files are found
//! and read by `imp_engine::config::load`.

use imp_engine::agents::{self, SKILL_GROUP};
use imp_engine::config::{Command, Loaded, Skill, Sourced};
use imp_engine::{BoxFuture, HostTool, ToolEntry, ToolHost};
use serde_json::Value;
use std::path::{Path, PathBuf};

pub use imp_engine::agents::SKILL_TOOL;

/// The custom commands of `~/.agents` and the folder, as `commands/NAME.md` files define them.
pub fn custom_commands(loaded: &Loaded) -> Vec<Command> {
    loaded.commands.values().map(|c| c.value.clone()).collect()
}

/// A path for people: `~/...` inside the home folder.
pub fn shown_path(path: &Path) -> String {
    if let Some(home) = directories::BaseDirs::new()
        && let Ok(rest) = path.strip_prefix(home.home_dir())
    {
        return if rest.as_os_str().is_empty() {
            "~".into()
        } else {
            format!("~/{}", rest.display())
        };
    }
    path.display().to_string()
}

/// The skills as a tool.
pub struct SkillHost {
    skills: Vec<(String, PathBuf)>,
}

impl SkillHost {
    pub fn new(skills: &std::collections::BTreeMap<String, Sourced<Skill>>) -> Option<Self> {
        (!skills.is_empty()).then(|| Self {
            skills: skills
                .values()
                .map(|s| (s.value.name.clone(), s.path.clone()))
                .collect(),
        })
    }

    /// The text the tool returns for a skill.
    pub fn read(&self, name: &str) -> String {
        let Some((_, path)) = self.skills.iter().find(|(n, _)| n == name) else {
            let names: Vec<&str> = self.skills.iter().map(|(n, _)| n.as_str()).collect();
            return format!(
                "Error: there is no skill {name}. The skills are: {}.",
                names.join(", ")
            );
        };
        let text = match std::fs::read_to_string(path) {
            Ok(t) => t,
            Err(e) => return format!("Error: could not read {}: {e}", path.display()),
        };
        let folder = path.parent().unwrap_or(Path::new("."));
        agents::skill_text(
            name,
            &folder.display().to_string(),
            &text,
            &skill_files(folder),
        )
    }
}

fn sorted_entries(dir: &Path) -> Vec<PathBuf> {
    let mut all: Vec<PathBuf> = std::fs::read_dir(dir)
        .map(|rd| rd.filter_map(|e| e.ok().map(|e| e.path())).collect())
        .unwrap_or_default();
    all.sort();
    all
}

/// The files in a skill's folder (not `SKILL.md`), a few levels down and no more than 50.
fn skill_files(folder: &Path) -> Vec<String> {
    let mut out = Vec::new();
    let mut stack = vec![folder.to_path_buf()];
    while let Some(dir) = stack.pop() {
        for path in sorted_entries(&dir) {
            if out.len() >= 50 {
                return out;
            }
            let hidden = path
                .file_name()
                .is_some_and(|n| n.to_string_lossy().starts_with('.'));
            if hidden {
                continue;
            }
            if path.is_dir() {
                if path
                    .strip_prefix(folder)
                    .map_or(0, |r| r.components().count())
                    < 3
                {
                    stack.push(path);
                }
            } else if let Ok(rel) = path.strip_prefix(folder)
                && rel != Path::new("SKILL.md")
            {
                out.push(rel.display().to_string());
            }
        }
    }
    out
}

impl ToolHost for SkillHost {
    fn tools(&self) -> Vec<HostTool> {
        let names: Vec<String> = self.skills.iter().map(|(n, _)| n.clone()).collect();
        vec![HostTool {
            entry: Some(ToolEntry::own(SKILL_GROUP, SKILL_TOOL)),
            spec: agents::skill_tool(&names),
        }]
    }

    fn call<'a>(&'a self, name: &'a str, arguments: &'a str) -> BoxFuture<'a, Option<String>> {
        Box::pin(async move {
            if name != SKILL_TOOL {
                return None;
            }
            let args: Value = serde_json::from_str(arguments).unwrap_or(Value::Null);
            Some(match args.get("name").and_then(Value::as_str) {
                Some(skill) => self.read(skill),
                None => "Error: use_skill needs the `name` of a skill.".into(),
            })
        })
    }
}
