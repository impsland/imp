//! Drawing the chat: the transcript, the message field, the status line and the help card.
//! No borders and no lines between things: groups are set apart by blank space and a soft fill.
//!
//! A tool call reads as `⏺ read_file(path: "README.md")` with its result under it (`⎿ …`), a message to
//! another Imp as `⇢ zed: …` and its answer as `⇠ …`. Lines from commands are dim and never part of
//! what the model sees. An empty chat shows the Imp in the middle, when there is room for it.
//!
//! The screen gives way on a short or narrow terminal: the field loses its blank rows, the picture and
//! then the folder and the help hint in the status line go, and the help card scrolls.

use super::markdown::{self, MdRow, wrap_styled};
use super::text::{Join, text_width, truncate, visible_start, wrap_joined};
use super::{App, MAX_INPUT_HEIGHT, field, help, select::View};
use crate::mentions;
use crate::slash::{Note, NoteKind};
use crate::strings;
use crate::transcript::{CallLine, call_line, cut, result_line};
use imp_engine::{ChatMessage, Role, ToolCall};
use ratatui::Frame;
use ratatui::layout::{Constraint, Layout, Position, Rect};
use ratatui::style::Style;
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
/// The frames of the spinner that shows the Imp is still at work.
const SPINNER: [&str; 10] = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"];
/// Below this height the message field has no blank rows around it.
const ROOMY: u16 = 10;
/// The Imp, for the empty chat.
const ART: &[&str] = &[
    "               ..wwwwww..",
    "     wWw .wWWWWWWWWWWWWWWWWWWw. wWw",
    "    wWWWww.WWWWWWWWWWWWWWWWWW.wwWWWw",
    "    WWWWWW.wWWWWWWWWWWWWWWWWw.WWWWWW",
    "   .wWWw.wWWWWWWWWWWWWWWWWWWWWw.wWWw.",
    " .WWwwwWWWWWWWWWWWWWWWWWWWWWwWWWWwwwWW.",
    " WWWWWWWWWWWWWWWWWWWWWWWWw    .WWWWWWWW",
    " WWWWWWWWW.  wWWWWWWWWWWW       WWWWWWW",
    ".WWWWWWWW.    WWWWWWWWWWw       WWWWWWW.",
    " WWWWWWWWw    WWWWWWWWWWW      wWWWWWWW",
    "  WWWWWWWWWwwWWWWWWWWWWWWWw. .wWWWWWWW",
    "   wWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWw",
    "    wWWWWWWWWWWWWWWWWWWWWWWWWWWWWWw",
];

/// One row of the transcript: how it looks, how many columns at its start are marks rather than text,
/// and how it joins the row above when copied.
#[derive(Debug, Clone)]
pub struct Row {
    pub line: Line<'static>,
    pub gutter: usize,
    pub join: Join,
}

impl Row {
    fn new(line: Line<'static>, gutter: usize) -> Self {
        Self {
            line,
            gutter,
            join: Join::Hard,
        }
    }

    fn blank() -> Self {
        Self::new(Line::raw(""), 0)
    }
}

impl App {
    /// The transcript as lines of the given width.
    pub fn transcript(&self, width: usize) -> Vec<Line<'static>> {
        self.rows(width, None).into_iter().map(|r| r.line).collect()
    }

    /// Whether nothing has been said yet, so the empty screen shows.
    fn is_empty_chat(&self) -> bool {
        self.chat.messages().is_empty()
            && !self.chat.is_streaming()
            && self.visiting.as_ref().is_none_or(|v| v.partial.is_none())
    }

    /// The transcript as rows of the given width. `height`: the room it has, to know whether the Imp
    /// fits on the empty screen (None leaves it out).
    pub(super) fn rows(&self, width: usize, height: Option<usize>) -> Vec<Row> {
        let mut rows = Vec::new();
        let messages = self.chat.messages();
        let mut notes = self.notes.iter().peekable();
        for (i, message) in messages.iter().enumerate() {
            let run: Vec<&Note> = std::iter::from_fn(|| notes.next_if(|(at, _)| *at <= i))
                .map(|(_, n)| n)
                .collect();
            self.push_notes(&mut rows, &run, width);
            self.push_message(&mut rows, message, &messages[i + 1..], width);
        }
        let streaming = self.streaming();
        if !streaming.is_empty() {
            self.push_answer(&mut rows, &format!("{streaming}▌"), width);
        } else if self.waiting && self.tool.is_none() {
            self.push_thinking(&mut rows, width);
        }
        let run: Vec<&Note> = notes.map(|(_, n)| n).collect();
        self.push_notes(&mut rows, &run, width);
        if let Some(error) = &self.error {
            let sentence = strings::format(self.lang, "cli.chat.error", &[("error", error)]);
            marked(&mut rows, "✕", self.theme.danger(), &sentence, width);
        }
        if self.is_empty_chat() {
            let mut all = self.welcome(width, height, rows.len());
            all.extend(rows);
            return all;
        }
        rows
    }

    /// The Imp's own mark: its colour, or the visitor's.
    fn mark_style(&self) -> Style {
        match &self.visiting {
            Some(v) => self.theme.hue(v.hue),
            None => self.theme.imp(),
        }
    }

    /// The empty screen: the Imp when it fits, how to start, and what the folder adds. Who the Imp is and
    /// where it works are in the status line, so they are not said twice. `below`: rows that follow.
    fn welcome(&self, width: usize, height: Option<usize>, below: usize) -> Vec<Row> {
        let muted = self.theme.muted();
        let text_width_max = width.saturating_sub(4).clamp(1, 64);
        let mut words = wrap_joined(
            strings::text(self.lang, "cli.chat.welcome_hint"),
            text_width_max,
        );
        if !self.context.is_empty() {
            words.extend(wrap_joined(&self.context, text_width_max));
        }
        let art_width = ART.iter().map(|l| text_width(l)).max().unwrap_or(0);
        let art_rows = ART.len() + 1;
        let with_art = height.is_some_and(|h| h >= art_rows + words.len() + below + 2)
            && width >= art_width + 2;
        let centered = |text: &str, block: usize, style: Style, join: Join| {
            let pad = width.saturating_sub(block) / 2;
            Row {
                line: Line::from(vec![
                    Span::raw(" ".repeat(pad)),
                    Span::styled(text.to_string(), style),
                ]),
                gutter: pad,
                join,
            }
        };
        let mut rows = Vec::new();
        if with_art {
            for line in ART {
                rows.push(centered(line, art_width, self.mark_style(), Join::Hard));
            }
            rows.push(Row::blank());
        }
        for (line, join) in words {
            rows.push(centered(&line, text_width(&line), muted, join));
        }
        rows.push(Row::blank());
        rows
    }

    /// Notes that came together, such as what one command said: a blank row before and after them,
    /// and before each command typed. The labels of fields in a row line up.
    fn push_notes(&self, rows: &mut Vec<Row>, notes: &[&Note], width: usize) {
        if notes.is_empty() {
            return;
        }
        gap(rows);
        for (i, note) in notes.iter().enumerate() {
            if note.kind == NoteKind::Command && i > 0 {
                gap(rows);
            }
            if note.kind == NoteKind::Heading && i > 0 && notes[i - 1].kind != NoteKind::Command {
                gap(rows);
            }
            let label = match note.kind {
                NoteKind::Field => notes[i..]
                    .iter()
                    .take_while(|n| n.kind == NoteKind::Field)
                    .chain(
                        notes[..i]
                            .iter()
                            .rev()
                            .take_while(|n| n.kind == NoteKind::Field),
                    )
                    .map(|n| text_width(&n.label))
                    .max()
                    .unwrap_or(0)
                    .min(width / 3),
                _ => 0,
            };
            self.push_note(rows, note, label, width);
        }
        rows.push(Row::blank());
    }

    /// One note. `label`: the width of the labels of the fields around it.
    fn push_note(&self, rows: &mut Vec<Row>, note: &Note, label: usize, width: usize) {
        let theme = &self.theme;
        let muted = theme.muted();
        match note.kind {
            NoteKind::Command => {
                lead_rows(
                    rows,
                    vec![Span::styled(format!("{YOU} "), self.mark_style())],
                    &[(note.text.clone(), theme.strong())],
                    width,
                );
            }
            NoteKind::Heading => {
                let parts = markdown::inline(&note.text, theme.heading(false), theme);
                lead_rows(rows, vec![Span::raw("  ")], &parts, width);
            }
            NoteKind::Info => {
                let parts = markdown::inline(&note.text, muted, theme);
                lead_rows(rows, vec![Span::raw("  ")], &parts, width);
            }
            NoteKind::Field => {
                let name = truncate(&note.label, label);
                let pad = " ".repeat(label.saturating_sub(text_width(&name)) + 2);
                let parts = markdown::inline(&note.text, theme.text(), theme);
                lead_rows(
                    rows,
                    vec![Span::raw("  "), Span::styled(format!("{name}{pad}"), muted)],
                    &parts,
                    width,
                );
            }
            NoteKind::On | NoteKind::Off => {
                let on = note.kind == NoteKind::On;
                let (mark, style, base) = if on {
                    ("✓ ", theme.good(), theme.text())
                } else {
                    ("· ", muted, muted)
                };
                let parts = markdown::inline(&note.text, base, theme);
                lead_rows(
                    rows,
                    vec![Span::raw("  "), Span::styled(mark, style)],
                    &parts,
                    width,
                );
            }
            NoteKind::Problem => marked(rows, "✕", theme.danger(), &note.text, width),
            NoteKind::Code => {
                rows.push(Row::new(
                    Line::from(vec![
                        Span::raw("  "),
                        Span::styled(note.text.clone(), theme.code()),
                    ]),
                    2,
                ));
            }
        }
    }

    /// An answer in Markdown, led by the Imp's mark.
    fn push_answer(&self, rows: &mut Vec<Row>, text: &str, width: usize) {
        for (i, md) in markdown::render(text, width.saturating_sub(2), &self.theme)
            .into_iter()
            .enumerate()
        {
            let lead = if i == 0 {
                Span::styled(format!("{IMP} "), self.mark_style())
            } else {
                Span::raw("  ")
            };
            rows.push(md_row(lead, md));
        }
    }

    /// While the Imp thinks: a spinner, for how long, and how to stop it, so it never looks stuck.
    fn push_thinking(&self, rows: &mut Vec<Row>, width: usize) {
        let thinking = strings::text(self.lang, "cli.chat.thinking");
        let stop = strings::text(self.lang, "cli.chat.stop_hint");
        let line = format!("{thinking}…{} · {stop}", self.seconds());
        rows.push(Row::new(
            Line::from(vec![
                Span::styled(format!("{} ", self.spinner()), self.mark_style()),
                Span::styled(truncate(&line, width.saturating_sub(2)), self.theme.muted()),
            ]),
            2,
        ));
    }

    /// One message. `after` is the rest of the conversation, where the results of its tool calls are.
    fn push_message(
        &self,
        rows: &mut Vec<Row>,
        message: &ChatMessage,
        after: &[ChatMessage],
        width: usize,
    ) {
        match message.role {
            Role::User => {
                // Files picked with @ went to the model. The chat names them under what was written.
                let (text, files) = mentions::shown(&message.content);
                marked(rows, YOU, self.theme.muted(), text, width);
                if !files.is_empty() {
                    let said = strings::format(
                        self.lang,
                        "cli.chat.attached",
                        &[("files", &files.join(", "))],
                    );
                    indented(rows, RESULT, self.theme.muted(), &said, width);
                }
                rows.push(Row::blank());
            }
            Role::Assistant => {
                if !message.content.is_empty() {
                    self.push_answer(rows, &message.content, width);
                }
                for call in &message.tool_calls {
                    self.push_call(rows, call, after, width);
                }
                if !message.content.is_empty() || !message.tool_calls.is_empty() {
                    rows.push(Row::blank());
                }
            }
            // Results show under their calls.
            Role::Tool | Role::System => {}
        }
    }

    fn push_call(&self, rows: &mut Vec<Row>, call: &ToolCall, after: &[ChatMessage], width: usize) {
        let muted = self.theme.muted();
        let result = after
            .iter()
            .find(|m| m.role == Role::Tool && m.tool_call_id.as_deref() == Some(&call.id))
            .map(|m| m.content.as_str());
        match call_line(&call.name, &call.arguments) {
            CallLine::Tool(text) => {
                marked(rows, CALL, self.mark_style(), &text, width);
                let (said, style) = match result.map(result_line) {
                    Some((text, false)) => (text, muted),
                    Some((text, true)) => (text, self.theme.danger()),
                    None => (
                        format!(
                            "{} {}{}",
                            self.spinner(),
                            strings::text(self.lang, "cli.chat.running"),
                            self.seconds()
                        ),
                        muted,
                    ),
                };
                indented(rows, RESULT, style, &said, width);
            }
            CallLine::Message { to, text } => {
                let asked = format!("{to}: {text}");
                marked(rows, ASK, self.mark_style(), &asked, width);
                let answer = cut(result.unwrap_or_default().trim(), 600);
                let (said, style) = match result.map(result_line) {
                    Some((_, true)) => (answer, self.theme.danger()),
                    Some(_) => (answer, self.theme.text()),
                    None => (
                        format!(
                            "{} {}",
                            self.spinner(),
                            strings::format(self.lang, "cli.chat.waiting_for", &[("imp", &to)])
                        ),
                        muted,
                    ),
                };
                indented(rows, ANSWER, style, &said, width);
            }
        }
    }

    pub fn render(&self, frame: &mut Frame) {
        let area = frame.area();
        if area.width == 0 || area.height == 0 {
            return;
        }
        // On a short screen the field loses its blank rows, and on a tiny one the status line goes.
        let pad: u16 = if area.height >= ROOMY { 1 } else { 0 };
        let status_height: u16 = if area.height >= 3 { 1 } else { 0 };
        let field_width = (area.width as usize)
            .saturating_sub(FIELD_INDENT as usize + 1)
            .max(1);
        self.field_width.set(field_width);
        let field_rows = field::layout(&self.input, field_width);
        let smallest = 1 + 2 * pad;
        let tallest = MAX_INPUT_HEIGHT.min(area.height / 2).max(smallest);
        let input_height = (field_rows.len() as u16 + 2 * pad)
            .clamp(smallest, tallest)
            .min(area.height.saturating_sub(status_height));
        let room = area.height.saturating_sub(input_height + status_height + 1) as usize;
        let popup = self.popup(room, area.width as usize);
        let below = popup.len() as u16;
        let [top, field, hints, status] = Layout::vertical([
            Constraint::Min(0),
            Constraint::Length(input_height),
            Constraint::Length(below),
            Constraint::Length(status_height),
        ])
        .areas(area);
        self.render_transcript(frame, top);
        let cursor = field::cursor_cell(&self.input, &field_rows, self.cursor);
        let lines = field::row_texts(&self.input, &field_rows);
        self.render_field(frame, field, &lines, cursor, pad);
        if below > 0 {
            frame.render_widget(Paragraph::new(popup), hints);
        }
        if status_height > 0 {
            frame.render_widget(
                Paragraph::new(self.status_line(status.width as usize)),
                status,
            );
        }
        if self.help {
            help::render(self, frame, area);
        }
    }

    /// The rows that fit, from the bottom or as far up as it is scrolled. An empty chat is in the middle.
    /// While scrolled up, rows that arrive below raise the scroll by as much, so the view stays still.
    fn render_transcript(&self, frame: &mut Frame, area: Rect) {
        let width = area.width.max(1) as usize;
        let height = area.height as usize;
        let rows = self.rows(width, Some(height));
        let total = rows.len();
        let before = self.view.get();
        if before.width == width && total > before.total && self.scroll.get() > 0 {
            self.scroll.set(self.scroll.get() + total - before.total);
        }
        if before.width != width || total < before.total {
            // The rows were made again differently, so the chosen places no longer mean the same text.
            self.selection.set(None);
        }
        let (start, max) = visible_start(total, height, self.scroll.get());
        self.scroll.set(self.scroll.get().min(max));
        self.viewport.set(height);
        self.max_scroll.set(max);
        let top = if self.is_empty_chat() && total < height {
            ((height - total) / 2) as u16
        } else {
            0
        };
        let shown_area = Rect::new(area.x, area.y + top, area.width, area.height - top);
        self.view.set(View {
            area: shown_area,
            first: start,
            total,
            width,
            height,
        });
        let shown: Vec<Line> = rows
            .iter()
            .skip(start)
            .take(height)
            .map(|r| r.line.clone())
            .collect();
        frame.render_widget(Paragraph::new(shown), shown_area);
        self.paint_selection(frame.buffer_mut(), &rows);
    }

    /// The message field: a soft fill with `pad` blank rows above and below, no border.
    fn render_field(
        &self,
        frame: &mut Frame,
        area: Rect,
        lines: &[&str],
        cursor: (usize, usize),
        pad: u16,
    ) {
        frame.buffer_mut().set_style(area, self.theme.card());
        let inner = area.height.saturating_sub(2 * pad).max(1) as usize;
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
                        Span::raw(l.to_string()),
                    ])
                })
                .collect()
        };
        let body = Rect::new(area.x, area.y + pad, area.width, inner as u16).intersection(area);
        frame.render_widget(Paragraph::new(shown), body);
        let row = cursor.0.saturating_sub(skip).min(inner.saturating_sub(1)) as u16;
        let x = (area.x + FIELD_INDENT + cursor.1 as u16).min(area.right().saturating_sub(1));
        let y = (area.y + pad + row).min(area.bottom().saturating_sub(1));
        frame.set_cursor_position(Position::new(x, y));
    }

    /// The Imp's mark, its name, brain and folder on the left, then what it is doing and a hint on the
    /// right. What does not fit goes: first the end of the folder's path, then the folder, then the hint.
    fn status_line(&self, width: usize) -> Line<'static> {
        let muted = self.theme.muted();
        let open = !self.menu().entries.is_empty();
        let hint_key = if open {
            "cli.chat.menu_hint"
        } else if self.scroll.get() > 0 {
            "cli.chat.scrolled_hint"
        } else {
            "cli.chat.help_hint"
        };
        let hint = strings::text(self.lang, hint_key);
        let activity = self.activity();
        let full = format!("{activity} · {hint} ");
        let short = format!("{activity} ");
        let head = format!(" {} · {}", self.imp, self.model);
        // The mark, the left side, at least one space, and the right side.
        let fits = |left: &str, right: &str| 2 + text_width(left) + text_width(right) <= width;
        let room_for_folder = width.saturating_sub(2 + text_width(&head) + 3 + text_width(&full));
        let (left, right) = if self.folder.is_empty() {
            (head.clone(), full.clone())
        } else if fits(&format!("{head} · {}", self.folder), &full) {
            (format!("{head} · {}", self.folder), full.clone())
        } else if room_for_folder >= 10 {
            (
                format!("{head} · {}", shorten_path(&self.folder, room_for_folder)),
                full.clone(),
            )
        } else {
            (head.clone(), full.clone())
        };
        let (left, right) = if fits(&left, &right) {
            (left, right)
        } else if fits(&head, &full) {
            (head, full)
        } else {
            let left = truncate(&head, width.saturating_sub(text_width(&short) + 2));
            (left, short)
        };
        let gap = width.saturating_sub(1 + text_width(&left) + text_width(&right));
        Line::from(vec![
            Span::styled(IMP, self.mark_style()),
            Span::styled(left, muted),
            Span::raw(" ".repeat(gap)),
            Span::styled(truncate(&right, width.saturating_sub(1)), muted),
        ])
    }
}

/// A path cut to `most` columns from the left, keeping whole folder names where it can: `…/Developer/imp`.
fn shorten_path(path: &str, most: usize) -> String {
    if text_width(path) <= most {
        return path.to_string();
    }
    let parts: Vec<&str> = path.split('/').filter(|p| !p.is_empty()).collect();
    let mut tail = String::new();
    for part in parts.iter().rev() {
        let next = if tail.is_empty() {
            part.to_string()
        } else {
            format!("{part}/{tail}")
        };
        if text_width(&next) + 2 > most {
            break;
        }
        tail = next;
    }
    if tail.is_empty() {
        return truncate(parts.last().copied().unwrap_or(path), most);
    }
    format!("…/{tail}")
}

/// The spinner's frame `ms` milliseconds after the answer was asked for.
pub(super) fn spinner_frame(ms: u128) -> &'static str {
    SPINNER[(ms / 100) as usize % SPINNER.len()]
}

/// A blank row, unless the last row is blank or there is none.
fn gap(rows: &mut Vec<Row>) {
    let blank = rows
        .last()
        .is_none_or(|r| r.line.spans.iter().all(|s| s.content.trim().is_empty()));
    if !blank {
        rows.push(Row::blank());
    }
}

/// Styled text wrapped after `lead`, the rows after the first indented under the text.
fn lead_rows(
    rows: &mut Vec<Row>,
    lead: Vec<Span<'static>>,
    parts: &[(String, Style)],
    width: usize,
) {
    let lead_width: usize = lead.iter().map(|s| text_width(&s.content)).sum();
    for (i, (spans, join)) in wrap_styled(parts, width.saturating_sub(lead_width).max(1))
        .into_iter()
        .enumerate()
    {
        let mut line = if i == 0 {
            lead.clone()
        } else {
            vec![Span::raw(" ".repeat(lead_width))]
        };
        line.extend(spans);
        rows.push(Row {
            line: Line::from(line),
            gutter: lead_width,
            join,
        });
    }
}

/// A row of an answer: the mark (or its space), the row's indent, then its text.
fn md_row(lead: Span<'static>, md: MdRow) -> Row {
    let lead_width = text_width(&lead.content);
    let mut spans = vec![lead];
    if md.indent > 0 {
        spans.push(Span::raw(" ".repeat(md.indent)));
    }
    spans.extend(md.spans);
    Row {
        line: Line::from(spans),
        gutter: lead_width + md.indent,
        join: md.join,
    }
}

/// Rows of `text` wrapped to `width`, the first led by `mark` and the rest indented under the text.
fn marked(rows: &mut Vec<Row>, mark: &str, mark_style: Style, text: &str, width: usize) {
    for (i, (line, join)) in wrap_joined(text, width.saturating_sub(2))
        .into_iter()
        .enumerate()
    {
        let lead = if i == 0 {
            mark.to_string()
        } else {
            " ".to_string()
        };
        let lead = format!("{lead} ");
        rows.push(Row {
            gutter: text_width(&lead),
            line: Line::from(vec![Span::styled(lead, mark_style), Span::raw(line)]),
            join,
        });
    }
}

/// Like `marked`, two columns in and all in `style`: what came back from a call.
fn indented(rows: &mut Vec<Row>, mark: &str, style: Style, text: &str, width: usize) {
    for (i, (line, join)) in wrap_joined(text, width.saturating_sub(4))
        .into_iter()
        .enumerate()
    {
        let lead = format!("  {} ", if i == 0 { mark } else { " " });
        rows.push(Row {
            gutter: text_width(&lead),
            line: Line::styled(format!("{lead}{line}"), style),
            join,
        });
    }
}

#[cfg(test)]
mod tests {
    use super::shorten_path;

    #[test]
    fn a_long_folder_keeps_its_last_names() {
        assert_eq!(shorten_path("~/a/b", 20), "~/a/b");
        assert_eq!(shorten_path("~/Developer/apps/imp", 16), "…/apps/imp");
        assert_eq!(shorten_path("/x/averyveryverylongname", 10), "averyvery…");
    }
}
