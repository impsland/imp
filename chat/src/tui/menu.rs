//! The list of `/` commands above the message field, and the hint for the one being typed.
//!
//! While a command name is typed the list shows the commands that match it, best first. Once the
//! name is followed by a space, one line shows how to use the command, and the words that can
//! follow it (such as `add` after `/mcp`) are listed when there is a fixed set.
//!
//! While a word that starts with `@` is typed, anywhere in the message, the list shows the folder's
//! files that match it. Accepting one puts its path in the message. A folder opens to what is in it.

use super::text::{text_width, truncate};
use super::{Action, App, MOST_SUGGESTION_ROWS, MOST_SUGGESTIONS};
use crate::custom;
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
    /// The forms of a command that has several, shown as lines under it.
    pub details: Vec<String>,
    /// The command itself, when the list is of commands and not of words after one.
    pub command: Option<&'static Command>,
    /// A custom command (`.agents/commands`): accepting it runs it, or fills in its arguments.
    pub custom: bool,
    /// Where the cursor goes after accepting it, when not at the end.
    pub cursor: Option<usize>,
}

/// What is shown above the field for the text typed.
#[derive(Debug, Default)]
pub struct Menu {
    /// How to use the command whose name is typed, once a space follows it.
    pub hint: Option<String>,
    pub entries: Vec<Entry>,
    /// The list is of files, after `@`: Enter accepts one rather than sending.
    pub files: bool,
}

impl App {
    /// The commands that match what is typed, best first, for the list above the field.
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
                    .map(|c| {
                        let details = slash::variants(c);
                        Entry {
                            insert: if slash::takes_args(c) {
                                format!("{} ", c.name)
                            } else {
                                c.name.clone()
                            },
                            label: if details.is_empty() {
                                &c.usage
                            } else {
                                &c.name
                            }
                            .clone(),
                            about: c.about.clone(),
                            details,
                            command: Some(c),
                            custom: false,
                            cursor: None,
                        }
                    })
                    .collect()
            };
            // Custom commands come after the built-in ones, and only when their name is being typed.
            let mut entries = entries;
            if !self.menu_closed {
                let typed = self.input.as_str();
                for c in self.custom.iter().filter(|c| {
                    let name = format!("/{}", c.name);
                    name.starts_with(typed) && slash::find(&name).is_none()
                }) {
                    let usage = custom::usage(c);
                    entries.push(Entry {
                        insert: if custom::takes_arguments(c) {
                            format!("/{} ", c.name)
                        } else {
                            format!("/{}", c.name)
                        },
                        label: usage,
                        about: custom::about(c),
                        details: Vec::new(),
                        command: None,
                        custom: true,
                        cursor: None,
                    });
                }
            }
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
            slash::choices(&command.name)
                .iter()
                .filter(|c| c.word.starts_with(rest))
                .map(|c| Entry {
                    insert: format!(
                        "{} {}{}",
                        command.name,
                        c.word,
                        if c.more { " " } else { "" }
                    ),
                    label: c.word.clone(),
                    about: c.about.clone(),
                    details: Vec::new(),
                    command: None,
                    custom: false,
                    cursor: None,
                })
                .collect()
        };
        Menu {
            hint: slash::hint(&self.input),
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
                    details: Vec::new(),
                    command: None,
                    custom: false,
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

    /// The lines above the field, no more than `room` of them: the hint, then the visible part of
    /// the list (a command with several forms takes a line for each) with a line saying where in it
    /// the highlight is when it does not all fit.
    pub(super) fn popup(&self, room: usize, width: usize) -> Vec<Line<'static>> {
        if let Some(secret) = &self.secret {
            let said = format!(
                " {} (not shown). Enter saves it, Esc cancels.",
                secret.prompt
            );
            return vec![Line::styled(truncate(&said, width), self.theme.muted())];
        }
        let menu = self.menu();
        let mut lines = Vec::new();
        if let (Some(hint), true) = (&menu.hint, room > 0) {
            lines.push(Line::styled(
                truncate(&format!(" {hint}"), width),
                self.theme.muted(),
            ));
        }
        let total = menu.entries.len();
        let avail = room.saturating_sub(lines.len()).min(MOST_SUGGESTION_ROWS);
        if total == 0 || avail == 0 {
            return lines;
        }
        let height = |e: &Entry| 1 + e.details.len();
        let rows_of =
            |from: usize, to: usize| menu.entries[from..to].iter().map(height).sum::<usize>();
        let fits = total <= MOST_SUGGESTIONS && rows_of(0, total) <= avail;
        let footer = !fits && avail >= 2;
        let budget = avail - usize::from(footer);
        let pick = self.pick_in(total);
        let mut visible = total.min(MOST_SUGGESTIONS);
        let mut start = pick.saturating_sub(visible / 2).min(total - visible);
        // Drop entries from the far end, then the near one, until the rows fit with the highlight in.
        while visible > 1 && rows_of(start, start + visible) > budget {
            if start + visible - 1 > pick {
                visible -= 1;
            } else {
                start += 1;
                visible -= 1;
            }
        }
        let shown = &menu.entries[start..start + visible];
        let label_width = shown
            .iter()
            .map(|e| text_width(&e.label))
            .max()
            .unwrap_or(0)
            .min(width / 2);
        let mut list = Vec::new();
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
            list.push(Line::styled(
                truncate(&format!(" {mark} {label}{pad}{}", e.about), width),
                style,
            ));
            for form in &e.details {
                list.push(Line::styled(
                    truncate(&format!("       {form}"), width),
                    self.theme.muted(),
                ));
            }
        }
        // Only a single entry taller than the room can still be too long.
        list.truncate(budget);
        lines.extend(list);
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
