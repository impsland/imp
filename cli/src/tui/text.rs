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
