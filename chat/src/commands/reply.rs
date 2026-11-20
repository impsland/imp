//! What a management command answers: a value for `--json` and the same thing for people to read.

use serde_json::Value;
use std::fmt::Write as _;

/// How a reply reads without `--json`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum View {
    /// A line of text: what was done.
    Note(String),
    /// Several lines, as they are.
    Text(String),
    /// One thing: a label and a value per line.
    Fields(Vec<(String, String)>),
    /// Many things in columns.
    Table {
        head: Vec<&'static str>,
        rows: Vec<Vec<String>>,
    },
}

/// The result of one command. The terminal prints it and a chat shows it, so both read the same.
#[derive(Debug, Clone, PartialEq)]
pub struct Reply {
    pub json: Value,
    pub view: View,
}

impl Reply {
    /// What was done, as `{"ok": true, "message": ...}` plus `json` when there is something to say.
    pub fn done(message: impl Into<String>, json: Value) -> Self {
        let message = message.into();
        let mut object = serde_json::Map::new();
        object.insert("ok".into(), Value::Bool(true));
        object.insert("message".into(), Value::String(message.clone()));
        if let Value::Object(more) = json {
            object.extend(more);
        }
        Self {
            json: Value::Object(object),
            view: View::Note(message),
        }
    }

    pub fn table(head: Vec<&'static str>, rows: Vec<Vec<String>>, json: Value) -> Self {
        Self {
            json,
            view: View::Table { head, rows },
        }
    }

    pub fn fields(fields: Vec<(&str, String)>, json: Value) -> Self {
        Self {
            json,
            view: View::Fields(
                fields
                    .into_iter()
                    .map(|(k, v)| (k.to_string(), v))
                    .collect(),
            ),
        }
    }

    pub fn text(text: impl Into<String>, json: Value) -> Self {
        Self {
            json,
            view: View::Text(text.into()),
        }
    }

    /// The text to print, without a final newline.
    pub fn render(&self, json: bool) -> String {
        if json {
            return serde_json::to_string_pretty(&self.json).unwrap_or_default();
        }
        match &self.view {
            View::Note(text) | View::Text(text) => text.clone(),
            View::Fields(fields) => {
                let width = fields
                    .iter()
                    .map(|(k, _)| k.chars().count())
                    .max()
                    .unwrap_or(0);
                fields
                    .iter()
                    .map(|(k, v)| format!("{k:width$}  {v}").trim_end().to_string())
                    .collect::<Vec<_>>()
                    .join("\n")
            }
            View::Table { head, rows } => {
                if rows.is_empty() {
                    return "Nothing here yet.".into();
                }
                let widths: Vec<usize> = (0..head.len())
                    .map(|i| {
                        rows.iter()
                            .map(|r| r.get(i).map_or(0, |c| c.chars().count()))
                            .chain([head[i].chars().count()])
                            .max()
                            .unwrap_or(0)
                    })
                    .collect();
                let line = |cells: Vec<&str>| {
                    let mut out = String::new();
                    for (i, cell) in cells.iter().enumerate() {
                        if i + 1 == cells.len() {
                            out.push_str(cell);
                        } else {
                            let _ = write!(out, "{cell:w$}  ", w = widths[i]);
                        }
                    }
                    out.trim_end().to_string()
                };
                let mut lines = vec![line(head.clone())];
                lines.extend(
                    rows.iter()
                        .map(|r| line(r.iter().map(String::as_str).collect())),
                );
                lines.join("\n")
            }
        }
    }
}

/// `-` is how a command says "take this setting away".
pub fn cleared(value: &str) -> bool {
    value == "-"
}

/// `NAME=VALUE` pairs.
pub fn pairs(items: &[String], what: &str) -> crate::Result<Vec<(String, String)>> {
    items
        .iter()
        .map(|item| match item.split_once('=') {
            Some((k, v)) if !k.trim().is_empty() => Ok((k.trim().to_string(), v.to_string())),
            _ => Err(crate::CliError(format!(
                "{item:?} is not NAME=VALUE (for {what})."
            ))),
        })
        .collect()
}
