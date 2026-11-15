//! Answers as the model writes them, in Markdown, drawn for a terminal: **bold**, *italic*, `code`,
//! headings, lists, quotes, code blocks, links and tables. The CommonMark parser is `pulldown-cmark`.
//! Nothing is drawn with box lines: blocks are set apart by indentation, blank lines and a soft fill.
//!
//! Each row says how it joins the row above (see [`Join`]), so text chosen with the mouse is copied
//! as the paragraphs it was, and code is copied as it was written.

use super::text::{Join, text_width};
use crate::theme::Theme;
use pulldown_cmark::{CodeBlockKind, Event, HeadingLevel, Options, Parser, Tag, TagEnd};
use ratatui::style::{Modifier, Style};
use ratatui::text::Span;

/// One row: its spans after the indent, the columns of indent before them, and how it joins the row above.
#[derive(Debug, Clone)]
pub struct MdRow {
    pub indent: usize,
    pub spans: Vec<Span<'static>>,
    pub join: Join,
}

impl MdRow {
    fn blank() -> Self {
        Self {
            indent: 0,
            spans: Vec::new(),
            join: Join::Hard,
        }
    }

    pub fn is_blank(&self) -> bool {
        self.spans.iter().all(|s| s.content.trim().is_empty())
    }
}

/// A list being drawn: the next number of an ordered one.
struct List {
    next: Option<u64>,
}

struct Renderer<'t> {
    theme: &'t Theme,
    width: usize,
    rows: Vec<MdRow>,
    /// The styled words of the block being read.
    segments: Vec<(String, Style)>,
    styles: Vec<Style>,
    /// Indent of the current block, and what goes before its first row (a bullet).
    indent: usize,
    lead: Option<String>,
    lists: Vec<List>,
    quote: usize,
    heading: Option<HeadingLevel>,
    code: Option<String>,
    link: Option<String>,
    table: Option<Vec<Vec<String>>>,
    cell: Option<String>,
}

/// The rows of `text` for a width, below a mark that the caller draws.
pub fn render(text: &str, width: usize, theme: &Theme) -> Vec<MdRow> {
    let mut r = Renderer {
        theme,
        width: width.max(4),
        rows: Vec::new(),
        segments: Vec::new(),
        styles: vec![theme.text()],
        indent: 0,
        lead: None,
        lists: Vec::new(),
        quote: 0,
        heading: None,
        code: None,
        link: None,
        table: None,
        cell: None,
    };
    let options =
        Options::ENABLE_TABLES | Options::ENABLE_STRIKETHROUGH | Options::ENABLE_TASKLISTS;
    for event in Parser::new_ext(text, options) {
        r.event(event);
    }
    r.flush();
    while r.rows.last().is_some_and(MdRow::is_blank) {
        r.rows.pop();
    }
    if r.rows.is_empty() {
        r.rows.push(MdRow::blank());
    }
    r.rows
}

impl Renderer<'_> {
    fn style(&self) -> Style {
        *self.styles.last().unwrap_or(&Style::default())
    }

    fn push_style(&mut self, f: impl FnOnce(Style) -> Style) {
        let next = f(self.style());
        self.styles.push(next);
    }

    fn text(&mut self, t: &str) {
        if let Some(cell) = &mut self.cell {
            cell.push_str(t);
            return;
        }
        if let Some(code) = &mut self.code {
            code.push_str(t);
            return;
        }
        let style = self.style();
        self.segments.push((t.to_string(), style));
    }

    /// A blank row between blocks, never two and never first.
    fn gap(&mut self) {
        if self.rows.last().is_some_and(|r| !r.is_blank()) {
            self.rows.push(MdRow::blank());
        }
    }

    fn event(&mut self, event: Event) {
        match event {
            Event::Start(tag) => self.start(tag),
            Event::End(tag) => self.end(tag),
            Event::Text(t) => self.text(&t),
            Event::Code(t) => {
                if let Some(cell) = &mut self.cell {
                    cell.push_str(&t);
                } else {
                    let style = self.theme.inline_code();
                    self.segments.push((t.to_string(), style));
                }
            }
            // In a chat, a line break the model wrote is meant: an address, a poem, steps.
            Event::SoftBreak => self.flush_keep_lead(),
            Event::HardBreak => {
                self.flush_keep_lead();
            }
            Event::Rule => {
                self.flush();
                self.gap();
            }
            Event::TaskListMarker(done) => {
                self.lead = Some(if done { "☑ " } else { "☐ " }.into());
            }
            Event::Html(t) | Event::InlineHtml(t) => self.text(&t),
            Event::FootnoteReference(t) => self.text(&format!("[{t}]")),
            Event::InlineMath(t) | Event::DisplayMath(t) => self.text(&t),
        }
    }

    fn start(&mut self, tag: Tag) {
        match tag {
            Tag::Paragraph => {}
            Tag::Heading { level, .. } => {
                self.flush();
                self.gap();
                self.heading = Some(level);
                let style = self.theme.heading(level == HeadingLevel::H1);
                self.styles.push(style);
            }
            Tag::BlockQuote(_) => {
                self.flush();
                self.quote += 1;
                self.indent += 2;
                self.push_style(|s| s.add_modifier(Modifier::ITALIC | Modifier::DIM));
            }
            Tag::CodeBlock(kind) => {
                self.flush();
                self.gap();
                let lang = match kind {
                    CodeBlockKind::Fenced(l) => l.to_string(),
                    CodeBlockKind::Indented => String::new(),
                };
                if !lang.trim().is_empty() {
                    self.rows.push(MdRow {
                        indent: self.indent,
                        spans: vec![Span::styled(lang.trim().to_string(), self.theme.muted())],
                        join: Join::Hard,
                    });
                }
                self.code = Some(String::new());
            }
            Tag::List(first) => {
                self.flush();
                if self.lists.is_empty() {
                    self.gap();
                } else {
                    self.indent += 2;
                }
                self.lists.push(List { next: first });
            }
            Tag::Item => {
                self.flush();
                let lead = match self.lists.last_mut().and_then(|l| l.next.as_mut()) {
                    Some(n) => {
                        let lead = format!("{n}. ");
                        *n += 1;
                        lead
                    }
                    None => "• ".into(),
                };
                self.lead = Some(lead);
            }
            Tag::Emphasis => self.push_style(|s| s.add_modifier(Modifier::ITALIC)),
            Tag::Strong => self.push_style(|s| s.add_modifier(Modifier::BOLD)),
            Tag::Strikethrough => self.push_style(|s| s.add_modifier(Modifier::CROSSED_OUT)),
            Tag::Link { dest_url, .. } => {
                self.link = Some(dest_url.to_string());
                let link = self.theme.link();
                self.push_style(|s| s.patch(link));
            }
            Tag::Image { dest_url, .. } => {
                self.link = Some(dest_url.to_string());
                self.text("[");
            }
            Tag::Table(_) => {
                self.flush();
                self.gap();
                self.table = Some(Vec::new());
            }
            Tag::TableHead | Tag::TableRow => {
                if let Some(t) = &mut self.table {
                    t.push(Vec::new());
                }
            }
            Tag::TableCell => self.cell = Some(String::new()),
            _ => {}
        }
    }

    fn end(&mut self, tag: TagEnd) {
        match tag {
            TagEnd::Paragraph => {
                self.flush();
                if self.lists.is_empty() {
                    self.gap();
                }
            }
            TagEnd::Heading(_) => {
                self.flush();
                self.styles.pop();
                self.heading = None;
            }
            TagEnd::BlockQuote(_) => {
                self.flush();
                self.quote = self.quote.saturating_sub(1);
                self.indent = self.indent.saturating_sub(2);
                self.styles.pop();
                self.gap();
            }
            TagEnd::CodeBlock => {
                let code = self.code.take().unwrap_or_default();
                self.code_rows(&code);
                self.gap();
            }
            TagEnd::List(_) => {
                self.flush();
                self.lists.pop();
                if self.lists.is_empty() {
                    self.gap();
                } else {
                    self.indent = self.indent.saturating_sub(2);
                }
            }
            TagEnd::Item => self.flush(),
            TagEnd::Emphasis | TagEnd::Strong | TagEnd::Strikethrough => {
                self.styles.pop();
            }
            TagEnd::Link => {
                self.styles.pop();
                let url = self.link.take().unwrap_or_default();
                // The address shows when the words are not the address.
                let said: String = self
                    .segments
                    .iter()
                    .rev()
                    .take(3)
                    .map(|(t, _)| t.as_str())
                    .collect();
                if !url.is_empty() && !said.contains(url.as_str()) && !url.starts_with('#') {
                    self.segments
                        .push((format!(" ({url})"), self.theme.muted()));
                }
            }
            TagEnd::Image => {
                let url = self.link.take().unwrap_or_default();
                self.text(&format!("] ({url})"));
            }
            TagEnd::TableCell => {
                let cell = self.cell.take().unwrap_or_default();
                if let Some(row) = self.table.as_mut().and_then(|t| t.last_mut()) {
                    row.push(cell.trim().to_string());
                }
            }
            TagEnd::Table => {
                let table = self.table.take().unwrap_or_default();
                self.table_rows(&table);
                self.gap();
            }
            _ => {}
        }
    }

    /// Wraps what was read into rows, the first led by the block's bullet.
    fn flush(&mut self) {
        self.flush_rows();
        self.lead = None;
    }

    /// The same, for a hard line break inside a block: the rows that follow line up under it.
    fn flush_keep_lead(&mut self) {
        let lead = self.lead.clone();
        self.flush_rows();
        self.lead = lead.map(|l| " ".repeat(text_width(&l)));
    }

    fn flush_rows(&mut self) {
        if self.segments.is_empty() {
            if let Some(lead) = self.lead.take() {
                // An empty item still shows its bullet.
                self.rows.push(MdRow {
                    indent: self.indent,
                    spans: vec![Span::styled(lead, self.theme.bullet())],
                    join: Join::Hard,
                });
            }
            return;
        }
        let segments = std::mem::take(&mut self.segments);
        let lead = self.lead.take().unwrap_or_default();
        let lead_width = text_width(&lead);
        let room = self.width.saturating_sub(self.indent + lead_width).max(1);
        for (i, (spans, join)) in wrap_styled(&segments, room).into_iter().enumerate() {
            let mut row_spans = Vec::new();
            if lead_width > 0 {
                row_spans.push(if i == 0 {
                    Span::styled(lead.clone(), self.theme.bullet())
                } else {
                    Span::raw(" ".repeat(lead_width))
                });
            }
            row_spans.extend(spans);
            self.rows.push(MdRow {
                indent: self.indent,
                spans: row_spans,
                join: if i == 0 { Join::Hard } else { join },
            });
        }
    }

    /// Code as it was written, on a soft fill, long lines cut into rows that join with nothing.
    fn code_rows(&mut self, code: &str) {
        let room = self.width.saturating_sub(self.indent).max(1);
        let style = self.theme.code_block();
        for line in code.trim_end_matches('\n').split('\n') {
            let line = line.replace('\t', "    ");
            for (i, piece) in split_cols(&line, room).into_iter().enumerate() {
                let pad = room.saturating_sub(text_width(&piece));
                self.rows.push(MdRow {
                    indent: self.indent,
                    spans: vec![Span::styled(format!("{piece}{}", " ".repeat(pad)), style)],
                    join: if i == 0 {
                        Join::Hard
                    } else {
                        Join::Soft(String::new())
                    },
                });
            }
        }
    }

    /// A table: columns as wide as their widest cell (cut to fit), the header in bold.
    fn table_rows(&mut self, table: &[Vec<String>]) {
        let columns = table.iter().map(Vec::len).max().unwrap_or(0);
        if columns == 0 {
            return;
        }
        let gap = 2;
        let mut widths: Vec<usize> = (0..columns)
            .map(|c| {
                table
                    .iter()
                    .filter_map(|r| r.get(c))
                    .map(|s| text_width(s))
                    .max()
                    .unwrap_or(0)
            })
            .collect();
        let room = self.width.saturating_sub(self.indent);
        // Narrow the widest column until the table fits.
        while widths.iter().sum::<usize>() + gap * (columns - 1) > room {
            let (i, w) = widths
                .iter()
                .enumerate()
                .max_by_key(|(_, w)| **w)
                .map(|(i, w)| (i, *w))
                .unwrap_or((0, 0));
            if w <= 3 {
                break;
            }
            widths[i] = w - 1;
        }
        for (r, row) in table.iter().enumerate() {
            let style = if r == 0 {
                self.theme.text().add_modifier(Modifier::BOLD)
            } else {
                self.theme.text()
            };
            let mut spans = Vec::new();
            for (c, width) in widths.iter().enumerate() {
                let cell = row.get(c).map_or("", String::as_str);
                let cut = super::text::truncate(cell, *width);
                let pad =
                    width.saturating_sub(text_width(&cut)) + if c + 1 < columns { gap } else { 0 };
                spans.push(Span::styled(cut, style));
                spans.push(Span::raw(" ".repeat(pad)));
            }
            self.rows.push(MdRow {
                indent: self.indent,
                spans,
                join: Join::Hard,
            });
        }
    }
}

/// `s` cut into pieces of at most `width` columns.
fn split_cols(s: &str, width: usize) -> Vec<String> {
    let mut out = vec![String::new()];
    let mut used = 0;
    for c in s.chars() {
        let w = text_width(c.encode_utf8(&mut [0; 4]));
        if used + w > width && used > 0 {
            out.push(String::new());
            used = 0;
        }
        out.last_mut().expect("one piece").push(c);
        used += w;
    }
    out
}

/// Styled text wrapped to `width` columns at spaces (long words are broken), with how each row
/// joins the one before: the space the wrap took, or nothing inside a broken word.
pub fn wrap_styled(segments: &[(String, Style)], width: usize) -> Vec<(Vec<Span<'static>>, Join)> {
    // Words with their style pieces, and whether a space came before each.
    let mut words: Vec<(bool, Vec<(String, Style)>)> = Vec::new();
    let mut space_before = false;
    for (text, style) in segments {
        for (i, part) in text.split(' ').enumerate() {
            if i > 0 {
                space_before = true;
            }
            if part.is_empty() {
                continue;
            }
            match words.last_mut() {
                Some((_, pieces)) if !space_before => pieces.push((part.to_string(), *style)),
                _ => words.push((space_before, vec![(part.to_string(), *style)])),
            }
            space_before = false;
        }
    }
    let mut out: Vec<(Vec<Span<'static>>, Join)> = Vec::new();
    let mut line: Vec<Span<'static>> = Vec::new();
    let mut used = 0;
    let mut join = Join::Hard;
    for (spaced, pieces) in words {
        let word_width: usize = pieces.iter().map(|(t, _)| text_width(t)).sum();
        let sep = if spaced && used > 0 { 1 } else { 0 };
        if used > 0 && used + sep + word_width > width {
            out.push((std::mem::take(&mut line), join));
            join = Join::Soft(" ".into());
            used = 0;
        } else if sep == 1 {
            line.push(Span::raw(" "));
            used += 1;
        }
        for (text, style) in pieces {
            // A word longer than the row is broken where the row ends.
            let mut rest = text.as_str();
            while used + text_width(rest) > width && !rest.is_empty() {
                let room = width.saturating_sub(used);
                let piece: String = take_cols(rest, room.max(1));
                if piece.is_empty() {
                    break;
                }
                rest = &rest[piece.len()..];
                line.push(Span::styled(piece, style));
                out.push((std::mem::take(&mut line), join));
                join = Join::Soft(String::new());
                used = 0;
            }
            if !rest.is_empty() {
                used += text_width(rest);
                line.push(Span::styled(rest.to_string(), style));
            }
        }
    }
    if !line.is_empty() || out.is_empty() {
        out.push((line, join));
    }
    out
}

/// The longest start of `s` that fits in `cols` columns (at least one character).
fn take_cols(s: &str, cols: usize) -> String {
    let mut out = String::new();
    let mut used = 0;
    for c in s.chars() {
        let w = text_width(c.encode_utf8(&mut [0; 4]));
        if used + w > cols && !out.is_empty() {
            break;
        }
        out.push(c);
        used += w;
    }
    out
}

/// Notes and other plain lines: `code` and **bold** only, so text such as `snake_case` or a `*` stays as it is.
pub fn inline(text: &str, base: Style, theme: &Theme) -> Vec<(String, Style)> {
    let mut out: Vec<(String, Style)> = Vec::new();
    let mut rest = text;
    let mut plain = String::new();
    while !rest.is_empty() {
        if let Some(after) = rest.strip_prefix('`')
            && let Some(end) = after.find('`')
        {
            if !plain.is_empty() {
                out.push((std::mem::take(&mut plain), base));
            }
            out.push((after[..end].to_string(), theme.inline_code()));
            rest = &after[end + 1..];
            continue;
        }
        if let Some(after) = rest.strip_prefix("**")
            && let Some(end) = after.find("**")
            && end > 0
        {
            if !plain.is_empty() {
                out.push((std::mem::take(&mut plain), base));
            }
            out.push((after[..end].to_string(), base.add_modifier(Modifier::BOLD)));
            rest = &after[end + 2..];
            continue;
        }
        let c = rest.chars().next().expect("not empty");
        plain.push(c);
        rest = &rest[c.len_utf8()..];
    }
    if !plain.is_empty() {
        out.push((plain, base));
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn theme() -> Theme {
        Theme::new(true, false)
    }

    fn plain(rows: &[MdRow]) -> Vec<String> {
        rows.iter()
            .map(|r| {
                let text: String = r.spans.iter().map(|s| s.content.as_ref()).collect();
                format!("{}{}", " ".repeat(r.indent), text)
                    .trim_end()
                    .to_string()
            })
            .collect()
    }

    #[test]
    fn markdown_reads_as_text_with_its_marks_gone() {
        let rows = render(
            "# Plan\n\nSome **bold** and *soft* words with `code`.\n\n- one\n- two\n  - deeper\n\n1. first\n2. second\n\n> quoted\n\n```rust\nfn main() {}\n```\n\nSee [the docs](https://x.dev).",
            40,
            &theme(),
        );
        let text = plain(&rows);
        assert_eq!(text[0], "Plan");
        assert!(
            text.contains(&"Some bold and soft words with code.".to_string()),
            "{text:?}"
        );
        assert!(text.contains(&"• one".to_string()), "{text:?}");
        assert!(text.contains(&"  • deeper".to_string()), "{text:?}");
        assert!(text.contains(&"1. first".to_string()) && text.contains(&"2. second".to_string()));
        assert!(text.contains(&"  quoted".to_string()), "{text:?}");
        assert!(text.contains(&"rust".to_string()) && text.contains(&"fn main() {}".to_string()));
        assert!(
            text.contains(&"See the docs (https://x.dev).".to_string()),
            "{text:?}"
        );
        assert!(
            !text
                .iter()
                .any(|l| l.contains("**") || l.contains('`') || l.contains("```"))
        );
        let bold = rows
            .iter()
            .flat_map(|r| &r.spans)
            .find(|s| s.content == "bold")
            .unwrap();
        assert!(bold.style.add_modifier.contains(Modifier::BOLD));
    }

    #[test]
    fn rows_wrap_to_the_width_and_remember_the_spaces() {
        let rows = render("aaa bbb ccc ddd", 8, &theme());
        assert_eq!(plain(&rows), ["aaa bbb", "ccc ddd"]);
        assert_eq!(rows[1].join, Join::Soft(" ".into()));
        let long = render("abcdefghijkl", 5, &theme());
        assert_eq!(plain(&long), ["abcde", "fghij", "kl"]);
        assert_eq!(long[1].join, Join::Soft(String::new()));
        let item = render("- one two three four", 10, &theme());
        assert_eq!(plain(&item), ["• one two", "  three", "  four"]);
    }

    #[test]
    fn a_table_lines_up_and_fits() {
        let rows = render("| a | bb |\n|---|---|\n| ccc | d |", 40, &theme());
        assert_eq!(plain(&rows), ["a    bb", "ccc  d"]);
        let narrow = render(
            "| aaaaaaaaaa | bbbbbbbbbb |\n|---|---|\n| c | d |",
            14,
            &theme(),
        );
        assert!(
            plain(&narrow).iter().all(|l| text_width(l) <= 14),
            "{:?}",
            plain(&narrow)
        );
    }

    #[test]
    fn inline_marks_in_notes() {
        let t = theme();
        let parts = inline(
            "Use `imp imp list` or **this**, not snake_case *",
            t.text(),
            &t,
        );
        let texts: Vec<&str> = parts.iter().map(|(s, _)| s.as_str()).collect();
        assert_eq!(
            texts,
            ["Use ", "imp imp list", " or ", "this", ", not snake_case *"]
        );
    }
}
