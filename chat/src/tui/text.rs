//! Measuring, wrapping and cutting text for the screen.

pub fn text_width(s: &str) -> usize {
    textwrap::core::display_width(s)
}

/// Cuts `s` to `max` columns, ending with an ellipsis when something was left out.
pub fn truncate(s: &str, max: usize) -> String {
    if text_width(s) <= max {
        return s.to_string();
    }
    let mut out = String::new();
    for c in s.chars() {
        if text_width(&out) + text_width(c.encode_utf8(&mut [0; 4])) + 1 > max {
            break;
        }
        out.push(c);
    }
    if max > 0 {
        out.push('…');
    }
    out
}

/// Wraps text to `width` columns. Line breaks in the text are kept and long words are broken.
pub fn wrap(text: &str, width: usize) -> Vec<String> {
    let width = width.max(1);
    let mut out = Vec::new();
    for paragraph in text.split('\n') {
        if paragraph.is_empty() {
            out.push(String::new());
        } else {
            out.extend(
                textwrap::wrap(paragraph, textwrap::Options::new(width).break_words(true))
                    .into_iter()
                    .map(|c| c.into_owned()),
            );
        }
    }
    out
}

/// Where the visible part of `total` lines starts when `height` lines show and the view is
/// `from_bottom` lines above the end. Also returns the most `from_bottom` can be.
pub fn visible_start(total: usize, height: usize, from_bottom: usize) -> (usize, usize) {
    let max = total.saturating_sub(height);
    (max - from_bottom.min(max), max)
}

/// The row and column of byte offset `cursor` of `text` once it is wrapped into `lines` by [`wrap`].
/// Spaces that were dropped where a line broke count as the end of the line before them.
pub fn cursor_cell(text: &str, lines: &[String], cursor: usize) -> (usize, usize) {
    let mut pos = 0;
    for (row, line) in lines.iter().enumerate() {
        let mut start = pos;
        let rest = |at: usize| text.get(at..).unwrap_or("");
        while !rest(start).starts_with(line.as_str()) {
            match rest(start).chars().next() {
                Some(c) if c.is_whitespace() && c != '\n' => start += c.len_utf8(),
                _ => break,
            }
        }
        if cursor < start && row > 0 {
            let before = &lines[row - 1];
            return (row - 1, text_width(before));
        }
        let end = (start + line.len()).min(text.len());
        let mid_word = text
            .get(end..)
            .and_then(|t| t.chars().next())
            .is_some_and(|c| !c.is_whitespace());
        if cursor < end || (cursor == end && !(mid_word && row + 1 < lines.len())) {
            let cursor = cursor.max(start);
            return (row, text.get(start..cursor).map_or(0, text_width));
        }
        pos = end;
        if text.get(pos..).is_some_and(|t| t.starts_with('\n')) {
            pos += 1;
        }
    }
    let last = lines.last().map_or(0, |l| text_width(l));
    (lines.len().saturating_sub(1), last)
}
