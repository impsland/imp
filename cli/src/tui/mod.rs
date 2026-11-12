//! The full-screen chat. `App` holds everything on the screen and has no input or output, so keys
//! and agent events can be tested without a terminal. `run` is the thin part that talks to one.
//!
//! `mod.rs` is the state and the keys, `view` draws it, `help` is the card the `?` key opens, `text`
//! measures and wraps, `terminal` owns the real terminal and the event loop.

mod help;
mod terminal;
mod text;
mod view;

#[cfg(test)]
mod tests;

use crate::chat_state::ChatState;
use crate::strings::{self, Lang};
use crate::theme::Theme;
use imp_core::AgentEvent;
use ratatui::crossterm::event::{
    KeyCode, KeyEvent, KeyEventKind, KeyModifiers, MouseEvent, MouseEventKind,
};
use std::cell::Cell;

pub use help::{Binding, GROUPS};
pub use terminal::run;
pub use text::{visible_start, wrap};

/// What a key asks the program to do.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Action {
    None,
    Quit,
    /// A message was added to the chat and the Imp should answer it.
    Send(String),
}

/// How many lines the mouse wheel moves.
const WHEEL_LINES: usize = 3;
/// The most lines the message field grows to, padding included.
const MAX_INPUT_HEIGHT: u16 = 8;

pub struct App {
    pub chat: ChatState,
    imp: String,
    model: String,
    input: String,
    /// How many lines the transcript is scrolled up from the bottom.
    scroll: usize,
    /// Set while drawing: the transcript's height and how far it can scroll.
    viewport: Cell<usize>,
    max_scroll: Cell<usize>,
    waiting: bool,
    retry: Option<String>,
    tool: Option<String>,
    error: Option<String>,
    help: bool,
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
            scroll: 0,
            viewport: Cell::new(10),
            max_scroll: Cell::new(0),
            waiting: false,
            retry: None,
            tool: None,
            error: None,
            help: false,
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
        match key.code {
            KeyCode::Esc => Action::Quit,
            KeyCode::Char('c') if ctrl => Action::Quit,
            KeyCode::Char('d') if ctrl && self.input.is_empty() => Action::Quit,
            KeyCode::F(1) => self.show_help(),
            KeyCode::Char('?') if self.input.is_empty() => self.show_help(),
            KeyCode::Char('u') if ctrl => self.edit(|input| input.clear()),
            KeyCode::Char('j') if ctrl => self.edit(|input| input.push('\n')),
            KeyCode::Enter if newline_mod => self.edit(|input| input.push('\n')),
            KeyCode::Enter => self.submit(),
            KeyCode::Backspace => self.edit(|input| {
                input.pop();
            }),
            KeyCode::Char(c) if !ctrl && !alt => self.edit(|input| input.push(c)),
            KeyCode::PageUp => self.scroll_by(self.page(), true),
            KeyCode::PageDown => self.scroll_by(self.page(), false),
            KeyCode::Up => self.scroll_by(1, true),
            KeyCode::Down => self.scroll_by(1, false),
            KeyCode::End => {
                self.scroll = 0;
                Action::None
            }
            _ => Action::None,
        }
    }

    fn show_help(&mut self) -> Action {
        self.help = true;
        Action::None
    }

    fn edit(&mut self, change: impl FnOnce(&mut String)) -> Action {
        change(&mut self.input);
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

    fn submit(&mut self) -> Action {
        let text = self.input.trim().to_string();
        match text.as_str() {
            "" => return Action::None,
            "/quit" | "/exit" => return Action::Quit,
            "/clear" if !self.waiting => {
                self.chat.clear();
                self.input.clear();
                self.scroll = 0;
                self.error = None;
                return Action::None;
            }
            _ => {}
        }
        if self.waiting || !self.chat.push_user(&text) {
            return Action::None;
        }
        self.input.clear();
        self.scroll = 0;
        self.error = None;
        self.waiting = true;
        Action::Send(text)
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
        self.input
            .push_str(&text.replace("\r\n", "\n").replace('\r', "\n"));
    }

    // --- the agent ----------------------------------------------------------------------------

    pub fn on_agent(&mut self, event: &AgentEvent) {
        match event {
            AgentEvent::Retry(n) => self.retry = Some(n.text()),
            AgentEvent::Stream(_) => self.retry = None,
            AgentEvent::ToolStart(call) => self.tool = Some(call.name.clone()),
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
        if let Some(retry) = &self.retry {
            retry.clone()
        } else if let Some(tool) = &self.tool {
            strings::format(lang, "cli.chat.using_tool", &[("tool", tool)])
        } else if self.waiting && self.chat.streaming_text().is_empty() {
            strings::text(lang, "cli.chat.thinking").to_string()
        } else if self.waiting {
            strings::text(lang, "cli.chat.answering").to_string()
        } else {
            strings::text(lang, "cli.chat.ready").to_string()
        }
    }
}
