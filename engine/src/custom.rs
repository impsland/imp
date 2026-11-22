//! Custom commands, the rules every app shares: `commands/NAME.md` in `~/.agents` and in a folder's
//! `.agents`, run as `/NAME arguments`. The file's text is the message. Finding the command a line names,
//! how the list words it, and the plan for a run live here. Reaching out to the shell and the files does
//! not: the app does that behind the Imp's permission rules (`shell` with the command line as the resource,
//! `read` with the path) and hands the answers to [`fill`].
//!
//! In the text `$ARGUMENTS` and `$1` to `$9` are filled in by `Command::message`, `` !`cmd` `` is replaced
//! by what the command prints and `@path` by the file's contents. What comes back from a command or a file
//! is never read as a template: the text is split once, by [`pieces`].

use crate::config::Command;

/// The most a file or the output of a command adds to a message.
pub const MOST_BYTES: usize = 100_000;

/// A part of a filled-in command text.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Piece {
    /// Text that stays as it is.
    Text(String),
    /// A command line to run (`` !`line` ``): the text becomes what it prints.
    Shell(String),
    /// A word that starts with `@`: the text becomes the file's contents, and stays as typed when the
    /// word names no file.
    File(String),
}

/// A command ready to run: its text in pieces, and who is to run it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Plan {
    pub pieces: Vec<Piece>,
    pub agent: Option<String>,
    pub model: Option<String>,
    pub subtask: bool,
}

/// The custom command a line names, and the arguments after it. None for any other line, and for a name
/// `is_built_in` says a built-in command has (that one always wins).
pub fn find<'a>(
    line: &'a str,
    commands: &'a [Command],
    is_built_in: impl Fn(&str) -> bool,
) -> Option<(&'a Command, &'a str)> {
    let t = line.trim();
    let (first, rest) = t.split_once(char::is_whitespace).unwrap_or((t, ""));
    let name = first.strip_prefix('/')?;
    if is_built_in(first) {
        return None;
    }
    let command = commands.iter().find(|c| c.name == name)?;
    Some((command, rest.trim()))
}

/// How a custom command is written in the list: its name, and its arguments when the text takes them.
pub fn usage(c: &Command) -> String {
    if takes_arguments(c) {
        format!("/{} ARGUMENTS", c.name)
    } else {
        format!("/{}", c.name)
    }
}

pub fn takes_arguments(c: &Command) -> bool {
    c.template.contains("$ARGUMENTS") || (1..=9).any(|n| c.template.contains(&format!("${n}")))
}

/// What the list says about it: its description, or the first line of its text.
pub fn about(c: &Command) -> String {
    c.description.clone().unwrap_or_else(|| {
        c.template
            .lines()
            .map(str::trim)
            .find(|l| !l.is_empty())
            .unwrap_or("")
            .to_string()
    })
}

/// The plan for `/name arguments`: the arguments filled in, and the text split into pieces.
pub fn plan(command: &Command, arguments: &str) -> Plan {
    Plan {
        pieces: pieces(&command.message(arguments)),
        agent: command.agent.clone(),
        model: command.model.clone(),
        subtask: command.subtask,
    }
}

/// Splits a text at `` !`cmd` `` and at a word that starts with `@` (after white space or at the start).
/// Trailing punctuation is not part of the path.
pub fn pieces(text: &str) -> Vec<Piece> {
    let mut out = Vec::new();
    let mut plain = String::new();
    let mut at = 0;
    while at < text.len() {
        let rest = &text[at..];
        if let Some(inner) = rest.strip_prefix("!`")
            && let Some(end) = inner.find('`')
        {
            let line = inner[..end].trim();
            if !line.is_empty() {
                if !plain.is_empty() {
                    out.push(Piece::Text(std::mem::take(&mut plain)));
                }
                out.push(Piece::Shell(line.to_string()));
                at += 3 + end;
                continue;
            }
        }
        if rest.starts_with('@')
            && text[..at]
                .chars()
                .next_back()
                .is_none_or(char::is_whitespace)
        {
            let word = rest[1..].split(char::is_whitespace).next().unwrap_or("");
            let path = word.trim_end_matches([',', '.', ';', ':', '!', '?', ')', ']', '"', '\'']);
            if !path.is_empty() {
                if !plain.is_empty() {
                    out.push(Piece::Text(std::mem::take(&mut plain)));
                }
                out.push(Piece::File(path.to_string()));
                at += 1 + path.len();
                continue;
            }
        }
        let ch = rest.chars().next().expect("not at the end");
        plain.push(ch);
        at += ch.len_utf8();
    }
    if !plain.is_empty() {
        out.push(Piece::Text(plain));
    }
    out
}

/// The text again, with what each piece came to: `answers` has one entry per piece, `Some(output)` for a
/// command that ran, `Some(contents)` for a file that was read and `None` for a word that names no file
/// (and for the plain text). A missing entry is a `None`.
pub fn fill(pieces: &[Piece], answers: &[Option<String>]) -> String {
    let mut out = String::new();
    for (i, piece) in pieces.iter().enumerate() {
        let answer = answers.get(i).and_then(Option::as_deref);
        match (piece, answer) {
            (Piece::Text(text), _) => out.push_str(text),
            (Piece::Shell(_), answer) => out.push_str(clip(answer.unwrap_or_default()).trim_end()),
            (Piece::File(path), Some(content)) => out.push_str(&format!(
                "<file path=\"{path}\">\n{}\n</file>",
                clip(content).trim_end()
            )),
            (Piece::File(path), None) => {
                out.push('@');
                out.push_str(path);
            }
        }
    }
    out
}

/// At most [`MOST_BYTES`], cut at a character.
fn clip(text: &str) -> String {
    if text.len() <= MOST_BYTES {
        return text.to_string();
    }
    let mut end = MOST_BYTES;
    while !text.is_char_boundary(end) {
        end -= 1;
    }
    format!("{}\n[cut]", &text[..end])
}

/// The sentence for a `` !`line` `` on a device that has no shell (the phone).
pub fn no_shell(line: &str) -> String {
    format!("`{line}` can't run here: this device has no shell.")
}

#[cfg(test)]
mod tests {
    use super::*;

    fn command(text: &str) -> Command {
        Command::parse("go", text).unwrap()
    }

    #[test]
    fn the_text_is_split_at_commands_and_files() {
        let p = pieces("Branch: !`git branch`\nSee @src/a.rs.\n");
        assert_eq!(
            p,
            [
                Piece::Text("Branch: ".into()),
                Piece::Shell("git branch".into()),
                Piece::Text("\nSee ".into()),
                Piece::File("src/a.rs".into()),
                Piece::Text(".\n".into()),
            ]
        );
        let answers = [
            None,
            Some("main\n".to_string()),
            None,
            Some("fn a() {}\n".to_string()),
            None,
        ];
        assert_eq!(
            fill(&p, &answers),
            "Branch: main\nSee <file path=\"src/a.rs\">\nfn a() {}\n</file>.\n"
        );
    }

    #[test]
    fn mentions_of_things_that_are_not_files_stay() {
        let p = pieces("mail me@home, @nobody and @ alone, !`");
        assert_eq!(
            p,
            [
                Piece::Text("mail me@home, ".into()),
                Piece::File("nobody".into()),
                Piece::Text(" and @ alone, !`".into()),
            ]
        );
        assert_eq!(fill(&p, &[]), "mail me@home, @nobody and @ alone, !`");
        assert_eq!(pieces(""), []);
        assert_eq!(pieces("!` `"), [Piece::Text("!` `".into())]);
    }

    #[test]
    fn what_a_piece_came_to_is_not_split_again() {
        // The pieces are made before anything runs, so a command that prints `@a` stays text.
        let p = pieces("x !`echo`");
        assert_eq!(
            fill(&p, &[None, Some("@src/a.rs !`rm`".into())]),
            "x @src/a.rs !`rm`"
        );
    }

    #[test]
    fn long_answers_are_cut_at_a_character() {
        let p = [Piece::Shell("x".into())];
        let long = "é".repeat(MOST_BYTES);
        let out = fill(&p, &[Some(long)]);
        assert!(out.ends_with("\n[cut]") && out.len() <= MOST_BYTES + 6);
    }

    #[test]
    fn the_front_matter_says_who_runs_it() {
        let c =
            command("---\nagent: review\nmodel: ollama/qwen3#high\nsubtask: true\n---\nLook at $1");
        let p = plan(&c, "x");
        assert_eq!(p.pieces, [Piece::Text("Look at x".into())]);
        assert_eq!(p.agent.as_deref(), Some("review"));
        assert_eq!(p.model.as_deref(), Some("ollama/qwen3#high"));
        assert!(p.subtask);
    }

    #[test]
    fn a_line_names_a_custom_command_unless_a_built_in_has_the_name() {
        let commands = vec![
            Command::parse("review", "Review $ARGUMENTS").unwrap(),
            Command::parse("model", "never").unwrap(),
        ];
        let built_in = |name: &str| name == "/model";
        let (c, args) = find("/review  src/auth.rs ", &commands, built_in).unwrap();
        assert_eq!((c.name.as_str(), args), ("review", "src/auth.rs"));
        assert!(find("/model gpt", &commands, built_in).is_none());
        assert!(find("/unknown", &commands, built_in).is_none());
        assert!(find("review", &commands, built_in).is_none());
        assert_eq!(usage(&commands[0]), "/review ARGUMENTS");
        assert_eq!(usage(&command("Plain")), "/go");
        assert_eq!(usage(&command("Look at $2")), "/go ARGUMENTS");
        assert_eq!(about(&commands[0]), "Review $ARGUMENTS");
        let described = command("---\ndescription: Does it\n---\nbody");
        assert_eq!(about(&described), "Does it");
    }
}
