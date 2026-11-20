//! What can be typed after a `/` in a chat. The commands that change the configuration are the command line's
//! (`imp agent`, `imp mcp`...): their words, forms and descriptions are read from the same clap grammar
//! (`crate::cli`) that parses them, so a chat can neither offer nor accept anything the command line does
//! not. The chat's own commands (`/help`, `/send`...) are listed here. Completion, hints and `/help` all use
//! this one table.

use crate::cli::Cli;
use clap::CommandFactory;
use std::sync::LazyLock;

/// One command, for `/help` and for completing what is typed.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Command {
    pub name: String,
    /// `/send DEVICE [IMP]`; for a command with several forms, `/mcp [list | add NAME ... | ...]`.
    pub usage: String,
    pub about: String,
    /// The ways to use a command that has several: its words, each with how it is written.
    pub forms: Vec<Choice>,
    /// Whether the name alone is enough to run it.
    pub bare: bool,
    /// Whether the command is the command line's, parsed by the same grammar as `imp NAME ...`.
    pub managed: bool,
}

/// One word that can follow a command, such as `add` after `/mcp`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Choice {
    pub word: String,
    /// The word and what follows it: `add NAME [--url URL]`.
    pub usage: String,
    pub about: String,
    /// Something more is expected after it.
    pub more: bool,
}

/// The commands of the command line a chat does not have: they need a terminal.
const TERMINAL_ONLY: &[&str] = &["edit"];

/// Whether a word of a command is the command line's alone, such as `imp agent edit`.
pub fn is_terminal_only(word: &str) -> bool {
    TERMINAL_ONLY.contains(&word)
}

/// The chat's own commands, and where the command line's go among them.
enum Slot {
    Own(&'static str, &'static str, &'static str),
    Managed(&'static str),
}

use Slot::{Managed, Own};

const LAYOUT: &[Slot] = &[
    Own("/help", "/help", "List these commands"),
    Own("/clear", "/clear", "Start the conversation over"),
    Own(
        "/compact",
        "/compact",
        "Sum up the chat, so a long one costs less",
    ),
    Own("/quit", "/quit", "Leave the chat (also /exit)"),
    Own(
        "/imp",
        "/imp [NAME]",
        "List the Imps, or talk to another one",
    ),
    Managed("model"),
    Managed("agent"),
    Managed("provider"),
    Managed("auth"),
    Managed("mcp"),
    Managed("permission"),
    Managed("skill"),
    Managed("command"),
    Managed("project"),
    Managed("config"),
    Own(
        "/tools",
        "/tools",
        "List the tools and whether the rules leave them on",
    ),
    Own(
        "/devices",
        "/devices",
        "List linked devices, the Imps on them and the visitors here",
    ),
    Own("/pair", "/pair", "Show a code to link a Mac or an iPhone"),
    Own(
        "/send",
        "/send DEVICE [IMP]",
        "Send this Imp (or another) to a linked device",
    ),
    Own(
        "/call",
        "/call [IMP]",
        "Bring an Imp back from another device",
    ),
    Own(
        "/return",
        "/return [VISITOR]",
        "Send a visiting Imp back to its home device",
    ),
    Own(
        "/trust",
        "/trust DEVICE [off]",
        "Let Imps use their tools for a device of yours",
    ),
    Own("/forget", "/forget DEVICE", "End the link with a device"),
];

/// Every command, in the order `/help` lists them.
pub static COMMANDS: LazyLock<Vec<Command>> = LazyLock::new(build);

fn build() -> Vec<Command> {
    let cli = Cli::command();
    LAYOUT
        .iter()
        .filter_map(|slot| match slot {
            Own(name, usage, about) => Some(Command {
                name: (*name).into(),
                usage: (*usage).into(),
                about: (*about).into(),
                forms: Vec::new(),
                bare: !needs_words(name, usage),
                managed: false,
            }),
            Managed(name) => cli.find_subcommand(name).map(managed),
        })
        .collect()
}

/// A command of the command line as a command of a chat.
fn managed(sub: &clap::Command) -> Command {
    let name = format!("/{}", sub.get_name());
    let forms: Vec<Choice> = sub
        .get_subcommands()
        .filter(|s| !TERMINAL_ONLY.contains(&s.get_name()) && !s.is_hide_set())
        .map(|s| {
            let usage = form(s);
            Choice {
                word: s.get_name().to_string(),
                more: s
                    .get_arguments()
                    .any(|a| a.is_required_set() && a.get_id() != "help"),
                about: about(s),
                usage,
            }
        })
        .collect();
    let bare = forms.is_empty()
        || !sub.is_subcommand_required_set()
        || forms.iter().any(|f| f.word == "list");
    let usage = if forms.is_empty() {
        let args = arguments(sub);
        if args.is_empty() {
            name.clone()
        } else {
            format!("{name} {args}")
        }
    } else {
        let all: Vec<&str> = forms.iter().map(|f| f.usage.as_str()).collect();
        format!("{name} [{}]", all.join(" | "))
    };
    Command {
        name,
        usage,
        about: about(sub),
        forms,
        bare,
        managed: true,
    }
}

fn about(sub: &clap::Command) -> String {
    sub.get_about().map(ToString::to_string).unwrap_or_default()
}

/// `add NAME [--url URL]`: the word and its arguments as they are written.
fn form(sub: &clap::Command) -> String {
    let args = arguments(sub);
    if args.is_empty() {
        sub.get_name().to_string()
    } else {
        format!("{} {args}", sub.get_name())
    }
}

/// The arguments of a command as a usage line: `NAME [DESCRIPTION] [--model MODEL]`.
fn arguments(sub: &clap::Command) -> String {
    let mut parts = Vec::new();
    let shown = |a: &&clap::Arg| !a.is_global_set() && !a.is_hide_set() && a.get_id() != "help";
    for a in sub
        .get_arguments()
        .filter(shown)
        .filter(|a| a.is_positional())
    {
        let value = a
            .get_value_names()
            .and_then(|v| v.first().map(ToString::to_string))
            .unwrap_or_else(|| a.get_id().as_str().to_uppercase());
        let many = a.get_num_args().is_some_and(|n| n.max_values() > 1);
        let value = if many { format!("{value}...") } else { value };
        parts.push(if a.is_required_set() {
            value
        } else {
            format!("[{value}]")
        });
    }
    for a in sub
        .get_arguments()
        .filter(shown)
        .filter(|a| !a.is_positional())
    {
        let flag = a.get_long().map_or_else(String::new, |l| format!("--{l}"));
        let takes = a.get_num_args().is_none_or(|n| n.max_values() > 0)
            && !matches!(a.get_action(), clap::ArgAction::SetTrue);
        let text = if takes {
            let value = a
                .get_value_names()
                .and_then(|v| v.first().map(ToString::to_string))
                .unwrap_or_else(|| a.get_id().as_str().to_uppercase());
            format!("{flag} {value}")
        } else {
            flag
        };
        parts.push(if a.is_required_set() {
            text
        } else {
            format!("[{text}]")
        });
    }
    parts.join(" ")
}

/// Whether a command of the chat cannot run without something after its name (`/send DEVICE`).
fn needs_words(name: &str, usage: &str) -> bool {
    let rest = usage.get(name.len()..).unwrap_or("").trim_start();
    !rest.is_empty() && !rest.starts_with('[')
}

/// The commands whose name starts with what was typed, for completion.
pub fn matching(typed: &str) -> Vec<&'static Command> {
    let word = typed.split_whitespace().next().unwrap_or(typed);
    if !word.starts_with('/') || typed.contains(' ') {
        return Vec::new();
    }
    COMMANDS
        .iter()
        .filter(|c| c.name.starts_with(word) || alias_starts_with(&c.name, word))
        .collect()
}

/// The commands for a name being typed, best first: those that start with it, then those that
/// contain it, then those with its letters in order. Equal matches keep the order of `COMMANDS`.
pub fn suggest(typed: &str) -> Vec<&'static Command> {
    if !typed.starts_with('/') || typed.contains(char::is_whitespace) {
        return Vec::new();
    }
    let word = typed.to_lowercase();
    let wanted = word.trim_start_matches('/');
    let mut ranked: Vec<(u8, usize, &'static Command)> = Vec::new();
    for (i, c) in COMMANDS.iter().enumerate() {
        let name = c.name.trim_start_matches('/');
        let rank = if name.starts_with(wanted) || alias_starts_with(&c.name, &word) {
            0
        } else if name.contains(wanted) {
            1
        } else if in_order(name, wanted) {
            2
        } else {
            continue;
        };
        ranked.push((rank, i, c));
    }
    ranked.sort_by_key(|(rank, i, _)| (*rank, *i));
    ranked.into_iter().map(|(_, _, c)| c).collect()
}

/// Whether the letters of `wanted` all appear in `name`, in that order.
fn in_order(name: &str, wanted: &str) -> bool {
    let mut letters = name.chars();
    wanted.chars().all(|w| letters.any(|n| n == w))
}

/// The command a word names, by its own name or by an alias.
pub fn find(word: &str) -> Option<&'static Command> {
    let word = alias(word).unwrap_or(word);
    COMMANDS.iter().find(|c| c.name == word)
}

/// Whether the command cannot run without something after its name (`/send DEVICE`).
pub fn needs_args(c: &Command) -> bool {
    !c.bare
}

/// Whether the command takes anything after its name at all.
pub fn takes_args(c: &Command) -> bool {
    c.usage.len() > c.name.len()
}

/// The ways to use a command that has several, one line each, for the lists that show them under the
/// command. Empty when the command has a single form.
pub fn variants(c: &Command) -> Vec<String> {
    if c.forms.len() > 1 {
        c.forms.iter().map(|f| f.usage.clone()).collect()
    } else {
        Vec::new()
    }
}

/// The words that can follow a command, when there is a small fixed set of them.
pub fn choices(command: &str) -> &'static [Choice] {
    find(command).map_or(&[], |c| c.forms.as_slice())
}

/// How to use what is typed: the command, or the form of it that the second word names
/// (`/mcp add NAME ...`). None when the first word is no command.
pub fn hint(typed: &str) -> Option<String> {
    let mut words = typed.split_whitespace();
    let command = find(words.next()?)?;
    let form = words
        .next()
        .and_then(|w| command.forms.iter().find(|f| f.word == w));
    Some(match form {
        Some(f) => format!("{} {}: {}", command.name, f.usage, f.about),
        None => format!("{}: {}", command.usage, command.about),
    })
}

/// Other names for a command: each alias and the command it stands for. An alias completes like a name,
/// so `/ex` suggests `/quit` through `/exit`.
const ALIASES: &[(&str, &str)] = &[
    ("/exit", "/quit"),
    ("/q", "/quit"),
    ("/new", "/clear"),
    ("/reset", "/clear"),
    ("/recap", "/compact"),
    ("/summarize", "/compact"),
    ("/imps", "/imp"),
    ("/?", "/help"),
    ("/link", "/pair"),
    ("/qr", "/pair"),
    ("/visitors", "/devices"),
    ("/peers", "/devices"),
    ("/agents", "/agent"),
    ("/providers", "/provider"),
    ("/skills", "/skill"),
    ("/commands", "/command"),
    ("/rules", "/permission"),
    ("/permissions", "/permission"),
];

/// The command an alias stands for, if the word is one.
pub fn alias(word: &str) -> Option<&'static str> {
    ALIASES
        .iter()
        .find(|(a, _)| *a == word)
        .map(|(_, target)| *target)
}

/// Whether one of a command's aliases starts with what was typed.
fn alias_starts_with(command: &str, typed: &str) -> bool {
    ALIASES
        .iter()
        .any(|(a, target)| *target == command && a.starts_with(typed))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_command_line_commands_are_read_from_its_grammar() {
        let mcp = find("/mcp").unwrap();
        assert!(mcp.managed && mcp.bare);
        let words: Vec<&str> = mcp.forms.iter().map(|f| f.word.as_str()).collect();
        assert_eq!(words, ["list", "add", "set", "remove", "enable", "disable"]);
        let add = mcp.forms.iter().find(|f| f.word == "add").unwrap();
        assert!(
            add.more && add.usage.starts_with("add NAME"),
            "{}",
            add.usage
        );
        assert!(add.usage.contains("[--url URL]"), "{}", add.usage);
        // A terminal-only form is not offered.
        let agent = find("/agent").unwrap();
        assert!(agent.forms.iter().all(|f| f.word != "edit"));
        assert!(agent.forms.iter().any(|f| f.word == "rename"));
        // A command without forms shows its arguments.
        assert_eq!(
            find("/model").unwrap().usage,
            "/model [MODEL] [--agent NAME]"
        );
        assert!(!needs_args(find("/model").unwrap()));
        assert!(needs_args(find("/send").unwrap()));
        assert!(!needs_args(find("/call").unwrap()));
    }

    #[test]
    fn a_hint_follows_the_form_being_typed() {
        assert_eq!(
            hint("/send ").as_deref(),
            Some("/send DEVICE [IMP]: Send this Imp (or another) to a linked device")
        );
        let add = hint("/mcp add files").unwrap();
        assert!(add.starts_with("/mcp add NAME"), "{add}");
        assert!(
            hint("/mcp ")
                .unwrap()
                .starts_with("/mcp [list [--agent NAME] | add")
        );
        assert!(hint("/nope ").is_none());
    }

    #[test]
    fn every_name_the_chat_lists_is_unique() {
        let mut names: Vec<&str> = COMMANDS.iter().map(|c| c.name.as_str()).collect();
        names.sort_unstable();
        names.dedup();
        assert_eq!(names.len(), COMMANDS.len());
        assert_eq!(COMMANDS.len(), LAYOUT.len(), "every managed command exists");
    }
}
