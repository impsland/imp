//! The list of `/` commands under the message field, and the hint for the one being typed.
//!
//! While a command name is typed the list shows the commands that match it, best first. Once the
//! name is followed by a space, one line shows how to use the command, and the words that can
//! follow it (such as `save` after `/api_key`) are listed when there is a fixed set.
//!
//! While a word that starts with `@` is typed, anywhere in the message, the list shows the folder's
//! files that match it. Accepting one puts its path in the message. A folder opens to what is in it.

use super::text::{text_width, truncate};
use super::{Action, App, MOST_SUGGESTIONS};
use crate::mentions;
use crate::slash::{self, Command};
use ratatui::style::Modifier;
use ratatui::text::Line;

/// One line of the list: what Tab puts in the field, and how the line reads.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Entry {
    /// The whole text of the field after accepting this entry.
    pub insert: String,
    pub label: String,
    pub about: String,
    /// The command itself, when the list is of commands and not of words after one.
    pub command: Option<&'static Command>,
    /// Where the cursor goes after accepting it, when not at the end.
    pub cursor: Option<usize>,
}

/// What is shown under the field for the text typed.
#[derive(Debug, Default)]
pub struct Menu {
    /// How to use the command whose name is typed, once a space follows it.
    pub hint: Option<String>,
    pub entries: Vec<Entry>,
    /// The list is of files, after `@`: Enter accepts one rather than sending.
    pub files: bool,
}

impl App {
    /// The commands that match what is typed, best first, for the list under the field.
    pub fn suggestions(&self) -> Vec<&'static Command> {
        if self.waiting || self.input.contains('\n') {
            return Vec::new();
        }
        slash::suggest(&self.input)
    }

    /// The list and the hint for the text typed. The list is empty after Esc closed it.
    pub fn menu(&self) -> Menu {
        if let Some(files) = self.file_menu() {
            return files;
        }
        if self.waiting || self.input.contains('\n') || !self.input.starts_with('/') {
            return Menu::default();
        }
        let Some((word, rest)) = self.input.split_once(' ') else {
            let entries = if self.menu_closed {
                Vec::new()
            } else {
                self.suggestions()
                    .into_iter()
                    .map(|c| Entry {
                        insert: if slash::takes_args(c) {
                            format!("{} ", c.name)
                        } else {
                            c.name.to_string()
                        },
                        label: c.usage.to_string(),
                        about: c.about.to_string(),
                        command: Some(c),
                        cursor: None,
                    })
                    .collect()
            };
            return Menu {
                hint: None,
                entries,
                files: false,
            };
        };
        let Some(command) = slash::find(word) else {
            return Menu::default();
        };
        let entries = if self.menu_closed || rest.contains(char::is_whitespace) {
            Vec::new()
        } else {
            slash::choices(command.name)
                .iter()
                .filter(|c| c.word.starts_with(rest))
                .map(|c| Entry {
                    insert: format!(
                        "{} {}{}",
                        command.name,
                        c.word,
                        if c.more { " " } else { "" }
                    ),
                    label: c.word.to_string(),
                    about: c.about.to_string(),
                    command: None,
                    cursor: None,
                })
                .collect()
        };
        Menu {
            hint: Some(format!("{}: {}", command.usage, command.about)),
            entries,
            files: false,
        }
    }

    /// The files for the `@` word at the cursor. None when the cursor is not in one.
    fn file_menu(&self) -> Option<Menu> {
        let (start, query) = mentions::mention_at(&self.input, self.cursor)?;
        if self.menu_closed || self.files.is_empty() {
            return Some(Menu::default());
        }
        let end = mentions::word_end(&self.input, start);
        let after = &self.input[end..];
        let entries = mentions::rank(&self.files, query, 50)
            .into_iter()
            .map(|path| {
                let written = mentions::written(path);
                // A file is followed by a space, a folder by nothing, so its contents show next.
                let space = if path.ends_with('/') || after.starts_with(char::is_whitespace) {
                    ""
                } else {
                    " "
                };
                let insert = format!("{}{written}{space}{after}", &self.input[..start]);
                Entry {
                    cursor: Some(start + written.len() + space.len()),
                    insert,
                    label: path.to_string(),
                    about: String::new(),
                    command: None,
                }
            })
            .collect();
        Some(Menu {
            hint: None,
            entries,
            files: true,
        })
    }

    /// The highlighted entry, kept inside the list.
    pub(super) fn picked<'a>(&self, menu: &'a Menu) -> Option<&'a Entry> {
        menu.entries.get(self.pick_in(menu.entries.len()))
    }

    /// The highlighted position of a list of `len` entries.
    pub(super) fn pick_in(&self, len: usize) -> usize {
        self.pick.min(len.saturating_sub(1))
    }

    /// Up and Down move the highlight and wrap around at the ends.
    pub(super) fn move_pick(&mut self, menu: &Menu, down: bool) -> Action {
        let len = menu.entries.len();
        let at = self.pick_in(len);
        self.pick = match (down, at) {
            (true, at) if at + 1 >= len => 0,
            (true, at) => at + 1,
            (false, 0) => len.saturating_sub(1),
            (false, at) => at - 1,
        };
        Action::None
    }

    /// Puts the highlighted entry in the field.
    pub(super) fn accept(&mut self, menu: &Menu) -> Action {
        if let Some(entry) = self.picked(menu) {
            let (text, cursor) = (entry.insert.clone(), entry.cursor);
            self.set_input(text);
            if let Some(at) = cursor.filter(|at| self.input.is_char_boundary(*at)) {
                self.cursor = at;
            }
            self.pick = 0;
        }
        Action::None
    }

    /// The lines under the field, no more than `room` of them: the hint, then the visible part of
    /// the list with a line saying where in it the highlight is when it does not all fit.
    pub(super) fn popup(&self, room: usize, width: usize) -> Vec<Line<'static>> {
        let menu = self.menu();
        let mut lines = Vec::new();
        if let (Some(hint), true) = (&menu.hint, room > 0) {
            lines.push(Line::styled(
                truncate(&format!(" {hint}"), width),
                self.theme.muted(),
            ));
        }
        let total = menu.entries.len();
        let avail = room.saturating_sub(lines.len());
        if total == 0 || avail == 0 {
            return lines;
        }
        let mut visible = total.min(MOST_SUGGESTIONS).min(avail);
        let footer = total > visible && avail >= 2;
        if footer {
            visible = visible.min(avail - 1);
        }
        let pick = self.pick_in(total);
        let start = pick.saturating_sub(visible / 2).min(total - visible);
        let shown = &menu.entries[start..start + visible];
        let label_width = shown
            .iter()
            .map(|e| text_width(&e.label))
            .max()
            .unwrap_or(0)
            .min(width / 2);
        for (i, e) in shown.iter().enumerate() {
            let chosen = start + i == pick;
            let label = truncate(&e.label, label_width);
            let pad = " ".repeat(label_width.saturating_sub(text_width(&label)) + 2);
            let mark = if chosen { "›" } else { " " };
            let style = if chosen {
                self.theme.text().add_modifier(Modifier::BOLD)
            } else {
                self.theme.muted()
            };
            lines.push(Line::styled(
                truncate(&format!(" {mark} {label}{pad}{}", e.about), width),
                style,
            ));
        }
        if footer {
            let up = if start > 0 { " ↑" } else { "" };
            let down = if start + visible < total { " ↓" } else { "" };
            lines.push(Line::styled(
                format!("  {}/{total}{up}{down}", pick + 1),
                self.theme.muted(),
            ));
        }
        lines
    }
}
