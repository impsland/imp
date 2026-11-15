//! Drawing the chat: the transcript, the message field, the status line and the help card.
//! No borders and no lines between things: groups are set apart by blank space and a soft fill.
//!
//! A tool call reads as `⏺ read_file(path: "README.md")` with its result under it (`⎿ …`), a message to
//! another Imp as `⇢ zed: …` and its answer as `⇠ …`. Lines from commands are dim and never part of
//! what the model sees.

use super::text::{cursor_cell, text_width, truncate, visible_start, wrap};
use super::{App, MAX_INPUT_HEIGHT, help};
use crate::slash::{Note, NoteKind};
use crate::strings;
use crate::transcript::{CallLine, call_line, cut, result_line};
use imp_engine::{ChatMessage, Role, ToolCall};
use ratatui::Frame;
use ratatui::layout::{Constraint, Layout, Position, Rect};
use ratatui::style::{Modifier, Style};
use ratatui::text::{Line, Span};
use ratatui::widgets::Paragraph;

/// What starts a message you wrote, and what starts an answer (in the Imp's colour).
const YOU: &str = "›";
const IMP: &str = "●";
/// A tool call, its result, and a message to another Imp and its answer.
const CALL: &str = "⏺";
const RESULT: &str = "⎿";
const ASK: &str = "⇢";
const ANSWER: &str = "⇠";
/// Columns left of the text in the message field: one of space, the mark and one of space.
const FIELD_INDENT: u16 = 3;

impl App {
    /// The transcript as lines of the given width.
    pub fn transcript(&self, width: usize) -> Vec<Line<'static>> {
        let mut lines = Vec::new();
        let messages = self.chat.messages();
        if messages.is_empty() && self.notes.is_empty() && !self.chat.is_streaming() {
            self.welcome(&mut lines, width);
        }
        let mut notes = self.notes.iter().peekable();
        for (i, message) in messages.iter().enumerate() {
            while let Some((_, note)) = notes.next_if(|(at, _)| *at <= i) {
                self.push_note(&mut lines, note, width);
            }
            self.push_message(&mut lines, message, &messages[i + 1..], width);
        }
        if self.chat.is_streaming() || self.visiting.as_ref().is_some_and(|v| v.partial.is_some()) {
            let text = format!("{}▌", self.streaming());
            marked(&mut lines, IMP, self.mark_style(), &text, width);
        }
        for (_, note) in notes {
            self.push_note(&mut lines, note, width);
        }
        if let Some(error) = &self.error {
            let sentence = strings::format(self.lang, "cli.chat.error", &[("error", error)]);
            marked(&mut lines, "✕", self.theme.danger(), &sentence, width);
        }
        lines
    }

    /// The Imp's own mark: its colour, or the visitor's.
    fn mark_style(&self) -> Style {
        match &self.visiting {
            Some(v) => self.theme.hue(v.hue),
            None => self.theme.imp(),
        }
    }

    /// The empty screen: who this is, where it works, and how to find the commands.
    fn welcome(&self, lines: &mut Vec<Line<'static>>, width: usize) {
        let muted = self.theme.muted();
        let mut head = vec![
            Span::styled(format!("{IMP} "), self.mark_style()),
            Span::styled(
                self.imp.clone(),
                self.theme.text().add_modifier(Modifier::BOLD),
            ),
        ];
        head.push(Span::styled(format!(" · {}", self.model), muted));
        lines.push(Line::from(head));
        if !self.folder.is_empty() {
            lines.push(Line::styled(
                truncate(&format!("  {}", self.folder), width),
                muted,
            ));
        }
        let hint = strings::text(self.lang, "cli.chat.welcome_hint");
        for l in wrap(hint, width.saturating_sub(2)) {
            lines.push(Line::styled(format!("  {l}"), muted));
        }
        lines.push(Line::raw(""));
    }

    fn push_note(&self, lines: &mut Vec<Line<'static>>, note: &Note, width: usize) {
        match note.kind {
            NoteKind::Info => {
                let muted = self.theme.muted();
                for (i, l) in wrap(&note.text, width.saturating_sub(2))
                    .into_iter()
                    .enumerate()
                {
                    let lead = if i == 0 { "  " } else { "    " };
                    lines.push(Line::styled(truncate(&format!("{lead}{l}"), width), muted));
                }
            }
            NoteKind::Problem => marked(lines, "✕", self.theme.danger(), &note.text, width),
            NoteKind::Code => {
                lines.push(Line::from(vec![
                    Span::raw("  "),
                    Span::styled(note.text.clone(), self.theme.code()),
                ]));
            }
        }
    }

    /// One message. `after` is the rest of the conversation, where the results of its tool calls are.
    fn push_message(
        &self,
        lines: &mut Vec<Line<'static>>,
        message: &ChatMessage,
        after: &[ChatMessage],
        width: usize,
    ) {
        match message.role {
            Role::User => {
                marked(lines, YOU, self.theme.muted(), &message.content, width);
                lines.push(Line::raw(""));
            }
            Role::Assistant => {
                if !message.content.is_empty() {
                    marked(lines, IMP, self.mark_style(), &message.content, width);
                }
                for call in &message.tool_calls {
                    self.push_call(lines, call, after, width);
                }
                if !message.content.is_empty() || !message.tool_calls.is_empty() {
                    lines.push(Line::raw(""));
                }
            }
            // Results show under their calls.
            Role::Tool | Role::System => {}
        }
    }

    fn push_call(
        &self,
        lines: &mut Vec<Line<'static>>,
        call: &ToolCall,
        after: &[ChatMessage],
        width: usize,
    ) {
        let muted = self.theme.muted();
        let result = after
            .iter()
            .find(|m| m.role == Role::Tool && m.tool_call_id.as_deref() == Some(&call.id))
            .map(|m| m.content.as_str());
        match call_line(&call.name, &call.arguments) {
            CallLine::Tool(text) => {
                marked(lines, CALL, self.mark_style(), &text, width);
                let (said, style) = match result.map(result_line) {
                    Some((text, false)) => (text, muted),
                    Some((text, true)) => (text, self.theme.danger()),
                    None => (
                        strings::text(self.lang, "cli.chat.running").to_string(),
                        muted,
                    ),
                };
                indented(lines, RESULT, style, &said, width);
            }
            CallLine::Message { to, text } => {
                let asked = format!("{to}: {text}");
                marked(lines, ASK, self.mark_style(), &asked, width);
                let answer = cut(result.unwrap_or_default().trim(), 600);
                let (said, style) = match result.map(result_line) {
                    Some((_, true)) => (answer, self.theme.danger()),
                    Some(_) => (answer, self.theme.text()),
                    None => (
                        strings::format(self.lang, "cli.chat.waiting_for", &[("imp", &to)]),
                        muted,
                    ),
                };
                indented(lines, ANSWER, style, &said, width);
            }
        }
    }

    pub fn render(&self, frame: &mut Frame) {
        let area = frame.area();
        let field_width = (area.width as usize)
            .saturating_sub(FIELD_INDENT as usize + 1)
            .max(1);
        let input_lines = wrap(&self.input, field_width);
        let input_height = (input_lines.len() as u16 + 2).clamp(3, MAX_INPUT_HEIGHT);
        let room = area.height.saturating_sub(input_height + 2) as usize;
        let popup = self.popup(room, area.width as usize);
        let below = popup.len() as u16;
        let [top, field, hints, status] = Layout::vertical([
            Constraint::Min(1),
            Constraint::Length(input_height),
            Constraint::Length(below),
            Constraint::Length(1),
        ])
        .areas(area);
        self.render_transcript(frame, top);
        let cursor = cursor_cell(&self.input, &input_lines, self.cursor);
        self.render_field(frame, field, &input_lines, cursor);
        if below > 0 {
            frame.render_widget(Paragraph::new(popup), hints);
        }
        frame.render_widget(
            Paragraph::new(self.status_line(status.width as usize)),
            status,
        );
        if self.help {
            help::render(self, frame, area);
        }
    }

    fn render_transcript(&self, frame: &mut Frame, area: Rect) {
        let lines = self.transcript(area.width.max(1) as usize);
        let height = area.height as usize;
        let (start, max) = visible_start(lines.len(), height, self.scroll);
        self.viewport.set(height);
        self.max_scroll.set(max);
        let shown: Vec<Line> = lines.into_iter().skip(start).take(height).collect();
        frame.render_widget(Paragraph::new(shown), area);
    }

    /// The message field: a soft fill with a blank row above and below, no border.
    fn render_field(
        &self,
        frame: &mut Frame,
        area: Rect,
        lines: &[String],
        cursor: (usize, usize),
    ) {
        frame.buffer_mut().set_style(area, self.theme.card());
        let inner = area.height.saturating_sub(2) as usize;
        // The last lines show, unless the cursor is above them.
        let skip = lines.len().saturating_sub(inner).min(cursor.0);
        let first_shown = skip == 0;
        let hint = if self.waiting {
            "cli.chat.input_wait"
        } else {
            "cli.chat.input_hint"
        };
        let shown: Vec<Line> = if self.input.is_empty() {
            let hint = strings::text(self.lang, hint);
            vec![Line::from(vec![
                Span::styled(format!(" {YOU} "), self.theme.muted()),
                Span::styled(hint, self.theme.muted()),
            ])]
        } else {
            lines
                .iter()
                .skip(skip)
                .enumerate()
                .map(|(i, l)| {
                    let mark = if i == 0 && first_shown { YOU } else { " " };
                    Line::from(vec![
                        Span::styled(format!(" {mark} "), self.theme.muted()),
                        Span::raw(l.clone()),
                    ])
                })
                .collect()
        };
        let body = Rect::new(
            area.x,
            area.y + 1,
            area.width,
            area.height.saturating_sub(2),
        );
        frame.render_widget(Paragraph::new(shown), body);
        let row = cursor.0.saturating_sub(skip).min(inner.saturating_sub(1)) as u16;
        let x = (area.x + FIELD_INDENT + cursor.1 as u16).min(area.right().saturating_sub(1));
        frame.set_cursor_position(Position::new(x, area.y + 1 + row));
    }

    /// The Imp's mark, its name and brain on the left, then what it is doing and the help hint on the right.
    fn status_line(&self, width: usize) -> Line<'static> {
        let muted = self.theme.muted();
        let left = format!(" {} · {}", self.imp, self.model);
        let open = !self.menu().entries.is_empty();
        let hint = strings::text(
            self.lang,
            if open {
                "cli.chat.menu_hint"
            } else {
                "cli.chat.help_hint"
            },
        );
        let activity = self.activity();
        let mut right = format!("{activity} · {hint} ");
        let used = |left: &str, right: &str| 1 + text_width(left) + text_width(right);
        if used(&left, &right) > width {
            right = format!("{activity} ");
        }
        let left = truncate(&left, width.saturating_sub(text_width(&right) + 2));
        let gap = width.saturating_sub(used(&left, &right));
        Line::from(vec![
            Span::styled(IMP, self.mark_style()),
            Span::styled(left, muted),
            Span::raw(" ".repeat(gap)),
            Span::styled(truncate(&right, width), muted),
        ])
    }
}

/// Lines of `text` wrapped to `width`, the first led by `mark` and the rest indented under the text.
fn marked(lines: &mut Vec<Line<'static>>, mark: &str, mark_style: Style, text: &str, width: usize) {
    for (i, line) in wrap(text, width.saturating_sub(2)).into_iter().enumerate() {
        let lead = if i == 0 {
            mark.to_string()
        } else {
            " ".to_string()
        };
        lines.push(Line::from(vec![
            Span::styled(format!("{lead} "), mark_style),
            Span::raw(line),
        ]));
    }
}

/// Like `marked`, two columns in and all in `style`: what came back from a call.
fn indented(lines: &mut Vec<Line<'static>>, mark: &str, style: Style, text: &str, width: usize) {
    for (i, line) in wrap(text, width.saturating_sub(4)).into_iter().enumerate() {
        let lead = if i == 0 { mark } else { " " };
        lines.push(Line::styled(format!("  {lead} {line}"), style));
    }
}
