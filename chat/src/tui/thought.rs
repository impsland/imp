//! What the model thought before it answered. While it thinks, the reasoning streams in a dim block of
//! a few rows, the latest at the bottom, so the screen does not move around. When the answer or a tool
//! call starts, the block collapses to one line, `✻ Thought for 3s`, which opens in full like a tool
//! call does (a click on it, or Ctrl+O). Every phase of thinking in a turn has its own line. The
//! reasoning is only shown: it is never part of what the model is sent.

use super::App;
use super::text::{text_width, truncate, wrap};
use super::view::Row;
use crate::strings;
use ratatui::style::Style;
use ratatui::text::{Line, Span};
use std::time::Instant;

/// The mark of a thought, where a tool call has `⏺`.
pub(super) const THOUGHT: &str = "✻";
/// The most rows of reasoning shown while the model thinks.
pub(super) const LIVE_ROWS: usize = 4;

/// A phase of thinking that is over.
#[derive(Debug, Clone)]
pub(super) struct Thought {
    /// Stands for the thought in a click on its row, like the id of a tool call.
    pub id: String,
    /// Before which message of the chat it came: the one the model said or called a tool in next.
    pub at: usize,
    pub text: String,
    pub seconds: u64,
}

/// The phase of thinking that is going on.
#[derive(Debug, Clone)]
pub(super) struct Thinking {
    pub text: String,
    pub since: Instant,
}

impl App {
    /// More of the model's reasoning arrived.
    pub(super) fn think(&mut self, more: &str) {
        self.thinking
            .get_or_insert_with(|| Thinking {
                text: String::new(),
                since: Instant::now(),
            })
            .text
            .push_str(more);
    }

    /// The answer or a tool call started, or the turn ended: the thinking collapses to its line.
    pub(super) fn end_thinking(&mut self) {
        let Some(thinking) = self.thinking.take() else {
            return;
        };
        let text = thinking.text.trim();
        if text.is_empty() {
            return;
        }
        self.thought_count += 1;
        self.thoughts.push(Thought {
            id: format!("thought-{}", self.thought_count),
            at: self.chat.messages().len(),
            text: text.to_string(),
            seconds: thinking.since.elapsed().as_secs_f64().ceil().max(1.0) as u64,
        });
    }

    /// The thoughts and the thinking go with the chat they belong to.
    pub(super) fn forget_thoughts(&mut self) {
        self.thoughts.clear();
        self.thinking = None;
    }

    /// The collapsed line of a thought.
    pub(super) fn thought_title(&self, thought: &Thought) -> String {
        strings::format(
            self.lang,
            "cli.chat.thought_for",
            &[("seconds", &thought.seconds.to_string())],
        )
    }

    /// The thoughts that came before message `at`, as collapsed lines.
    pub(super) fn push_thoughts(
        &self,
        rows: &mut Vec<Row>,
        at: impl Fn(usize) -> bool,
        width: usize,
    ) {
        for thought in self.thoughts.iter().filter(|t| at(t.at)) {
            let title = truncate(&self.thought_title(thought), width.saturating_sub(2));
            let mut row = Row::new(
                Line::from(vec![
                    Span::styled(format!("{THOUGHT} "), self.mark_style()),
                    Span::styled(title, self.theme.muted()),
                ]),
                2,
            );
            row.call = Some(thought.id.clone());
            rows.push(row);
            rows.push(Row::blank());
        }
    }

    /// The reasoning that is arriving: its last few rows, dim and indented under the spinner line.
    pub(super) fn push_reasoning_tail(&self, rows: &mut Vec<Row>, width: usize) {
        let Some(thinking) = &self.thinking else {
            return;
        };
        let room = width.saturating_sub(2).max(1);
        let all: Vec<String> = thinking
            .text
            .trim()
            .split('\n')
            .filter(|l| !l.trim().is_empty())
            .flat_map(|l| wrap(l.trim(), room))
            .collect();
        let muted: Style = self.theme.muted();
        for line in &all[all.len().saturating_sub(LIVE_ROWS)..] {
            rows.push(Row::new(
                Line::styled(format!("  {line}"), muted),
                text_width("  "),
            ));
        }
    }
}
