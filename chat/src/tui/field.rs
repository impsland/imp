//! The message field's own layout. The transcript's wrapping drops the spaces where it breaks a line,
//! which is right for reading but wrong for typing: a space typed at the end must show, and the cursor
//! must move past it. Here every character keeps its place, lines break after a space when they can,
//! and the cursor's row and column come from the same layout, so they always agree.

use super::text::text_width;

/// One row of the field: a byte range of the text, without the line break that may end it.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Row {
    pub start: usize,
    pub end: usize,
    /// The next row goes on the same line of the text (a wrap, not a line break).
    pub wraps: bool,
}

/// The rows of `text` in a field `width` columns wide.
pub fn layout(text: &str, width: usize) -> Vec<Row> {
    let width = width.max(1);
    let mut rows = Vec::new();
    let mut line_start = 0;
    for line in text.split('\n') {
        let mut start = line_start;
        let mut col = 0;
        // Where the row could break: just after the last space in it.
        let mut after_space: Option<usize> = None;
        for (i, c) in line.char_indices() {
            let at = line_start + i;
            let w = text_width(c.encode_utf8(&mut [0; 4]));
            if col + w > width && col > 0 {
                let cut = match after_space {
                    Some(b) if !c.is_whitespace() && b > start => b,
                    _ => at,
                };
                rows.push(Row {
                    start,
                    end: cut,
                    wraps: true,
                });
                start = cut;
                col = text_width(&text[start..at]);
                after_space = None;
            }
            col += w;
            if c.is_whitespace() {
                after_space = Some(at + c.len_utf8());
            }
        }
        let end = line_start + line.len();
        rows.push(Row {
            start,
            end,
            wraps: false,
        });
        line_start = end + 1;
    }
    rows
}

/// The row and column of byte offset `cursor`. At the place where a row wraps, the cursor is at the
/// start of the next row.
pub fn cursor_cell(text: &str, rows: &[Row], cursor: usize) -> (usize, usize) {
    for (i, row) in rows.iter().enumerate() {
        let inside = cursor >= row.start && (cursor < row.end || (cursor == row.end && !row.wraps));
        if inside {
            return (i, text_width(&text[row.start..cursor]));
        }
    }
    let last = rows.len().saturating_sub(1);
    (
        last,
        rows.last().map_or(0, |r| text_width(&text[r.start..r.end])),
    )
}

/// The byte offset at column `col` of row `row`, or the end of the row when it is shorter.
pub fn offset_at(text: &str, rows: &[Row], row: usize, col: usize) -> usize {
    let Some(r) = rows.get(row) else {
        return text.len();
    };
    let mut at = r.start;
    let mut used = 0;
    for c in text[r.start..r.end].chars() {
        let w = text_width(c.encode_utf8(&mut [0; 4]));
        if used + w > col {
            break;
        }
        used += w;
        at += c.len_utf8();
    }
    // A wrapped row's last place is the next row's first: stay before it.
    if r.wraps && at == r.end && at > r.start {
        at = text[..at]
            .char_indices()
            .next_back()
            .map_or(r.start, |(i, _)| i);
    }
    at
}

/// The text of each row, as drawn.
pub fn row_texts<'a>(text: &'a str, rows: &[Row]) -> Vec<&'a str> {
    rows.iter().map(|r| &text[r.start..r.end]).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn shown(text: &str, width: usize) -> Vec<&str> {
        row_texts(text, &layout(text, width))
    }

    #[test]
    fn every_space_stays_and_the_cursor_moves_past_it() {
        assert_eq!(shown("a b ", 10), ["a b "]);
        let rows = layout("a b ", 10);
        assert_eq!(cursor_cell("a b ", &rows, 4), (0, 4));
        assert_eq!(cursor_cell("a  b", &layout("a  b", 10), 3), (0, 3));
        assert_eq!(shown("", 5), [""]);
        assert_eq!(cursor_cell("", &layout("", 5), 0), (0, 0));
    }

    #[test]
    fn lines_break_after_a_space_or_inside_a_long_word() {
        assert_eq!(shown("hello world", 8), ["hello ", "world"]);
        assert_eq!(shown("abcdefghij", 4), ["abcd", "efgh", "ij"]);
        assert_eq!(shown("one\ntwo", 10), ["one", "two"]);
        assert_eq!(shown("日本語日本語", 6), ["日本語", "日本語"]);
        // The cursor at the wrap is at the start of the next row.
        let rows = layout("hello world", 8);
        assert_eq!(cursor_cell("hello world", &rows, 6), (1, 0));
        assert_eq!(cursor_cell("hello world", &rows, 11), (1, 5));
        // After a line break, on the new line.
        let rows = layout("one\n", 10);
        assert_eq!(cursor_cell("one\n", &rows, 4), (1, 0));
    }

    #[test]
    fn up_and_down_land_on_the_same_column_or_the_rows_end() {
        let text = "hello world\nhi";
        let rows = layout(text, 8);
        assert_eq!(offset_at(text, &rows, 1, 2), 8);
        assert_eq!(offset_at(text, &rows, 2, 9), text.len());
        // Never past a wrap: the last place of "hello " is before the space's end.
        assert_eq!(offset_at(text, &rows, 0, 50), 5);
    }
}
