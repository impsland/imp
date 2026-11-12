//! Drawing the chat: the transcript, the message field, the status line and the help card.
//! No borders and no lines between things: groups are set apart by blank space and a soft fill.

use super::text::{text_width, truncate, visible_start, wrap};
use super::{App, MAX_INPUT_HEIGHT, help};
use crate::strings;
use imp_core::{ChatMessage, Role};
use ratatui::Frame;
use ratatui::layout::{Constraint, Layout, Position, Rect};
use ratatui::style::{Modifier, Style};
use ratatui::text::{Line, Span};
use ratatui::widgets::Paragraph;

/// What starts a message you wrote, and what starts an answer (in the Imp's colour).
const YOU: &str = "›";
const IMP: &str = "●";
/// Columns left of the text in the message field: one of space, the mark and one of space.
const FIELD_INDENT: u16 = 3;

impl App {
    /// The transcript as lines of the given width.
    pub fn transcript(&self, width: usize) -> Vec<Line<'static>> {
        let mut lines = Vec::new();
        for message in self.chat.messages() {
            self.push_message(&mut lines, message, width);
        }
        if self.chat.is_streaming() {
            let text = format!("{}▌", self.chat.streaming_text());
            marked(&mut lines, IMP, self.theme.imp(), &text, width);
        }
        if let Some(error) = &self.error {
            let sentence = strings::format(self.lang, "cli.chat.error", &[("error", error)]);
            marked(&mut lines, "✕", self.theme.danger(), &sentence, width);
        }
        lines
    }

    fn push_message(&self, lines: &mut Vec<Line<'static>>, message: &ChatMessage, width: usize) {
        let (lang, muted) = (self.lang, self.theme.muted());
        match message.role {
            Role::User => marked(lines, YOU, self.theme.muted(), &message.content, width),
            Role::Assistant => {
                if !message.content.is_empty() {
                    marked(lines, IMP, self.theme.imp(), &message.content, width);
                }
                for call in &message.tool_calls {
                    let args = [("imp", self.imp.as_str()), ("tool", call.name.as_str())];
                    let text = strings::format(lang, "cli.chat.tool_use", &args);
                    marked(lines, "·", muted, &text, width);
                }
            }
            Role::Tool => {
                let first = message.content.lines().next().unwrap_or("");
                let text = strings::format(lang, "cli.chat.tool_result", &[("text", first)]);
                lines.push(Line::styled(truncate(&format!("  {text}"), width), muted));
            }
            Role::System => {}
        }
        let answer_without_words = message.role == Role::Assistant && message.content.is_empty();
        if message.role != Role::Tool && !answer_without_words {
            lines.push(Line::raw(""));
        }
    }

    pub fn render(&self, frame: &mut Frame) {
        let area = frame.area();
        let text_width = (area.width as usize)
            .saturating_sub(FIELD_INDENT as usize + 1)
            .max(1);
        let input_lines = wrap(&self.input, text_width);
        let input_height = (input_lines.len() as u16 + 2).clamp(3, MAX_INPUT_HEIGHT);
        let [top, field, status] = Layout::vertical([
            Constraint::Min(1),
            Constraint::Length(input_height),
            Constraint::Length(1),
        ])
        .areas(area);
        self.render_transcript(frame, top);
        self.render_field(frame, field, &input_lines);
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
    fn render_field(&self, frame: &mut Frame, area: Rect, lines: &[String]) {
        frame.buffer_mut().set_style(area, self.theme.card());
        let inner = area.height.saturating_sub(2) as usize;
        let skip = lines.len().saturating_sub(inner);
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
        let row = lines.len().saturating_sub(skip).saturating_sub(1) as u16;
        let col = lines.last().map_or(0, |l| text_width(l)) as u16;
        let x = (area.x + FIELD_INDENT + col).min(area.right().saturating_sub(1));
        frame.set_cursor_position(Position::new(x, area.y + 1 + row));
    }

    /// The Imp's mark, its name and brain on the left; what it is doing and the help hint on the right.
    fn status_line(&self, width: usize) -> Line<'static> {
        let muted = self.theme.muted();
        let left = format!(" {} · {}", self.imp, self.model);
        let hint = strings::text(self.lang, "cli.chat.help_hint");
        let activity = self.activity();
        let mut right = format!("{activity} · {hint} ");
        let used = |left: &str, right: &str| 1 + text_width(left) + text_width(right);
        if used(&left, &right) > width {
            right = format!("{activity} ");
        }
        let left = truncate(&left, width.saturating_sub(text_width(&right) + 2));
        let gap = width.saturating_sub(used(&left, &right));
        Line::from(vec![
            Span::styled(IMP, self.theme.imp()),
            Span::styled(left, muted),
            Span::raw(" ".repeat(gap)),
            Span::styled(
                truncate(&right, width),
                muted.add_modifier(Modifier::empty()),
            ),
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
