//! Editing the message field: a cursor that moves by letter, word and line, and changes at the cursor.

use super::{Action, App};

impl App {
    /// Where the cursor is in the text, as a byte offset.
    pub fn cursor(&self) -> usize {
        self.cursor
    }

    /// Replaces the whole text and puts the cursor after it.
    pub(super) fn set_input(&mut self, text: String) {
        self.cursor = text.len();
        self.input = text;
    }

    /// Runs a cursor move. Moving is not editing, so the `/` list stays as it is.
    pub(super) fn move_cursor(&mut self, go: impl FnOnce(&mut App)) -> Action {
        go(self);
        Action::None
    }

    /// Puts `text` at the cursor and the cursor after it.
    pub(super) fn insert(&mut self, text: &str) {
        self.input.insert_str(self.cursor, text);
        self.cursor += text.len();
    }

    /// The start of the character before the cursor.
    fn before(&self) -> usize {
        self.input[..self.cursor]
            .char_indices()
            .next_back()
            .map_or(0, |(i, _)| i)
    }

    /// The end of the character after the cursor.
    fn after(&self) -> usize {
        self.input[self.cursor..]
            .chars()
            .next()
            .map_or(self.cursor, |c| self.cursor + c.len_utf8())
    }

    pub(super) fn left(&mut self) {
        self.cursor = self.before();
    }

    pub(super) fn right(&mut self) {
        self.cursor = self.after();
    }

    pub(super) fn backspace(&mut self) {
        let from = self.before();
        self.input.replace_range(from..self.cursor, "");
        self.cursor = from;
    }

    pub(super) fn delete(&mut self) {
        let to = self.after();
        self.input.replace_range(self.cursor..to, "");
    }

    /// The start of the word before the cursor: spaces are skipped first, then the word itself.
    fn word_start(&self) -> usize {
        let head = &self.input[..self.cursor];
        let trimmed = head.trim_end_matches(char::is_whitespace);
        trimmed.trim_end_matches(|c: char| !c.is_whitespace()).len()
    }

    /// The end of the word after the cursor: spaces are skipped first, then the word itself.
    fn word_end(&self) -> usize {
        let tail = &self.input[self.cursor..];
        let rest = tail.trim_start_matches(char::is_whitespace);
        let word = rest.trim_start_matches(|c: char| !c.is_whitespace());
        self.input.len() - word.len()
    }

    pub(super) fn word_left(&mut self) {
        self.cursor = self.word_start();
    }

    pub(super) fn word_right(&mut self) {
        self.cursor = self.word_end();
    }

    pub(super) fn delete_word_back(&mut self) {
        let from = self.word_start();
        self.input.replace_range(from..self.cursor, "");
        self.cursor = from;
    }

    /// The start of the line the cursor is on.
    pub(super) fn line_start(&mut self) {
        self.cursor = self.input[..self.cursor].rfind('\n').map_or(0, |i| i + 1);
    }

    /// The end of the line the cursor is on.
    pub(super) fn line_end(&mut self) {
        self.cursor = self.input[self.cursor..]
            .find('\n')
            .map_or(self.input.len(), |i| self.cursor + i);
    }
}
