//! Skills and custom commands for the apps' chats (`docs/apps/skills-commands.md`): the same rules as the
//! terminal app, from `imp_engine::agents` and `imp_engine::custom`. The skills are listed in the system
//! text and read by the `use_skill` tool. A typed `/name arguments` line becomes a plan: the command's
//! text in pieces, where a command line or a file is for the app to run behind the Imp's permission
//! rules (`shell`, `read`) and [`command_fill`] puts the text together again.

use crate::config::{ConfigPaths, env_for};
use imp_engine::agents::{self, SkillHost};
use imp_engine::config::{self, Command, Loaded, TrustStore};
use imp_engine::custom::{self, Piece};

fn loaded(paths: &ConfigPaths) -> Loaded {
    config::load(&env_for(paths), None, &TrustStore::default())
}

/// What goes after who the Imp is in the system text: the list of skills. Empty without skills.
#[uniffi::export]
pub fn skills_prompt(paths: ConfigPaths) -> String {
    let skills: Vec<agents::SkillSpec> = loaded(&paths)
        .skills
        .values()
        .map(|s| agents::SkillSpec::from(&s.value))
        .collect();
    agents::prompt(&[], &skills)
}

/// The `use_skill` tool as the model is offered it.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct SkillTool {
    pub name: String,
    pub description: String,
    /// The JSON schema of its arguments.
    pub parameters_json: String,
}

/// The tool for the skills there are, or `None` without skills (then there is no tool).
#[uniffi::export]
pub fn skills_tool(paths: ConfigPaths) -> Option<SkillTool> {
    let spec = SkillHost::new(&loaded(&paths).skills)?.spec();
    Some(SkillTool {
        name: spec.name,
        description: spec.description,
        parameters_json: spec.parameters.to_string(),
    })
}

/// What the tool answers to a call with these JSON arguments: the skill's text, or a sentence that says
/// what went wrong.
#[uniffi::export]
pub fn skills_answer(paths: ConfigPaths, arguments_json: String) -> String {
    match SkillHost::new(&loaded(&paths).skills) {
        Some(host) => host.answer(&arguments_json),
        None => "Error: there are no skills.".into(),
    }
}

/// A custom command as the list in the chat shows it.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct CommandEntry {
    pub name: String,
    /// `/name`, and `ARGUMENTS` when its text takes them.
    pub usage: String,
    pub about: String,
    pub takes_arguments: bool,
}

impl From<&Command> for CommandEntry {
    fn from(c: &Command) -> Self {
        Self {
            name: c.name.clone(),
            usage: custom::usage(c),
            about: custom::about(c),
            takes_arguments: custom::takes_arguments(c),
        }
    }
}

/// The custom commands, by name.
#[uniffi::export]
pub fn commands_list(paths: ConfigPaths) -> Vec<CommandEntry> {
    loaded(&paths)
        .commands
        .values()
        .map(|c| CommandEntry::from(&c.value))
        .collect()
}

/// A part of a command's text, for the app to resolve.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum CommandPiece {
    /// Stays as it is.
    Text { text: String },
    /// A command line to run behind the `shell` permission: the text becomes what it prints.
    Shell { line: String },
    /// A file to read behind the `read` permission (the path is as typed: `~/` is the home folder, a
    /// relative path is the app's own folder): the text becomes its contents. A word that names no file
    /// stays as typed, which is an answer of `None`.
    File { path: String },
}

impl From<Piece> for CommandPiece {
    fn from(p: Piece) -> Self {
        match p {
            Piece::Text(text) => Self::Text { text },
            Piece::Shell(line) => Self::Shell { line },
            Piece::File(path) => Self::File { path },
        }
    }
}

impl From<CommandPiece> for Piece {
    fn from(p: CommandPiece) -> Self {
        match p {
            CommandPiece::Text { text } => Self::Text(text),
            CommandPiece::Shell { line } => Self::Shell(line),
            CommandPiece::File { path } => Self::File(path),
        }
    }
}

/// A typed command, ready to run: who runs it and its text in pieces.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct CommandPlan {
    pub name: String,
    pub pieces: Vec<CommandPiece>,
    /// The Imp that answers, when the command names one.
    pub agent: Option<String>,
    /// The model for this message only.
    pub model: Option<String>,
    /// Answered in a conversation of its own, and not kept.
    pub subtask: bool,
}

/// The plan for a typed line, or `None` when the line does not name a custom command.
#[uniffi::export]
pub fn command_plan(paths: ConfigPaths, line: String) -> Option<CommandPlan> {
    let loaded = loaded(&paths);
    let commands: Vec<Command> = loaded.commands.values().map(|c| c.value.clone()).collect();
    let (command, arguments) = custom::find(&line, &commands, |_| false)?;
    let plan = custom::plan(command, arguments);
    Some(CommandPlan {
        name: command.name.clone(),
        pieces: plan.pieces.into_iter().map(Into::into).collect(),
        agent: plan.agent,
        model: plan.model,
        subtask: plan.subtask,
    })
}

/// The message again with what each piece came to: one answer per piece (see [`custom::fill`]).
#[uniffi::export]
pub fn command_fill(pieces: Vec<CommandPiece>, answers: Vec<Option<String>>) -> String {
    let pieces: Vec<Piece> = pieces.into_iter().map(Into::into).collect();
    custom::fill(&pieces, &answers)
}

/// The sentence for a command line on a device that has no shell.
#[uniffi::export]
pub fn command_no_shell(line: String) -> String {
    custom::no_shell(&line)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn paths(home: &std::path::Path) -> ConfigPaths {
        ConfigPaths {
            config_dir: home.join("config").display().to_string(),
            home_dir: home.display().to_string(),
        }
    }

    fn write(path: std::path::PathBuf, text: &str) {
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        std::fs::write(path, text).unwrap();
    }

    #[test]
    fn skills_and_commands_come_from_the_agents_folder() {
        let home = tempfile::tempdir().unwrap();
        let p = paths(home.path());
        assert_eq!(skills_prompt(p.clone()), "");
        assert!(skills_tool(p.clone()).is_none());
        assert!(commands_list(p.clone()).is_empty());

        let agents = home.path().join(".agents");
        write(
            agents.join("skills/notes/SKILL.md"),
            "---\nname: notes\ndescription: Take notes\n---\nStep one.",
        );
        write(
            agents.join("commands/review.md"),
            "---\ndescription: Review it\nagent: pip\nsubtask: true\n---\nLook at $1 !`git status` @a.rs",
        );
        assert!(skills_prompt(p.clone()).contains("- notes: Take notes"));
        let tool = skills_tool(p.clone()).unwrap();
        assert_eq!(tool.name, "use_skill");
        assert!(tool.parameters_json.contains("notes"));
        assert!(skills_answer(p.clone(), r#"{"name":"notes"}"#.into()).contains("Step one."));

        let list = commands_list(p.clone());
        assert_eq!(
            list,
            [CommandEntry {
                name: "review".into(),
                usage: "/review ARGUMENTS".into(),
                about: "Review it".into(),
                takes_arguments: true,
            }]
        );
        assert!(command_plan(p.clone(), "/other".into()).is_none());
        let plan = command_plan(p, "/review x".into()).unwrap();
        assert_eq!(plan.agent.as_deref(), Some("pip"));
        assert!(plan.subtask);
        assert_eq!(
            plan.pieces,
            [
                CommandPiece::Text {
                    text: "Look at x ".into()
                },
                CommandPiece::Shell {
                    line: "git status".into()
                },
                CommandPiece::Text { text: " ".into() },
                CommandPiece::File {
                    path: "a.rs".into()
                },
            ]
        );
        let text = command_fill(plan.pieces, vec![None, Some("clean\n".into()), None, None]);
        assert_eq!(text, "Look at x clean @a.rs");
    }
}
