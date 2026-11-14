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
}
