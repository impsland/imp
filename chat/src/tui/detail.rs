//! The details of one tool call, which the one-line view cuts short: every argument and the whole result,
//! wrapped to the screen. A written file shows as added lines and an edit as the lines taken out and put
//! in. It covers the chat like the help card does and moves between the calls of the chat with the arrows.

use super::text::{text_width, truncate, wrap};
use super::{App, WHEEL_LINES};
use crate::strings;
use crate::theme::Theme;
use crate::transcript::{DetailLine, Kind, argument_lines, result_line, short_name};
use imp_engine::{ChatMessage, Role, ToolCall};
use ratatui::Frame;
use ratatui::crossterm::event::{KeyCode, KeyEvent, KeyModifiers};
use ratatui::layout::Rect;
use ratatui::style::Style;
use ratatui::text::{Line, Span};
use ratatui::widgets::{Clear, Paragraph};
use std::cell::Cell;

/// The most lines of arguments, and of a result, shown before a note says how many more there are.
/// Enter shows them all.
pub(super) const MOST_LINES: usize = 40;
/// Columns left empty at each side of the text.
const MARGIN: usize = 2;

/// Which call is open, how far it is scrolled, and whether it shows all its lines.
pub struct Detail {
    at: usize,
    scroll: Cell<usize>,
    all: bool,
}

impl App {
    pub fn is_detail_open(&self) -> bool {
        self.detail.is_some()
    }

    /// The calls to tools in the chat in order, each with its result once it has come. A message to
    /// another Imp is not one: it already shows whole.
    fn tool_calls(&self) -> Vec<(&ToolCall, Option<&ChatMessage>)> {
        let messages = self.chat.messages();
        messages
            .iter()
            .enumerate()
            .flat_map(|(i, m)| m.tool_calls.iter().map(move |call| (i, call)))
            .filter(|(_, call)| call.name != crate::troupe::TOOL_NAME)
            .map(|(i, call)| {
                let result = messages[i + 1..]
                    .iter()
                    .find(|m| m.role == Role::Tool && m.tool_call_id.as_deref() == Some(&call.id));
                (call, result)
            })
            .collect()
    }

    /// Opens the call with this id, as a click on its rows does. Nothing opens for a call that is not there.
    pub(super) fn open_tool_detail(&mut self, call_id: &str) {
        let at = self
            .tool_calls()
            .iter()
            .position(|(call, _)| call.id == call_id);
        self.detail = at.map(|at| Detail {
            at,
            scroll: Cell::new(0),
            all: false,
        });
    }

    /// Opens the latest call. A chat without tool calls has nothing to open.
    pub(super) fn open_detail(&mut self) {
        let last = self.tool_calls().len().checked_sub(1);
        self.detail = last.map(|at| Detail {
            at,
            scroll: Cell::new(0),
            all: false,
        });
    }

    /// While the details are open, the arrows move between calls and through a long one, Enter shows
    /// every line of it, and Esc closes. Other keys are not typed into the message behind.
    pub(super) fn detail_key(&mut self, key: KeyEvent) -> super::Action {
        let total = self.tool_calls().len();
        let page = self.page();
        let Some(detail) = self.detail.as_mut() else {
            return super::Action::None;
        };
        let by =
            |from: usize, up: bool, n: usize| if up { from.saturating_sub(n) } else { from + n };
        let at = detail.scroll.get();
        match key.code {
            KeyCode::Char('c') if key.modifiers.contains(KeyModifiers::CONTROL) => {
                return super::Action::Quit;
            }
            KeyCode::Esc | KeyCode::Char('q') => self.detail = None,
            KeyCode::Char('o') if key.modifiers.contains(KeyModifiers::CONTROL) => {
                self.detail = None;
            }
            KeyCode::Left | KeyCode::Right => {
                let next = by(detail.at, key.code == KeyCode::Left, 1).min(total.saturating_sub(1));
                *detail = Detail {
                    at: next,
                    scroll: Cell::new(0),
                    all: false,
                };
            }
            KeyCode::Up => detail.scroll.set(by(at, true, 1)),
            KeyCode::Down => detail.scroll.set(by(at, false, 1)),
            KeyCode::PageUp => detail.scroll.set(by(at, true, page)),
            KeyCode::PageDown => detail.scroll.set(by(at, false, page)),
            KeyCode::Home => detail.scroll.set(0),
            KeyCode::End => detail.scroll.set(usize::MAX / 2),
            KeyCode::Enter => detail.all = !detail.all,
            _ => {}
        }
        super::Action::None
    }

    /// The wheel scrolls the open details.
    pub(super) fn detail_wheel(&mut self, up: bool) {
        if let Some(detail) = &self.detail {
            let at = detail.scroll.get();
            detail.scroll.set(if up {
                at.saturating_sub(WHEEL_LINES)
            } else {
                at + WHEEL_LINES
            });
        }
    }

    /// Draws the open call over the whole screen.
    pub(super) fn render_detail(&self, frame: &mut Frame, area: Rect) {
        let Some(detail) = &self.detail else {
            return;
        };
        let calls = self.tool_calls();
        let Some((call, result)) = calls.get(detail.at.min(calls.len().saturating_sub(1))) else {
            return;
        };
        frame.render_widget(Clear, area);
        frame.buffer_mut().set_style(area, self.theme.raised());
        let width = (area.width as usize).saturating_sub(2 * MARGIN).max(1);
        let rows = self.detail_rows(call, result.map(|m| m.content.as_str()), detail.all, width);
        let room = (area.height as usize).saturating_sub(1);
        let max = rows.len().saturating_sub(room);
        let from = detail.scroll.get().min(max);
        detail.scroll.set(from);
        let footer = strings::format(
            self.lang,
            "cli.chat.detail_footer",
            &[
                ("n", &(detail.at + 1).min(calls.len()).to_string()),
                ("total", &calls.len().to_string()),
            ],
        );
        let mut shown: Vec<Line<'static>> = rows.into_iter().skip(from).take(room).collect();
        shown.resize(room, Line::raw(""));
        shown.push(Line::styled(truncate(&footer, width), self.theme.muted()));
        let body = Rect::new(
            area.x + MARGIN as u16,
            area.y,
            (width as u16).min(area.width),
            area.height,
        );
        frame.render_widget(Paragraph::new(shown), body.intersection(area));
    }

    /// The rows of a call's details: its name, its arguments, and its result.
    fn detail_rows(
        &self,
        call: &ToolCall,
        result: Option<&str>,
        all: bool,
        width: usize,
    ) -> Vec<Line<'static>> {
        let theme = &self.theme;
        let mut rows = vec![
            Line::styled(truncate(short_name(&call.name), width), theme.strong()),
            Line::raw(""),
        ];
        let arguments = argument_lines(&call.name, &call.arguments);
        section(&mut rows, &arguments, all, width, theme, self.lang, None);
        if !arguments.is_empty() {
            rows.push(Line::raw(""));
        }
        rows.push(Line::styled(
            strings::text(self.lang, "cli.chat.detail_result"),
            theme.strong(),
        ));
        match result {
            Some(content) => {
                let (nothing, failed) = result_line(content);
                let lines: Vec<DetailLine> = if content.trim().is_empty() {
                    vec![plain(&nothing)]
                } else {
                    content.lines().map(plain).collect()
                };
                let style = failed.then(|| theme.danger());
                section(&mut rows, &lines, all, width, theme, self.lang, style);
            }
            None => rows.push(Line::styled(
                strings::text(self.lang, "cli.chat.running"),
                theme.muted(),
            )),
        }
        rows
    }
}

fn plain(text: &str) -> DetailLine {
    DetailLine {
        kind: Kind::Plain,
        text: text.to_string(),
    }
}

/// How a kind of line looks.
fn style_of(kind: Kind, theme: &Theme) -> Style {
    match kind {
        Kind::Heading => theme.muted(),
        Kind::Plain => theme.text(),
        Kind::Same => theme.muted(),
        Kind::Added => theme.good(),
        Kind::Removed => theme.danger(),
    }
}

/// Lines wrapped to `width` after their marks, the rows after the first of a line under its text. Past
/// `MOST_LINES` a note says how many are left out, unless `all`. `style` takes the place of the look
/// of the lines.
fn section(
    rows: &mut Vec<Line<'static>>,
    lines: &[DetailLine],
    all: bool,
    width: usize,
    theme: &Theme,
    lang: strings::Lang,
    style: Option<Style>,
) {
    let shown = if all {
        lines.len()
    } else {
        lines.len().min(MOST_LINES)
    };
    for line in &lines[..shown] {
        let mark = line.kind.marker();
        let indent = " ".repeat(text_width(mark));
        let style = style.unwrap_or_else(|| style_of(line.kind, theme));
        let room = width.saturating_sub(text_width(mark));
        for (i, text) in wrap(&line.text, room).into_iter().enumerate() {
            let lead = if i == 0 { mark } else { &indent };
            rows.push(Line::from(Span::styled(format!("{lead}{text}"), style)));
        }
    }
    if shown < lines.len() {
        let count = (lines.len() - shown).to_string();
        rows.push(Line::styled(
            strings::format(lang, "cli.chat.detail_more", &[("count", &count)]),
            theme.muted(),
        ));
    }
}
