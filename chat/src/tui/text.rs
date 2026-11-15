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

/// How a row of the transcript joins the row above it when it is copied.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Join {
    /// A new line, paragraph or message.
    Hard,
    /// The same paragraph wrapped: the whitespace the wrap dropped (empty inside a broken word).
    Soft(String),
}

/// Like [`wrap`], with how each line joins the one before it.
pub fn wrap_joined(text: &str, width: usize) -> Vec<(String, Join)> {
    let mut out = Vec::new();
    for paragraph in text.split('\n') {
        let lines = wrap(paragraph, width);
        let mut pos = 0;
        for (i, line) in lines.into_iter().enumerate() {
            let found = paragraph
                .get(pos..)
                .and_then(|rest| rest.find(line.as_str()))
                .map(|at| pos + at);
            let join = match (i, found) {
                (0, _) => Join::Hard,
                (_, Some(at)) => Join::Soft(paragraph[pos..at].to_string()),
                (_, None) => Join::Soft(" ".into()),
            };
            if let Some(at) = found {
                pos = at + line.len();
            }
            out.push((line, join));
        }
    }
    out
}

/// The part of `s` from column `from` up to (not including) column `to`. A wide letter counts as being
/// in the column where it starts.
pub fn slice_cols(s: &str, from: usize, to: usize) -> String {
    let mut col = 0;
    let mut out = String::new();
    for c in s.chars() {
        let w = text_width(c.encode_utf8(&mut [0; 4]));
        if col >= to {
            break;
        }
        if col >= from {
            out.push(c);
        }
        col += w;
    }
    out
}
