//! The full-screen chat. `App` holds everything on the screen and has no input or output, so keys
//! and agent events can be tested without a terminal. `run` is the thin part that talks to one.
//!
//! `mod.rs` is the state and the keys, `view` draws it, `help` is the card the `?` key opens, `detail` is
//! the whole of one tool call that Ctrl+O opens, `text`
//! measures and wraps, `select` is choosing transcript text with the mouse to copy it, `clipboard` puts
//! it on the system clipboard, `terminal` owns the real terminal, the session, the device and the event loop.

mod clipboard;
mod detail;
mod field;
mod help;
mod input;
mod markdown;
mod menu;
mod select;
mod terminal;
mod text;
mod view;

#[cfg(test)]
mod tests;

use crate::chat_state::ChatState;
use crate::link::device::{Visitor, messages_of};
use crate::project::CustomCommand;
use crate::slash::{self, Note};
use crate::strings::{self, Lang};
use crate::theme::Theme;
use imp_engine::{AgentEvent, ChatMessage};
use ratatui::crossterm::event::{
    KeyCode, KeyEvent, KeyEventKind, KeyModifiers, MouseButton, MouseEvent, MouseEventKind,
};
use std::cell::Cell;
use std::time::{Duration, Instant};
use uuid::Uuid;

pub use help::{Binding, GROUPS};
pub use menu::Entry;
pub use terminal::{long_chat_sentence, run};
pub use text::{visible_start, wrap};

/// What a key asks the program to do.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Action {
    None,
    Quit,
    /// A message was added to the chat and the Imp should answer it.
    Send(String),
    /// A `/` command to run.
    Command(String),
    /// Stop the answer that is arriving.
    Stop,
    /// Put this text on the clipboard.
    Copy(String),
}

/// How many lines the mouse wheel moves.
const WHEEL_LINES: usize = 3;
/// The most lines the message field grows to, padding included.
const MAX_INPUT_HEIGHT: u16 = 8;
/// The most commands shown at once in the list above the field while one is typed.
const MOST_SUGGESTIONS: usize = 6;
/// The most rows of that list, with the forms of a command that has several counted in.
const MOST_SUGGESTION_ROWS: usize = 12;
/// The most messages kept to walk back through with Ctrl+P.
const MOST_RECALLED: usize = 100;
/// How long a short word such as "Copied" stays in the status line.
const FLASH: Duration = Duration::from_secs(2);

/// A visiting Imp on screen: its chat lives at its home device.
#[derive(Debug, Clone, PartialEq)]
pub struct Visiting {
    pub id: Uuid,
    pub hue: f64,
    pub home: String,
    pub awake: bool,
    /// What it is writing right now, as its home last said.
    pub partial: Option<String>,
    pub status: Option<String>,
}

pub struct App {
    pub chat: ChatState,
    imp: String,
    model: String,
    input: String,
    /// Where the cursor is in `input`, as a byte offset on a character boundary.
    cursor: usize,
    /// Which entry of the `/` list is highlighted, and whether Esc closed the list.
    pick: usize,
    menu_closed: bool,
    /// How many lines the transcript is scrolled up from the bottom. Drawing raises it when lines arrive
    /// below while it is above zero, so what is being read stays where it is.
    scroll: Cell<usize>,
    /// Set while drawing: the transcript's height and how far it can scroll.
    viewport: Cell<usize>,
    max_scroll: Cell<usize>,
    /// Set while drawing: where the transcript is and which of its rows shows first, for the mouse.
    view: Cell<select::View>,
    /// Text chosen with the mouse, in rows of the transcript, and whether the button is still down.
    selection: Cell<Option<select::Selection>>,
    dragging: bool,
    /// While dragging past the top (true) or bottom (false) of the transcript, it scrolls on its own, at a
    /// rate that grows with how many rows past the edge the mouse is.
    edge: Option<(bool, usize)>,
    /// The part of a line the edge scrolling has built up and not yet scrolled.
    edge_carry: f64,
    /// The last click, to tell a double or triple click.
    last_click: Option<(Instant, u16, u16, u8)>,
    /// A short word for the status line and when it was said ("Copied").
    flash: Option<(String, Instant)>,
    /// How far the help card is scrolled, on a screen too short for it.
    help_scroll: Cell<usize>,
    /// The folder's files and folders, for `@`.
    files: Vec<String>,
    /// The custom commands of the folder and of the home folder (`.agents/commands`).
    custom: Vec<CustomCommand>,
    /// What the folder adds (AGENTS.md, skills), in a few words for the empty screen.
    context: String,
    waiting: bool,
    /// When the answer that is arriving was asked for.
    started: Option<Instant>,
    retry: Option<String>,
    tool: Option<String>,
    error: Option<String>,
    help: bool,
    /// The details of a tool call, while they are open.
    detail: Option<detail::Detail>,
    /// Lines from commands and devices, each after so many messages of the conversation.
    notes: Vec<(usize, Note)>,
    /// A command that is running, shown in the status line.
    busy: Option<String>,
    /// The device this Imp is on, while it is away.
    away: Option<String>,
    visiting: Option<Visiting>,
    /// What was sent before, for Up and Down (and Ctrl+P and Ctrl+N), and what was being written
    /// before the walk through it started, which comes back after the newest.
    recalled: Vec<String>,
    recall_at: Option<usize>,
    draft: Option<String>,
    /// Set while drawing: the width of the message field, for moving up and down its rows.
    field_width: Cell<usize>,
    /// The folder the chat was started in, for the empty screen.
    folder: String,
    lang: Lang,
    theme: Theme,
}

impl App {
    pub fn new(imp: &str, model: &str, system: &str) -> Self {
        Self::with_chat(imp, model, ChatState::new(system))
    }

    pub fn with_chat(imp: &str, model: &str, chat: ChatState) -> Self {
        Self {
            chat,
            imp: imp.to_string(),
            model: model.to_string(),
            input: String::new(),
            cursor: 0,
            pick: 0,
            menu_closed: false,
            scroll: Cell::new(0),
            viewport: Cell::new(10),
            max_scroll: Cell::new(0),
            view: Cell::new(select::View::default()),
            selection: Cell::new(None),
            dragging: false,
            edge: None,
            edge_carry: 0.0,
            last_click: None,
            flash: None,
            help_scroll: Cell::new(0),
            files: Vec::new(),
            custom: Vec::new(),
            context: String::new(),
            waiting: false,
            started: None,
            retry: None,
            tool: None,
            error: None,
            help: false,
            detail: None,
            notes: Vec::new(),
            busy: None,
            away: None,
            visiting: None,
            recalled: Vec::new(),
            recall_at: None,
            draft: None,
            field_width: Cell::new(80),
            folder: String::new(),
            lang: Lang::detect(),
            theme: Theme::detect(),
        }
    }

    /// Chooses the language and look instead of reading them from the environment.
    pub fn styled(mut self, lang: Lang, theme: Theme) -> Self {
        self.lang = lang;
        self.theme = theme;
        self
    }

    /// The folder shown in the status line.
    pub fn in_folder(mut self, folder: &str) -> Self {
        self.folder = folder.to_string();
        self
    }

    /// What the folder adds, in a few words for the empty screen, such as `AGENTS.md · 3 skills`.
    pub fn with_context(mut self, context: &str) -> Self {
        self.context = context.to_string();
        self
    }

    /// The folder's files and folders (folders end with `/`), offered after `@`.
    pub fn set_files(&mut self, files: Vec<String>) {
        self.files = files;
    }

    /// The custom commands, offered after `/` and run when typed.
    pub fn set_custom_commands(&mut self, commands: Vec<CustomCommand>) {
        self.custom = commands;
    }

    /// Says in the status line for a moment that text was copied.
    pub fn copied(&mut self) {
        self.flash(strings::text(self.lang, "cli.chat.copied"));
    }

    /// Says something short in the status line for a moment, such as "Copied".
    pub fn flash(&mut self, word: &str) {
        self.flash = Some((word.to_string(), Instant::now()));
    }

    /// Whether the status line says something that will go away, so the screen must be drawn again.
    pub fn has_flash(&self) -> bool {
        self.flash
            .as_ref()
            .is_some_and(|(_, at)| at.elapsed() < FLASH)
    }

    pub fn input(&self) -> &str {
        &self.input
    }

    pub fn scroll(&self) -> usize {
        self.scroll.get()
    }

    fn set_scroll(&mut self, lines: usize) {
        self.scroll.set(lines);
    }

    pub fn is_waiting(&self) -> bool {
        self.waiting
    }

    pub fn is_help_open(&self) -> bool {
        self.help
    }

    pub fn name(&self) -> &str {
        &self.imp
    }

    pub fn visiting(&self) -> Option<&Visiting> {
        self.visiting.as_ref()
    }

    pub fn away(&self) -> Option<&str> {
        self.away.as_deref()
    }

    /// The notes on screen, in order.
    pub fn notes(&self) -> impl Iterator<Item = &Note> {
        self.notes.iter().map(|(_, n)| n)
    }

    // Keys
    pub fn on_key(&mut self, key: KeyEvent) -> Action {
        if key.kind == KeyEventKind::Release {
            return Action::None;
        }
        if self.help {
            return self.help_key(key);
        }
        if self.detail.is_some() {
            return self.detail_key(key);
        }
        let ctrl = key.modifiers.contains(KeyModifiers::CONTROL);
        // With text chosen, Esc lets go of it and Ctrl+C copies it again instead of leaving.
        if self.selection.get().is_some() {
            match key.code {
                KeyCode::Esc => {
                    self.selection.set(None);
                    return Action::None;
                }
                KeyCode::Char('c') if ctrl => {
                    let text = self.selected_text();
                    self.selection.set(None);
                    return if text.is_empty() {
                        Action::None
                    } else {
                        Action::Copy(text)
                    };
                }
                _ => {}
            }
        }
        let alt = key.modifiers.contains(KeyModifiers::ALT);
        let shift = key.modifiers.contains(KeyModifiers::SHIFT);
        let newline_mod = key
            .modifiers
            .intersects(KeyModifiers::SHIFT | KeyModifiers::ALT);
        let by_word = ctrl || alt;
        let menu = self.menu();
        let open = !menu.entries.is_empty();
        let at_end = self.cursor == self.input.len();
        match key.code {
            KeyCode::Esc if open => {
                self.menu_closed = true;
                Action::None
            }
            KeyCode::Esc if self.waiting => Action::Stop,
            // Esc never leaves the chat: a stray press must not end it. /quit and Ctrl+C do that.
            KeyCode::Esc => Action::None,
            KeyCode::Char('c') if ctrl => Action::Quit,
            KeyCode::Char('d') if ctrl && self.input.is_empty() => Action::Quit,
            KeyCode::F(1) => self.show_help(),
            KeyCode::Char('?') if self.input.is_empty() => self.show_help(),
            KeyCode::Char('o') if ctrl => {
                self.open_detail();
                Action::None
            }
            KeyCode::Char('u') if ctrl => self.edit(|app| app.set_input(String::new())),
            KeyCode::Char('j') if ctrl => self.edit(|app| app.insert("\n")),
            KeyCode::Char('w') if ctrl => self.edit(App::delete_word_back),
            KeyCode::Char('a') if ctrl => self.move_cursor(App::line_start),
            KeyCode::Char('e') if ctrl => self.move_cursor(App::line_end),
            KeyCode::Char('p') if ctrl => self.recall(true),
            KeyCode::Char('n') if ctrl => self.recall(false),
            KeyCode::Up if open => self.move_pick(&menu, false),
            KeyCode::Down if open => self.move_pick(&menu, true),
            KeyCode::Up if shift => self.scroll_by(1, true),
            KeyCode::Down if shift => self.scroll_by(1, false),
            KeyCode::Up => self.up_or_back(),
            KeyCode::Down => self.down_or_forward(),
            KeyCode::Tab if open => self.accept(&menu),
            KeyCode::Right if open && at_end => self.accept(&menu),
            KeyCode::Tab => {
                // Brings the list back after Esc closed it.
                self.menu_closed = false;
                Action::None
            }
            KeyCode::Enter if newline_mod => self.edit(|app| app.insert("\n")),
            KeyCode::Enter => self.enter(&menu),
            KeyCode::Backspace if alt => self.edit(App::delete_word_back),
            KeyCode::Backspace => self.edit(App::backspace),
            KeyCode::Delete => self.edit(App::delete),
            KeyCode::Left if by_word => self.move_cursor(App::word_left),
            KeyCode::Right if by_word => self.move_cursor(App::word_right),
            KeyCode::Left => self.move_cursor(App::left),
            KeyCode::Right => self.move_cursor(App::right),
            KeyCode::Home => self.move_cursor(App::line_start),
            KeyCode::End if ctrl || self.input.is_empty() => {
                self.set_scroll(0);
                Action::None
            }
            KeyCode::End => self.move_cursor(App::line_end),
            KeyCode::Char(c) if !ctrl && !alt => {
                self.edit(|app| app.insert(c.encode_utf8(&mut [0; 4])))
            }
            KeyCode::PageUp => self.scroll_by(self.page(), true),
            KeyCode::PageDown => self.scroll_by(self.page(), false),
            _ => Action::None,
        }
    }

    /// Enter on the highlighted command runs it, or completes it when it cannot run bare. On a file
    /// after `@` it puts the file in the message.
    fn enter(&mut self, menu: &menu::Menu) -> Action {
        if menu.files && !menu.entries.is_empty() {
            return self.accept(menu);
        }
        if let Some(entry) = self.picked(menu).filter(|e| e.custom) {
            // A custom command that takes arguments is completed first, so they can be typed.
            if entry.insert.ends_with(' ') {
                return self.accept(menu);
            }
            let insert = entry.insert.clone();
            self.set_input(insert);
        } else if let Some(command) = self.picked(menu).and_then(|e| e.command) {
            if slash::needs_args(command) {
                return self.accept(menu);
            }
            self.set_input(command.name.to_string());
        }
        self.submit()
    }

    fn show_help(&mut self) -> Action {
        self.help = true;
        self.help_scroll.set(0);
        Action::None
    }

    /// While the help card is open, the arrows and pages scroll it (on a short screen) and any other key closes it.
    fn help_key(&mut self, key: KeyEvent) -> Action {
        let at = self.help_scroll.get();
        let page = self.page();
        match key.code {
            KeyCode::Up => self.help_scroll.set(at.saturating_sub(1)),
            KeyCode::Down => self.help_scroll.set(at + 1),
            KeyCode::PageUp => self.help_scroll.set(at.saturating_sub(page)),
            KeyCode::PageDown => self.help_scroll.set(at + page),
            KeyCode::Home => self.help_scroll.set(0),
            KeyCode::End => self.help_scroll.set(usize::MAX / 2),
            _ => self.help = false,
        }
        Action::None
    }

    /// A change to the text: it starts the `/` list over and leaves the walk through what was sent.
    fn edit(&mut self, change: impl FnOnce(&mut App)) -> Action {
        change(self);
        self.selection.set(None);
        self.recall_at = None;
        self.pick = 0;
        self.menu_closed = false;
        Action::None
    }

    /// Puts the message sent before in the field (`back`), or the one after. Past the newest comes back
    /// what was being written when the walk started, so nothing typed is lost.
    fn recall(&mut self, back: bool) -> Action {
        if self.recalled.is_empty() {
            return Action::None;
        }
        let last = self.recalled.len() - 1;
        let at = match (self.recall_at, back) {
            (None, true) => Some(last),
            (None, false) => return Action::None,
            (Some(i), true) => Some(i.saturating_sub(1)),
            (Some(i), false) if i < last => Some(i + 1),
            (Some(_), false) => None,
        };
        if self.recall_at.is_none() {
            self.draft = Some(self.input.clone());
        }
        self.recall_at = at;
        let text = match at {
            Some(i) => self.recalled[i].clone(),
            None => self.draft.take().unwrap_or_default(),
        };
        self.set_input(text);
        Action::None
    }

    /// The row of the field the cursor is on, the rows, and the cursor's column.
    fn field_place(&self) -> (usize, Vec<field::Row>, usize) {
        let rows = field::layout(&self.input, self.field_width.get());
        let (row, col) = field::cursor_cell(&self.input, &rows, self.cursor);
        (row, rows, col)
    }

    /// Up moves to the row above in the message. On its first row it brings back what was sent before,
    /// as in a shell.
    fn up_or_back(&mut self) -> Action {
        let (row, rows, col) = self.field_place();
        if row == 0 {
            return self.recall(true);
        }
        self.cursor = field::offset_at(&self.input, &rows, row - 1, col);
        Action::None
    }

    /// Down moves to the row below. On the last row it goes forward through what was sent.
    fn down_or_forward(&mut self) -> Action {
        let (row, rows, col) = self.field_place();
        if row + 1 >= rows.len() {
            return self.recall(false);
        }
        self.cursor = field::offset_at(&self.input, &rows, row + 1, col);
        Action::None
    }

    fn page(&self) -> usize {
        self.viewport.get().saturating_sub(1).max(1)
    }

    fn scroll_by(&mut self, lines: usize, up: bool) -> Action {
        let now = self.scroll.get();
        if up {
            self.set_scroll((now + lines).min(self.max_scroll.get()));
        } else {
            self.set_scroll(now.saturating_sub(lines));
        }
        Action::None
    }

    fn remember(&mut self, text: &str) {
        if self.recalled.last().map(String::as_str) != Some(text) {
            self.recalled.push(text.to_string());
            if self.recalled.len() > MOST_RECALLED {
                self.recalled.remove(0);
            }
        }
        self.recall_at = None;
    }

    fn submit(&mut self) -> Action {
        let text = self.input.trim().to_string();
        if text.is_empty() {
            return Action::None;
        }
        // A custom command sends its text to the Imp, so it is a message, not a command.
        let custom = slash::custom_text(&text, &self.custom);
        if custom.is_none() && slash::is_command(&text) {
            let word = text.split_whitespace().next().unwrap_or("");
            match word {
                "/quit" | "/exit" => return Action::Quit,
                "/clear" | "/new" if !self.waiting => {
                    self.clear();
                    self.set_input(String::new());
                    return Action::None;
                }
                _ => {}
            }
            if self.waiting {
                return Action::None;
            }
            self.set_input(String::new());
            self.set_scroll(0);
            self.error = None;
            if !text.starts_with("/api_key") && !text.starts_with("/key") {
                self.remember(&text);
            }
            self.note(Note::command(slash::shown(&text)));
            return Action::Command(text);
        }
        let text = custom.unwrap_or(text);
        let text = text
            .strip_prefix('/')
            .filter(|t| t.starts_with('/'))
            .unwrap_or(&text)
            .to_string();
        if self.waiting {
            return Action::None;
        }
        if let Some(device) = &self.away {
            let said = format!(
                "{} is on {device}, so it answers there. /call brings it back.",
                self.imp
            );
            self.note(Note::problem(said));
            return Action::None;
        }
        if let Some(v) = &self.visiting {
            if !v.awake {
                let said = format!(
                    "{} is asleep: its home, {}, is not connected.",
                    self.imp, v.home
                );
                self.note(Note::problem(said));
                return Action::None;
            }
            // The question shows at once. Its home's chat replaces it when it comes back.
            self.chat.push_user(&text);
        } else if !self.chat.push_user(&text) {
            return Action::None;
        }
        self.remember(&text);
        self.set_input(String::new());
        self.set_scroll(0);
        self.error = None;
        self.waiting = true;
        self.started = Some(Instant::now());
        Action::Send(text)
    }

    /// An answer to a message the Imp sent without waiting has come while it was free. `event` is added at the
    /// end of the chat as a new message (never in place of an earlier one) and the Imp takes a turn on it.
    /// False when it can't start one now.
    pub fn wake(&mut self, event: &str) -> bool {
        if self.waiting || !self.chat.push_user(event) {
            return false;
        }
        self.set_scroll(0);
        self.error = None;
        self.waiting = true;
        self.started = Some(Instant::now());
        true
    }

    /// Starts the conversation over. Notes go too.
    pub fn clear(&mut self) {
        self.chat.clear();
        self.notes.clear();
        self.selection.set(None);
        self.set_scroll(0);
        self.error = None;
    }

    /// The wheel scrolls (the help card, when it is open). Dragging over the transcript chooses text,
    /// which is copied when the button is let go. Two clicks choose a word and three a paragraph.
    pub fn on_mouse(&mut self, mouse: MouseEvent) -> Action {
        if self.help {
            match mouse.kind {
                MouseEventKind::ScrollUp => self
                    .help_scroll
                    .set(self.help_scroll.get().saturating_sub(WHEEL_LINES)),
                MouseEventKind::ScrollDown => {
                    self.help_scroll.set(self.help_scroll.get() + WHEEL_LINES);
                }
                MouseEventKind::Down(_) => self.help = false,
                _ => {}
            }
            return Action::None;
        }
        if self.detail.is_some() {
            match mouse.kind {
                MouseEventKind::ScrollUp => self.detail_wheel(true),
                MouseEventKind::ScrollDown => self.detail_wheel(false),
                _ => {}
            }
            return Action::None;
        }
        match mouse.kind {
            MouseEventKind::ScrollUp => self.scroll_by(WHEEL_LINES, true),
            MouseEventKind::ScrollDown => self.scroll_by(WHEEL_LINES, false),
            MouseEventKind::Down(MouseButton::Left) => self.press(mouse.column, mouse.row),
            MouseEventKind::Drag(MouseButton::Left) => {
                self.drag(mouse.column, mouse.row);
                Action::None
            }
            MouseEventKind::Up(MouseButton::Left) => self.release(),
            _ => Action::None,
        }
    }

    /// While text is dragged past the edge of the transcript, it scrolls this often.
    pub fn edge_scrolling(&self) -> bool {
        self.dragging && self.edge.is_some()
    }

    pub fn on_paste(&mut self, text: &str) {
        let text = text.replace("\r\n", "\n").replace('\r', "\n");
        self.edit(|app| app.insert(&text));
    }

    // What the program tells the screen
    /// A line under the conversation so far. It is never sent to the model.
    pub fn note(&mut self, note: Note) {
        self.notes.push((self.chat.messages().len(), note));
        self.set_scroll(0);
    }

    pub fn notes_from(&mut self, notes: Vec<Note>) {
        for note in notes {
            self.note(note);
        }
    }

    /// A command is running: the status line says so.
    pub fn set_busy(&mut self, what: Option<String>) {
        self.busy = what;
    }

    /// Talk to another Imp of this computer now. The conversation starts fresh, or goes on from `messages`.
    pub fn switch(&mut self, imp: &str, model: &str, chat: ChatState) {
        self.chat = chat;
        self.imp = imp.to_string();
        self.model = model.to_string();
        self.notes.clear();
        self.visiting = None;
        self.away = None;
        self.waiting = false;
        self.started = None;
        self.error = None;
        self.selection.set(None);
        self.set_scroll(0);
    }

    /// The model or the system text changed for the next message.
    pub fn set_model(&mut self, model: &str, system: &str) {
        self.model = model.to_string();
        self.chat.set_system(system);
    }

    /// The Imp on screen went to another device (or came back, with None).
    pub fn set_away(&mut self, device: Option<String>) {
        self.away = device;
        self.waiting = false;
        self.started = None;
    }

    /// Show a visiting Imp: its chat as its home sends it, and what it is writing.
    pub fn show_visitor(&mut self, visitor: &Visitor) {
        let first = self
            .visiting
            .as_ref()
            .is_none_or(|v| v.id != visitor.look.id);
        if first {
            self.notes.clear();
            self.selection.set(None);
            self.set_scroll(0);
            self.error = None;
        }
        self.imp = visitor.look.name.clone();
        self.model = format!("visiting from {}", visitor.home_name);
        let pending_question = self.waiting && visitor.work.is_none();
        let mut messages = messages_of(&visitor.turns);
        // A question just sent shows until the home's chat has it.
        if pending_question
            && let Some(last) = self.chat.last_user_text()
            && visitor.turns.last().is_none_or(|t| t.request != last)
        {
            messages.push(ChatMessage::user(last));
        }
        self.chat = ChatState::from_messages("", messages);
        let work = visitor.work.as_ref();
        // Asleep, it answers nothing until its home is back.
        self.waiting = visitor.awake && (work.is_some() || pending_question);
        if !self.waiting {
            self.started = None;
        }
        self.visiting = Some(Visiting {
            id: visitor.look.id,
            hue: visitor.look.hue,
            home: visitor.home_name.clone(),
            awake: visitor.awake,
            partial: work.map(|w| w.partial.clone()),
            status: work.and_then(|w| w.status.clone()),
        });
    }

    /// The visitor on screen left this computer.
    pub fn visitor_left(&mut self) {
        if let Some(v) = &mut self.visiting {
            v.awake = false;
            v.partial = None;
        }
        self.waiting = false;
    }

    // The agent
    pub fn on_agent(&mut self, event: &AgentEvent) {
        match event {
            AgentEvent::Retry(n) => self.retry = Some(n.text()),
            AgentEvent::Stream(_) => self.retry = None,
            AgentEvent::ToolStart(call) => {
                self.tool = Some(crate::transcript::short_name(&call.name).to_string());
            }
            AgentEvent::ToolResult { .. } => self.tool = None,
            AgentEvent::StepStart | AgentEvent::StepEnd => {}
        }
        self.chat.apply_agent(event);
    }

    /// The answer is complete, or it failed with a sentence to show.
    pub fn on_done(&mut self, result: std::result::Result<(), String>) {
        // An answer is remembered for the next message. A failed one is not sent again.
        let answered = result.is_ok() && self.visiting.is_none();
        self.finish(answered);
        self.error = result.err();
    }

    /// The person stopped the answer. What arrived still shows, but it is not sent again.
    pub fn on_stopped(&mut self) {
        self.finish(false);
        self.error = None;
    }

    fn finish(&mut self, answered: bool) {
        if self.chat.is_streaming() {
            self.chat.abort_reply();
        }
        self.chat.finish_exchange(answered);
        self.waiting = false;
        self.started = None;
        self.retry = None;
        self.tool = None;
    }

    /// A plain sentence about something that did not start, shown where problems are shown.
    pub fn warn(&mut self, sentence: &str) {
        self.error = Some(sentence.to_string());
    }

    /// The spinner's frame now: it turns while an answer is on its way.
    pub(super) fn spinner(&self) -> &'static str {
        let ms = self.started.map_or(0, |s| s.elapsed().as_millis());
        view::spinner_frame(ms)
    }

    /// ` 4s` once an answer has taken a second, or nothing.
    pub(super) fn seconds(&self) -> String {
        self.started
            .map(|s| s.elapsed().as_secs())
            .filter(|s| *s > 0)
            .map_or(String::new(), |s| format!(" {s}s"))
    }

    /// Whether something on the screen moves, so it is drawn again often.
    pub fn is_animating(&self) -> bool {
        self.waiting
    }

    /// What the status line says on its right side.
    pub fn activity(&self) -> String {
        let lang = self.lang;
        if let Some((word, _)) = self.flash.as_ref().filter(|_| self.has_flash()) {
            return word.clone();
        }
        let seconds = self
            .started
            .map(|s| s.elapsed().as_secs())
            .filter(|s| *s > 0)
            .map_or(String::new(), |s| format!(" {s}s"));
        if let Some(busy) = &self.busy {
            busy.clone()
        } else if let Some(retry) = &self.retry {
            retry.clone()
        } else if let Some(tool) = self
            .tool
            .as_ref()
            .or_else(|| self.visiting.as_ref().and_then(|v| v.status.as_ref()))
        {
            strings::format(lang, "cli.chat.using_tool", &[("tool", tool)]) + &seconds
        } else if self.waiting && self.streaming().is_empty() {
            strings::text(lang, "cli.chat.thinking").to_string() + &seconds
        } else if self.waiting {
            strings::text(lang, "cli.chat.answering").to_string() + &seconds
        } else if let Some(device) = &self.away {
            strings::format(lang, "cli.chat.away", &[("device", device)])
        } else if self.visiting.as_ref().is_some_and(|v| !v.awake) {
            strings::text(lang, "cli.chat.asleep").to_string()
        } else {
            strings::text(lang, "cli.chat.ready").to_string()
        }
    }

    /// The words of the answer that is arriving, here or at a visitor's home.
    fn streaming(&self) -> &str {
        match self.visiting.as_ref().and_then(|v| v.partial.as_deref()) {
            Some(partial) => partial,
            None => self.chat.streaming_text(),
        }
    }
}
