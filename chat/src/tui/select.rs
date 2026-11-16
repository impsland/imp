//! Choosing transcript text with the mouse. The chat takes the mouse for the wheel, so the terminal's
//! own selection does not work in it. This one does the same and copies what was chosen as soon as the
//! button is let go. Holding the mouse on the top row of the transcript, or below its last row, scrolls it.
//!
//! Places are rows of the whole transcript and columns on screen, so text that arrives below while
//! choosing does not move the choice. The marks at the start of rows (`●`, `›`, indents) are not copied,
//! and a paragraph that was wrapped is copied as the one line it was.

use super::text::{Join, slice_cols, text_width};
use super::view::Row;
use super::{Action, App};
use ratatui::buffer::Buffer;
use ratatui::layout::Rect;
use ratatui::style::{Modifier, Style};
use std::time::{Duration, Instant};

/// Two clicks this close together are a double click.
const DOUBLE_CLICK: Duration = Duration::from_millis(450);

/// How often the transcript scrolls while the mouse is held past its top or bottom. Slow enough that
/// the choice can be stopped on the row wanted.
pub(super) const EDGE_TICK: Duration = Duration::from_millis(100);

/// Lines a second the transcript scrolls while the mouse is held just past its edge (the first row past it).
/// Slow, so a page of a long chat takes a few seconds and the choice can be stopped where it is wanted.
const EDGE_LINES_PER_SECOND_NEAR: f64 = 2.0;

/// Lines a second at the most, reached when the mouse is `EDGE_FAR_ROWS` rows past the edge. Kept
/// low, so even a long chat can be chosen from the top to the bottom without the choice running away.
const EDGE_LINES_PER_SECOND_FAR: f64 = 8.0;

/// How many rows past the edge the mouse must be to scroll at the fastest rate.
const EDGE_FAR_ROWS: usize = 8;

/// The lines one [`EDGE_TICK`] scrolls, for a mouse `past` rows beyond the edge. Fractions add up
/// across ticks (see `App::on_edge_tick`), so a slow rate is smooth rather than stepped.
fn edge_lines_per_tick(past: usize) -> f64 {
    let far = (past.saturating_sub(1) as f64 / (EDGE_FAR_ROWS - 1) as f64).min(1.0);
    let per_second =
        EDGE_LINES_PER_SECOND_NEAR + (EDGE_LINES_PER_SECOND_FAR - EDGE_LINES_PER_SECOND_NEAR) * far;
    per_second * EDGE_TICK.as_secs_f64()
}

/// Where the transcript was drawn: its area (without the space above it on an empty chat), the first
/// row shown, and how many rows there were.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct View {
    pub area: Rect,
    pub first: usize,
    pub total: usize,
    /// The width and height the rows were made for.
    pub width: usize,
    pub height: usize,
}

/// A place in the transcript: a row and a column.
pub type Point = (usize, usize);

/// Text chosen from `anchor` (where the button went down) to `head` (where it is now), both included.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Selection {
    pub anchor: Point,
    pub head: Point,
}

impl Selection {
    /// The first and the last place, in reading order.
    pub fn ordered(&self) -> (Point, Point) {
        if self.anchor <= self.head {
            (self.anchor, self.head)
        } else {
            (self.head, self.anchor)
        }
    }

    /// The columns chosen on `row`, from and up to (not including). None if the row is not in it.
    pub fn columns(&self, row: usize) -> Option<(usize, usize)> {
        let (start, end) = self.ordered();
        if row < start.0 || row > end.0 {
            return None;
        }
        let from = if row == start.0 { start.1 } else { 0 };
        let to = if row == end.0 {
            end.1.saturating_add(1)
        } else {
            usize::MAX
        };
        Some((from, to))
    }
}

/// The text of a row as it shows.
pub fn row_text(row: &Row) -> String {
    row.line.spans.iter().map(|s| s.content.as_ref()).collect()
}

impl App {
    /// The transcript place under a cell of the screen, kept inside the rows that show.
    fn point_at(&self, column: u16, screen_row: u16) -> Option<Point> {
        let view = self.view.get();
        if view.total == 0 || view.area.height == 0 {
            return None;
        }
        let last_shown = (view.first + view.area.height as usize)
            .min(view.total)
            .saturating_sub(1);
        let row = if screen_row < view.area.y {
            view.first
        } else {
            (view.first + (screen_row - view.area.y) as usize).min(last_shown)
        };
        Some((row, column.saturating_sub(view.area.x) as usize))
    }

    fn inside_transcript(&self, column: u16, row: u16) -> bool {
        let area = self.view.get().area;
        // The rows above the text of an empty chat count too.
        row < area.bottom() && column >= area.x && column < area.right()
    }

    /// The rows as they were drawn, to read text from.
    fn drawn_rows(&self) -> Vec<Row> {
        let view = self.view.get();
        self.rows(view.width.max(1), Some(view.height))
    }

    /// The button went down: start choosing, or choose a word (two clicks) or a paragraph (three).
    pub(super) fn press(&mut self, column: u16, row: u16) -> Action {
        let count = match self.last_click {
            Some((at, c, r, n)) if at.elapsed() < DOUBLE_CLICK && c == column && r == row => {
                n % 3 + 1
            }
            _ => 1,
        };
        self.last_click = Some((Instant::now(), column, row, count));
        self.dragging = false;
        self.edge = None;
        if !self.inside_transcript(column, row) {
            self.selection.set(None);
            return Action::None;
        }
        let Some(point) = self.point_at(column, row) else {
            return Action::None;
        };
        let rows = self.drawn_rows();
        let chosen = match count {
            2 => word_at(&rows, point),
            3 => paragraph_at(&rows, point),
            _ => {
                self.dragging = true;
                self.selection.set(Some(Selection {
                    anchor: point,
                    head: point,
                }));
                return Action::None;
            }
        };
        self.selection.set(chosen);
        self.copy_selection()
    }

    /// The button moved while down: the choice follows it, and past an edge the transcript scrolls.
    pub(super) fn drag(&mut self, column: u16, row: u16) {
        if !self.dragging {
            return;
        }
        // On (or above) the first row there may be more above, as the transcript starts at the top of the
        // terminal. Below the last row is the message field.
        let view = self.view.get();
        let more_above = self.scroll.get() < self.max_scroll.get();
        let edge = if row <= view.area.y && more_above {
            Some((true, (view.area.y - row) as usize + 1))
        } else if row >= view.area.bottom() && self.scroll.get() > 0 {
            Some((false, (row - view.area.bottom()) as usize + 1))
        } else {
            None
        };
        // The first row past the edge scrolls one line at once. After that the ticks do, at a rate set by
        // how far past the edge the mouse is. Moving the mouse does not change that rate by itself.
        let started = self.edge.is_none();
        self.edge = edge;
        if let Some((up, _)) = self.edge {
            if started {
                self.edge_carry = 0.0;
                self.scroll_edge(up, 1);
            }
            return;
        }
        self.edge_carry = 0.0;
        if let (Some(point), Some(mut sel)) = (self.point_at(column, row), self.selection.get()) {
            sel.head = point;
            self.selection.set(Some(sel));
        }
    }

    /// One tick of scrolling while the mouse is held past an edge: whole lines of what has built up.
    pub fn on_edge_tick(&mut self) {
        if let (true, Some((up, past))) = (self.dragging, self.edge) {
            self.edge_carry += edge_lines_per_tick(past);
            let lines = self.edge_carry.floor();
            if lines >= 1.0 {
                self.edge_carry -= lines;
                self.scroll_edge(up, lines as usize);
            }
        }
    }

    fn scroll_edge(&mut self, up: bool, lines: usize) {
        self.scroll_by(lines, up);
        let view = self.view.get();
        let height = view.area.height as usize;
        let max = view.total.saturating_sub(height);
        let first = max - self.scroll.get().min(max);
        let head = if up {
            (first, 0)
        } else {
            (
                (first + height).min(view.total).saturating_sub(1),
                usize::MAX / 2,
            )
        };
        if let Some(mut sel) = self.selection.get() {
            sel.head = head;
            self.selection.set(Some(sel));
        }
    }

    /// The button was let go: copy what was chosen. A click without a drag chooses nothing.
    pub(super) fn release(&mut self) -> Action {
        if !self.dragging {
            return Action::None;
        }
        self.dragging = false;
        self.edge = None;
        match self.selection.get() {
            Some(sel) if sel.anchor != sel.head => self.copy_selection(),
            // A click without a drag: on a tool call's rows it opens that call in full.
            Some(sel) => {
                self.selection.set(None);
                if let Some(id) = self
                    .drawn_rows()
                    .get(sel.anchor.0)
                    .and_then(|row| row.call.clone())
                {
                    self.open_tool_detail(&id);
                }
                Action::None
            }
            None => Action::None,
        }
    }

    fn copy_selection(&mut self) -> Action {
        let text = self.selected_text();
        if text.is_empty() {
            self.selection.set(None);
            Action::None
        } else {
            Action::Copy(text)
        }
    }

    /// The chosen text: without the marks at the start of rows, with wrapped paragraphs joined again.
    pub fn selected_text(&self) -> String {
        let Some(sel) = self.selection.get() else {
            return String::new();
        };
        let rows = self.drawn_rows();
        let (start, end) = sel.ordered();
        let mut out = String::new();
        let chosen = rows
            .iter()
            .enumerate()
            .skip(start.0)
            .take(end.0 + 1 - start.0);
        for (r, row) in chosen {
            let Some((from, to)) = sel.columns(r) else {
                continue;
            };
            let piece = slice_cols(&row_text(row), from.max(row.gutter), to);
            if r > start.0 {
                match &row.join {
                    Join::Hard => {
                        let kept = out.trim_end_matches([' ', '\t']).len();
                        out.truncate(kept);
                        out.push('\n');
                    }
                    Join::Soft(sep) => out.push_str(sep),
                }
            }
            out.push_str(&piece);
        }
        out.trim_end().to_string()
    }

    /// Shows the chosen text reversed, on the rows of the transcript that are on screen.
    pub(super) fn paint_selection(&self, buffer: &mut Buffer, rows: &[Row]) {
        let Some(sel) = self.selection.get() else {
            return;
        };
        let view = self.view.get();
        for (i, row) in rows
            .iter()
            .enumerate()
            .skip(view.first)
            .take(view.area.height as usize)
        {
            let Some((from, to)) = sel.columns(i) else {
                continue;
            };
            let from = from.max(row.gutter);
            let to = to.min(text_width(&row_text(row)));
            if from >= to {
                continue;
            }
            let y = view.area.y + (i - view.first) as u16;
            let x = view.area.x + from as u16;
            let width = (to - from).min(view.area.right().saturating_sub(x) as usize) as u16;
            buffer.set_style(
                Rect::new(x, y, width, 1),
                Style::new().add_modifier(Modifier::REVERSED),
            );
        }
    }
}

/// The word under a place: the letters around it up to a space.
fn word_at(rows: &[Row], (r, col): Point) -> Option<Selection> {
    let row = rows.get(r)?;
    let text = row_text(row);
    let cells: Vec<(usize, char)> = {
        let mut at = 0;
        text.chars()
            .map(|c| {
                let start = at;
                at += text_width(c.encode_utf8(&mut [0; 4]));
                (start, c)
            })
            .collect()
    };
    let i = cells.iter().rposition(|(start, _)| *start <= col)?;
    if cells[i].1.is_whitespace() || cells[i].0 < row.gutter {
        return None;
    }
    let mut first = i;
    while first > 0 && !cells[first - 1].1.is_whitespace() && cells[first - 1].0 >= row.gutter {
        first -= 1;
    }
    let mut last = i;
    while last + 1 < cells.len() && !cells[last + 1].1.is_whitespace() {
        last += 1;
    }
    Some(Selection {
        anchor: (r, cells[first].0),
        head: (r, cells[last].0),
    })
}

/// The paragraph under a place: its row and the rows it was wrapped onto.
fn paragraph_at(rows: &[Row], (r, _): Point) -> Option<Selection> {
    rows.get(r)?;
    let mut first = r;
    while first > 0 && matches!(rows[first].join, Join::Soft(_)) {
        first -= 1;
    }
    let mut last = r;
    while last + 1 < rows.len() && matches!(rows[last + 1].join, Join::Soft(_)) {
        last += 1;
    }
    Some(Selection {
        anchor: (first, 0),
        head: (last, usize::MAX / 2),
    })
}
