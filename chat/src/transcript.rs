//! How a tool call and its result read in a chat, in one short line each. The full-screen chat and the line
//! chat both use these, so a call looks the same in both.

use crate::troupe::TOOL_NAME as IMP_MESSAGE;
use serde_json::Value;

/// The longest a summary of arguments or of a result gets, in characters.
const LONGEST: usize = 96;

/// What a tool call is about, in a line.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum CallLine {
    /// A tool with its arguments: `read_file(path: "README.md")`.
    Tool(String),
    /// A message to another Imp.
    Message { to: String, text: String },
}

/// Reads a call: `imp_message` as a message to another Imp, any other tool as its name and arguments.
pub fn call_line(name: &str, arguments: &str) -> CallLine {
    let args: Value = serde_json::from_str(arguments).unwrap_or(Value::Null);
    if name == IMP_MESSAGE {
        let field = |k: &str| {
            args.get(k)
                .and_then(Value::as_str)
                .unwrap_or("")
                .to_string()
        };
        return CallLine::Message {
            to: field("to"),
            text: cut(&one_line(&field("text")), LONGEST * 2),
        };
    }
    let shown = match &args {
        Value::Object(map) if !map.is_empty() => map
            .iter()
            .map(|(k, v)| format!("{k}: {}", value(v)))
            .collect::<Vec<_>>()
            .join(", "),
        _ => String::new(),
    };
    CallLine::Tool(format!("{}({})", short_name(name), cut(&shown, LONGEST)))
}

/// A tool's name without the server prefix the MCP host adds (`files__read_file` reads `read_file`).
pub fn short_name(name: &str) -> &str {
    name.split_once("__").map_or(name, |(_, tool)| tool)
}

fn value(v: &Value) -> String {
    match v {
        Value::String(s) => format!("\"{}\"", cut(&one_line(s), 40)),
        Value::Array(items) => format!("[{} items]", items.len()),
        Value::Object(_) => "{…}".into(),
        other => other.to_string(),
    }
}

/// A result in a line: short text as it is, longer text as its first line and how many more there are.
/// A failure starts with `Error:`.
pub fn result_line(content: &str) -> (String, bool) {
    let failed = content.trim_start().starts_with("Error:")
        || content.starts_with("The tool ") && content.contains("switched off");
    let lines: Vec<&str> = content.lines().filter(|l| !l.trim().is_empty()).collect();
    let text = match lines.as_slice() {
        [] => "(nothing)".to_string(),
        [one] => cut(one.trim(), LONGEST),
        [first, rest @ ..] => format!("{} (+{} lines)", cut(first.trim(), LONGEST), rest.len()),
    };
    (text, failed)
}

/// What a line of a tool call's details is, which decides its mark and its colour.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Kind {
    /// The name of an argument.
    Heading,
    Plain,
    /// A line of a change that stays as it was.
    Same,
    Added,
    Removed,
}

impl Kind {
    /// What starts the line: `+` and `-` for a change, so it reads without colours too.
    pub fn marker(self) -> &'static str {
        match self {
            Kind::Added => "+ ",
            Kind::Removed => "- ",
            Kind::Same => "  ",
            Kind::Heading | Kind::Plain => "",
        }
    }
}

/// One line of the details of a call.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DetailLine {
    pub kind: Kind,
    pub text: String,
}

impl DetailLine {
    fn new(kind: Kind, text: &str) -> Self {
        Self {
            kind,
            text: text.to_string(),
        }
    }
}

/// Tools that write a whole file, whose `content` is new text.
const WRITE_TOOLS: [&str; 3] = ["write_file", "create_file", "write"];
/// The names editing tools give the text that was there and the text that replaces it.
const CHANGE_KEYS: [(&str, &str); 4] = [
    ("oldText", "newText"),
    ("old_string", "new_string"),
    ("old_str", "new_str"),
    ("old_text", "new_text"),
];

/// Every argument of a call, whole: each under its name, a written file as added lines and an edit as
/// the lines taken out and put in (the text that was there is known from the call itself).
pub fn argument_lines(name: &str, arguments: &str) -> Vec<DetailLine> {
    let args: Value = match serde_json::from_str(arguments) {
        Ok(args) => args,
        Err(_) if arguments.trim().is_empty() => return Vec::new(),
        Err(_) => return text_lines(Kind::Plain, arguments),
    };
    let Value::Object(map) = &args else {
        return plain(&args);
    };
    let writes = WRITE_TOOLS.contains(&short_name(name));
    let change = CHANGE_KEYS
        .iter()
        .find(|(old, new)| map.get(*old).is_some_and(Value::is_string) && map.contains_key(*new));
    // The map is sorted by name. What is written or changed comes last, after the path it is for.
    let mut entries: Vec<(&String, &Value)> = map.iter().collect();
    entries.sort_by_key(|(key, _)| {
        matches!(key.as_str(), "content" | "edits") || change.is_some_and(|(old, _)| key == old)
    });
    let mut out = Vec::new();
    for (key, v) in entries {
        if change.is_some_and(|(_, new)| key == new) {
            continue;
        }
        match (v, change) {
            (Value::String(content), _) if writes && key == "content" => {
                out.push(DetailLine::new(Kind::Heading, key));
                out.extend(text_lines(Kind::Added, content));
            }
            (Value::String(old), Some((o, n))) if key == o => {
                out.push(DetailLine::new(Kind::Heading, &format!("{o} → {n}")));
                out.extend(diff(old, map[*n].as_str().unwrap_or_default()));
            }
            (Value::Array(edits), _) if key == "edits" => {
                out.push(DetailLine::new(Kind::Heading, key));
                for (i, edit) in edits.iter().enumerate() {
                    if i > 0 {
                        out.push(DetailLine::new(Kind::Plain, ""));
                    }
                    match CHANGE_KEYS.iter().find_map(|(old, new)| {
                        Some((edit.get(old)?.as_str()?, edit.get(new)?.as_str()?))
                    }) {
                        Some((old, new)) => out.extend(diff(old, new)),
                        None => out.extend(plain(edit)),
                    }
                }
            }
            _ => {
                out.push(DetailLine::new(Kind::Heading, key));
                out.extend(plain(v));
            }
        }
    }
    out
}

/// A value as it reads: a string as its own lines, anything else as JSON.
fn plain(v: &Value) -> Vec<DetailLine> {
    match v {
        Value::String(s) => text_lines(Kind::Plain, s),
        Value::Array(_) | Value::Object(_) => text_lines(
            Kind::Plain,
            &serde_json::to_string_pretty(v).unwrap_or_default(),
        ),
        other => text_lines(Kind::Plain, &other.to_string()),
    }
}

fn text_lines(kind: Kind, text: &str) -> Vec<DetailLine> {
    text.lines().map(|l| DetailLine::new(kind, l)).collect()
}

/// A change by lines: the lines the two texts start and end with alike stay, what is between them is
/// taken out and put in. That is enough to read a change. It does not look for lines that moved.
fn diff(old: &str, new: &str) -> Vec<DetailLine> {
    let (old, new): (Vec<&str>, Vec<&str>) = (old.lines().collect(), new.lines().collect());
    let start = old.iter().zip(&new).take_while(|(a, b)| a == b).count();
    let end = old[start..]
        .iter()
        .rev()
        .zip(new[start..].iter().rev())
        .take_while(|(a, b)| a == b)
        .count();
    let line = |kind, l: &&str| DetailLine::new(kind, l);
    let mut out: Vec<DetailLine> = old[..start].iter().map(|l| line(Kind::Same, l)).collect();
    out.extend(
        old[start..old.len() - end]
            .iter()
            .map(|l| line(Kind::Removed, l)),
    );
    out.extend(
        new[start..new.len() - end]
            .iter()
            .map(|l| line(Kind::Added, l)),
    );
    out.extend(old[old.len() - end..].iter().map(|l| line(Kind::Same, l)));
    out
}

fn one_line(s: &str) -> String {
    s.split_whitespace().collect::<Vec<_>>().join(" ")
}

/// Cuts `s` to `max` characters, with an ellipsis if something was left out.
pub fn cut(s: &str, max: usize) -> String {
    if s.chars().count() <= max {
        return s.to_string();
    }
    let mut out: String = s.chars().take(max.saturating_sub(1)).collect();
    out.push('…');
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_tool_call_reads_as_its_name_and_arguments() {
        assert_eq!(
            call_line("files__read_file", r#"{"path":"README.md"}"#),
            CallLine::Tool("read_file(path: \"README.md\")".into())
        );
        assert_eq!(call_line("now", "{}"), CallLine::Tool("now()".into()));
        assert_eq!(call_line("x", "not json"), CallLine::Tool("x()".into()));
        let CallLine::Tool(long) = call_line("t", &format!(r#"{{"a":"{}"}}"#, "y".repeat(500)))
        else {
            panic!()
        };
        assert!(long.chars().count() < 120);
    }

    #[test]
    fn a_message_to_another_imp_reads_as_one() {
        assert_eq!(
            call_line("imp_message", r#"{"to":"zed","text":"Hi\nthere"}"#),
            CallLine::Message {
                to: "zed".into(),
                text: "Hi there".into()
            }
        );
    }

    #[test]
    fn results_are_one_line_and_failures_are_known() {
        assert_eq!(result_line("done"), ("done".into(), false));
        assert_eq!(result_line("a\nb\n\nc"), ("a (+2 lines)".into(), false));
        assert!(result_line("Error: no such file").1);
        assert_eq!(result_line("").0, "(nothing)");
    }

    #[test]
    fn a_written_file_is_all_added_lines() {
        let lines = argument_lines(
            "files__write_file",
            r#"{"path":"a.md","content":"one\ntwo"}"#,
        );
        let kinds: Vec<(Kind, &str)> = lines.iter().map(|l| (l.kind, l.text.as_str())).collect();
        assert_eq!(
            kinds,
            [
                (Kind::Heading, "path"),
                (Kind::Plain, "a.md"),
                (Kind::Heading, "content"),
                (Kind::Added, "one"),
                (Kind::Added, "two"),
            ]
        );
    }

    #[test]
    fn an_edit_shows_what_was_taken_out_and_put_in() {
        let lines = argument_lines(
            "edit_file",
            r#"{"path":"a","edits":[{"oldText":"a\nb\nc","newText":"a\nB\nc"}]}"#,
        );
        let kinds: Vec<(Kind, &str)> = lines.iter().map(|l| (l.kind, l.text.as_str())).collect();
        assert_eq!(
            kinds[3..],
            [
                (Kind::Same, "a"),
                (Kind::Removed, "b"),
                (Kind::Added, "B"),
                (Kind::Same, "c"),
            ]
        );
        let flat = argument_lines("str_replace", r#"{"old_string":"x","new_string":"y"}"#);
        assert_eq!(flat[0].text, "old_string → new_string");
        assert_eq!((flat[1].kind, flat[2].kind), (Kind::Removed, Kind::Added));
    }

    #[test]
    fn other_arguments_show_whole() {
        let long = "y".repeat(300);
        let lines = argument_lines("t", &format!(r#"{{"a":"{long}","n":3}}"#));
        assert_eq!(lines[1].text, long);
        assert_eq!(lines[3].text, "3");
        assert!(argument_lines("t", "").is_empty());
        assert_eq!(argument_lines("t", "oops")[0].text, "oops");
    }
}
