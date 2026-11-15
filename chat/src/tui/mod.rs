//! The full-screen chat. `App` holds everything on the screen and has no input or output, so keys
//! and agent events can be tested without a terminal. `run` is the thin part that talks to one.
//!
//! `mod.rs` is the state and the keys, `view` draws it, `help` is the card the `?` key opens, `text`
//! measures and wraps, `terminal` owns the real terminal, the session, the device and the event loop.

mod help;
mod input;
mod menu;
mod terminal;
mod text;
mod view;

#[cfg(test)]
mod tests;

use crate::chat_state::ChatState;
use crate::link::device::{Visitor, messages_of};
use crate::slash::{self, Note};
use crate::strings::{self, Lang};
use crate::theme::Theme;
use imp_engine::{AgentEvent, ChatMessage};
use ratatui::crossterm::event::{
    KeyCode, KeyEvent, KeyEventKind, KeyModifiers, MouseEvent, MouseEventKind,
};
use std::cell::Cell;
use std::time::Instant;
use uuid::Uuid;

pub use help::{Binding, GROUPS};
pub use menu::Entry;
pub use terminal::run;
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
}

/// How many lines the mouse wheel moves.
const WHEEL_LINES: usize = 3;
/// The most lines the message field grows to, padding included.
const MAX_INPUT_HEIGHT: u16 = 8;
/// The most commands shown at once in the list under the field while one is typed.
const MOST_SUGGESTIONS: usize = 6;
/// The most messages kept to walk back through with Ctrl+P.
const MOST_RECALLED: usize = 100;

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
    /// How many lines the transcript is scrolled up from the bottom.
    scroll: usize,
    /// Set while drawing: the transcript's height and how far it can scroll.
    viewport: Cell<usize>,
    max_scroll: Cell<usize>,
    waiting: bool,
    /// When the answer that is arriving was asked for.
    started: Option<Instant>,
    retry: Option<String>,
    tool: Option<String>,
    error: Option<String>,
    help: bool,
    /// Lines from commands and devices, each after so many messages of the conversation.
    notes: Vec<(usize, Note)>,
    /// A command that is running, shown in the status line.
    busy: Option<String>,
    /// The device this Imp is on, while it is away.
    away: Option<String>,
    visiting: Option<Visiting>,
    /// What was sent before, for Ctrl+P and Ctrl+N.
    recalled: Vec<String>,
    recall_at: Option<usize>,
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
            scroll: 0,
            viewport: Cell::new(10),
            max_scroll: Cell::new(0),
            waiting: false,
            started: None,
            retry: None,
            tool: None,
            error: None,
            help: false,
            notes: Vec::new(),
            busy: None,
            away: None,
            visiting: None,
            recalled: Vec::new(),
            recall_at: None,
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

    /// The folder shown on the empty screen.
    pub fn in_folder(mut self, folder: &str) -> Self {
        self.folder = folder.to_string();
        self
    }

    pub fn input(&self) -> &str {
        &self.input
    }

    pub fn scroll(&self) -> usize {
        self.scroll
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

    // --- keys -------------------------------------------------------------------------------

    pub fn on_key(&mut self, key: KeyEvent) -> Action {
        if key.kind == KeyEventKind::Release {
            return Action::None;
        }
        if self.help {
            self.help = false;
            return Action::None;
        }
        let ctrl = key.modifiers.contains(KeyModifiers::CONTROL);
        let alt = key.modifiers.contains(KeyModifiers::ALT);
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
            KeyCode::Esc => Action::Quit,
            KeyCode::Char('c') if ctrl => Action::Quit,
            KeyCode::Char('d') if ctrl && self.input.is_empty() => Action::Quit,
            KeyCode::F(1) => self.show_help(),
            KeyCode::Char('?') if self.input.is_empty() => self.show_help(),
            KeyCode::Char('u') if ctrl => self.edit(|app| app.set_input(String::new())),
            KeyCode::Char('j') if ctrl => self.edit(|app| app.insert("\n")),
            KeyCode::Char('w') if ctrl => self.edit(App::delete_word_back),
            KeyCode::Char('a') if ctrl => self.move_cursor(App::line_start),
            KeyCode::Char('e') if ctrl => self.move_cursor(App::line_end),
            KeyCode::Char('p') if ctrl => self.recall(true),
            KeyCode::Char('n') if ctrl => self.recall(false),
            KeyCode::Up if open => self.move_pick(&menu, false),
            KeyCode::Down if open => self.move_pick(&menu, true),
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
                self.scroll = 0;
                Action::None
            }
            KeyCode::End => self.move_cursor(App::line_end),
            KeyCode::Char(c) if !ctrl && !alt => {
                self.edit(|app| app.insert(c.encode_utf8(&mut [0; 4])))
            }
            KeyCode::PageUp => self.scroll_by(self.page(), true),
            KeyCode::PageDown => self.scroll_by(self.page(), false),
            KeyCode::Up => self.scroll_by(1, true),
            KeyCode::Down => self.scroll_by(1, false),
            _ => Action::None,
        }
    }

    /// Enter on the highlighted command runs it, or completes it when it cannot run bare.
    fn enter(&mut self, menu: &menu::Menu) -> Action {
        if let Some(command) = self.picked(menu).and_then(|e| e.command) {
            if slash::needs_args(command) {
                return self.accept(menu);
            }
            self.set_input(command.name.to_string());
        }
        self.submit()
    }

    fn show_help(&mut self) -> Action {
        self.help = true;
        Action::None
    }

    /// A change to the text: it starts the `/` list over and leaves the walk through what was sent.
    fn edit(&mut self, change: impl FnOnce(&mut App)) -> Action {
        change(self);
        self.recall_at = None;
        self.pick = 0;
        self.menu_closed = false;
        Action::None
    }

    /// Ctrl+P puts the message sent before in the field, Ctrl+N the one after.
    fn recall(&mut self, back: bool) -> Action {
        if self.recalled.is_empty() {
            return Action::None;
        }
        let last = self.recalled.len() - 1;
        let at = match (self.recall_at, back) {
            (None, true) => Some(last),
            (None, false) => None,
            (Some(i), true) => Some(i.saturating_sub(1)),
            (Some(i), false) if i < last => Some(i + 1),
            (Some(_), false) => None,
        };
        self.recall_at = at;
        let text = at.map(|i| self.recalled[i].clone()).unwrap_or_default();
        self.set_input(text);
        Action::None
    }

    fn page(&self) -> usize {
        self.viewport.get().saturating_sub(1).max(1)
    }

    fn scroll_by(&mut self, lines: usize, up: bool) -> Action {
        if up {
            self.scroll = (self.scroll + lines).min(self.max_scroll.get());
        } else {
            self.scroll = self.scroll.saturating_sub(lines);
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
        if slash::is_command(&text) {
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
            self.scroll = 0;
            self.error = None;
            if !text.starts_with("/api_key") && !text.starts_with("/key") {
                self.remember(&text);
            }
            self.note(Note::info(format!("› {}", slash::shown(&text))));
            return Action::Command(text);
        }
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
        self.scroll = 0;
        self.error = None;
        self.waiting = true;
        self.started = Some(Instant::now());
        Action::Send(text)
    }

    /// Starts the conversation over. Notes go too.
    pub fn clear(&mut self) {
        self.chat.clear();
        self.notes.clear();
        self.scroll = 0;
        self.error = None;
    }

    pub fn on_mouse(&mut self, mouse: MouseEvent) {
        match mouse.kind {
            MouseEventKind::ScrollUp => {
                self.scroll_by(WHEEL_LINES, true);
            }
            MouseEventKind::ScrollDown => {
                self.scroll_by(WHEEL_LINES, false);
            }
            _ => {}
        }
    }

    pub fn on_paste(&mut self, text: &str) {
        let text = text.replace("\r\n", "\n").replace('\r', "\n");
        self.edit(|app| app.insert(&text));
    }

    // --- what the program tells the screen -----------------------------------------------------

    /// A line under the conversation so far. It is never sent to the model.
    pub fn note(&mut self, note: Note) {
        self.notes.push((self.chat.messages().len(), note));
        self.scroll = 0;
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
        self.scroll = 0;
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
            self.scroll = 0;
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

    // --- the agent ----------------------------------------------------------------------------

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
        if self.chat.is_streaming() {
            self.chat.abort_reply();
        }
        self.waiting = false;
        self.started = None;
        self.retry = None;
        self.tool = None;
        self.error = result.err();
    }

    /// A plain sentence about something that did not start, shown where problems are shown.
    pub fn warn(&mut self, sentence: &str) {
        self.error = Some(sentence.to_string());
    }

    /// What the status line says on its right side.
    pub fn activity(&self) -> String {
        let lang = self.lang;
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
