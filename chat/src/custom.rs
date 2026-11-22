//! Custom commands in the terminal app: `commands/NAME.md` in `~/.agents` and in a folder's `.agents`, run as
//! `/NAME arguments`. What a command is and how its text is split and filled in is `imp_engine::custom`
//! (the apps use it too). Here the shell and the files are reached: `` !`cmd` `` is replaced by what the
//! command prints (the `shell` permission, with the command line as the resource) and `@path` by the
//! file's contents (the `read` permission). The front matter says who runs it: `agent` (that Imp), `model`
//! (for this message only) and `subtask` (a conversation of its own, whose answer is shown and not kept).
//! A built-in command of the same name always wins.

use crate::gate::Gate;
use crate::grammar;
use imp_engine::BoxFuture;
use imp_engine::config::Command;
use imp_engine::custom::{self, Piece};
use std::path::{Path, PathBuf};
use std::rc::Rc;
use std::time::Duration;

pub use imp_engine::custom::{about, takes_arguments, usage};

/// How long a command inside a template may run.
const SHELL_TIMEOUT: Duration = Duration::from_secs(60);

/// What the templates reach out to: the shell and the files, each behind the Imp's permission rules.
pub trait World {
    /// What the command line prints. `Err` is a sentence for the person: not allowed, or it did not run.
    fn shell<'a>(&'a self, line: &'a str) -> BoxFuture<'a, Result<String, String>>;
    /// The contents of the file `path` names, or `None` when it names no file (the text stays as it is).
    fn read<'a>(&'a self, path: &'a str) -> BoxFuture<'a, Result<Option<String>, String>>;
}

/// A command ready to run: its message with everything filled in, and who is to run it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Prepared {
    pub text: String,
    pub agent: Option<String>,
    pub model: Option<String>,
    pub subtask: bool,
}

/// The custom command a line names, and the arguments after it. None for any other line, and for a name a
/// built-in command has.
pub fn find<'a>(line: &'a str, commands: &'a [Command]) -> Option<(&'a Command, &'a str)> {
    custom::find(line, commands, |word| grammar::find(word).is_some())
}

/// Fills in a command for the arguments, and runs what its text asks for. Nothing is sent anywhere: a
/// command or a file that is not allowed is the error.
pub async fn prepare(
    command: &Command,
    arguments: &str,
    world: &dyn World,
) -> Result<Prepared, String> {
    let plan = custom::plan(command, arguments);
    Ok(Prepared {
        text: expand(&plan.pieces, world).await?,
        agent: plan.agent,
        model: plan.model,
        subtask: plan.subtask,
    })
}

/// Runs the pieces, one after the other, and puts the text together.
async fn expand(pieces: &[Piece], world: &dyn World) -> Result<String, String> {
    let mut answers = Vec::with_capacity(pieces.len());
    for piece in pieces {
        answers.push(match piece {
            Piece::Text(_) => None,
            Piece::Shell(line) => Some(world.shell(line).await?),
            Piece::File(path) => world.read(path).await?,
        });
    }
    Ok(custom::fill(pieces, &answers))
}

/// The shell and the files of this computer, as the Imp's rules allow.
pub struct Local {
    pub gate: Rc<Gate>,
    pub workspace: PathBuf,
    pub home: Option<PathBuf>,
}

impl Local {
    fn resolve(&self, path: &str) -> PathBuf {
        let path = match (path.strip_prefix("~/"), &self.home) {
            (Some(rest), Some(home)) => home.join(rest),
            _ => PathBuf::from(path),
        };
        if path.is_absolute() {
            path
        } else {
            self.workspace.join(path)
        }
    }
}

impl World for Local {
    fn shell<'a>(&'a self, line: &'a str) -> BoxFuture<'a, Result<String, String>> {
        Box::pin(async move {
            self.gate.check("shell", line).await?;
            let run = tokio::process::Command::new("sh")
                .arg("-c")
                .arg(line)
                .current_dir(&self.workspace)
                .stdin(std::process::Stdio::null())
                .kill_on_drop(true)
                .output();
            let output = tokio::time::timeout(SHELL_TIMEOUT, run)
                .await
                .map_err(|_| format!("`{line}` took longer than a minute."))?
                .map_err(|e| format!("`{line}` did not start: {e}"))?;
            let mut text = String::from_utf8_lossy(&output.stdout).into_owned();
            text.push_str(&String::from_utf8_lossy(&output.stderr));
            Ok(text)
        })
    }

    fn read<'a>(&'a self, path: &'a str) -> BoxFuture<'a, Result<Option<String>, String>> {
        Box::pin(async move {
            let full = self.resolve(path);
            if !Path::new(&full).is_file() {
                return Ok(None);
            }
            self.gate.check("read", &full.display().to_string()).await?;
            let bytes = tokio::fs::read(&full)
                .await
                .map_err(|e| format!("{path} could not be read: {e}"))?;
            Ok(Some(String::from_utf8_lossy(&bytes).into_owned()))
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::cell::RefCell;

    /// Answers like a computer with one file and a shell that prints what it was asked for.
    #[derive(Default)]
    struct Fake {
        asked: RefCell<Vec<String>>,
        deny: bool,
    }

    impl World for Fake {
        fn shell<'a>(&'a self, line: &'a str) -> BoxFuture<'a, Result<String, String>> {
            Box::pin(async move {
                self.asked.borrow_mut().push(format!("shell {line}"));
                if self.deny {
                    return Err(format!("Not allowed: shell {line}."));
                }
                Ok(format!("<{line}>\n"))
            })
        }

        fn read<'a>(&'a self, path: &'a str) -> BoxFuture<'a, Result<Option<String>, String>> {
            Box::pin(async move {
                self.asked.borrow_mut().push(format!("read {path}"));
                Ok((path == "src/a.rs").then(|| "fn a() {}\n".to_string()))
            })
        }
    }

    fn command(text: &str) -> Command {
        Command::parse("go", text).unwrap()
    }

    fn block<T>(future: impl std::future::Future<Output = T>) -> T {
        tokio::runtime::Builder::new_current_thread()
            .build()
            .unwrap()
            .block_on(future)
    }

    #[test]
    fn arguments_fill_in_and_shell_and_files_are_read() {
        let c = command(
            "Review $1 (all: $ARGUMENTS)\nBranch: !`git branch --show-current`\nSee @src/a.rs.\n",
        );
        let world = Fake::default();
        let p = block(prepare(&c, "src/a.rs now", &world)).unwrap();
        assert_eq!(
            p.text,
            "Review src/a.rs (all: src/a.rs now)\nBranch: <git branch --show-current>\nSee <file path=\"src/a.rs\">\nfn a() {}\n</file>."
        );
        assert_eq!(
            *world.asked.borrow(),
            ["shell git branch --show-current", "read src/a.rs"]
        );
    }

    #[test]
    fn what_comes_back_is_not_read_as_a_template() {
        // The shell prints `@src/a.rs` and `!`x``: neither is looked at again.
        struct Echo;
        impl World for Echo {
            fn shell<'a>(&'a self, _: &'a str) -> BoxFuture<'a, Result<String, String>> {
                Box::pin(async { Ok("@src/a.rs !`rm -rf /`".to_string()) })
            }
            fn read<'a>(&'a self, _: &'a str) -> BoxFuture<'a, Result<Option<String>, String>> {
                Box::pin(async { panic!("read what a command printed") })
            }
        }
        let out = block(expand(&custom::pieces("x !`echo`"), &Echo)).unwrap();
        assert_eq!(out, "x @src/a.rs !`rm -rf /`");
    }

    #[test]
    fn a_command_that_is_not_allowed_stops_the_message() {
        let c = command("Status: !`git status`");
        let world = Fake {
            deny: true,
            ..Fake::default()
        };
        let err = block(prepare(&c, "", &world)).unwrap_err();
        assert!(err.contains("Not allowed: shell git status"), "{err}");
    }

    #[test]
    fn the_front_matter_says_who_runs_it() {
        let c =
            command("---\nagent: review\nmodel: ollama/qwen3#high\nsubtask: true\n---\nLook at $1");
        let p = block(prepare(&c, "x", &Fake::default())).unwrap();
        assert_eq!(p.text, "Look at x");
        assert_eq!(p.agent.as_deref(), Some("review"));
        assert_eq!(p.model.as_deref(), Some("ollama/qwen3#high"));
        assert!(p.subtask);
    }

    #[test]
    fn a_built_in_name_is_never_a_custom_command() {
        let commands = vec![
            Command::parse("review", "Review $ARGUMENTS").unwrap(),
            Command::parse("model", "never").unwrap(),
        ];
        let (c, args) = find("/review  src/auth.rs ", &commands).unwrap();
        assert_eq!((c.name.as_str(), args), ("review", "src/auth.rs"));
        assert!(find("/model gpt", &commands).is_none(), "a built-in wins");
    }
}
