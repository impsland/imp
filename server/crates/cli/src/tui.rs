//! The full-screen chat. `App` holds everything on the screen and has no input or output, so keys
//! and agent events can be tested without a terminal. `run` is the thin part that talks to one.

use crate::chat_state::ChatState;
use crate::commands::Session;
use crate::{CliError, Result};
use imp_core::{AgentEvent, ChatMessage, Role, run_agent};
use ratatui::Frame;
use ratatui::crossterm::event::{
    DisableBracketedPaste, DisableMouseCapture, EnableBracketedPaste, EnableMouseCapture, Event,
    KeyCode, KeyEvent, KeyEventKind, KeyModifiers, MouseEvent, MouseEventKind,
};
use ratatui::crossterm::execute;
use ratatui::layout::{Constraint, Layout, Position, Rect};
use ratatui::style::{Color, Modifier, Style};
use ratatui::text::{Line, Span};
use ratatui::widgets::{Block, Borders, Paragraph};
use std::cell::Cell;
use std::future::Future;
use std::pin::Pin;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::Duration;

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
/// The most lines the input box grows to, border included.
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
        }
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

    // --- keys -------------------------------------------------------------------------------

    pub fn on_key(&mut self, key: KeyEvent) -> Action {
        if key.kind == KeyEventKind::Release {
            return Action::None;
        }
        let ctrl = key.modifiers.contains(KeyModifiers::CONTROL);
        let newline_mod = key
            .modifiers
            .intersects(KeyModifiers::SHIFT | KeyModifiers::ALT);
        match key.code {
            KeyCode::Esc => Action::Quit,
            KeyCode::Char('c') if ctrl => Action::Quit,
            KeyCode::Char('d') if ctrl && self.input.is_empty() => Action::Quit,
            KeyCode::Char('u') if ctrl => {
                self.input.clear();
                Action::None
            }
            KeyCode::Char('j') if ctrl => {
                self.input.push('\n');
                Action::None
            }
            KeyCode::Enter if newline_mod => {
                self.input.push('\n');
                Action::None
            }
            KeyCode::Enter => self.submit(),
            KeyCode::Backspace => {
                self.input.pop();
                Action::None
            }
            KeyCode::Char(c) if !ctrl && !key.modifiers.contains(KeyModifiers::ALT) => {
                self.input.push(c);
                Action::None
            }
            KeyCode::PageUp => {
                self.scroll_up(self.viewport.get().saturating_sub(1).max(1));
                Action::None
            }
            KeyCode::PageDown => {
                self.scroll_down(self.viewport.get().saturating_sub(1).max(1));
                Action::None
            }
            KeyCode::Up => {
                self.scroll_up(1);
                Action::None
            }
            KeyCode::Down => {
                self.scroll_down(1);
                Action::None
            }
            KeyCode::End => {
                self.scroll = 0;
                Action::None
            }
            _ => Action::None,
        }
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
            MouseEventKind::ScrollUp => self.scroll_up(WHEEL_LINES),
            MouseEventKind::ScrollDown => self.scroll_down(WHEEL_LINES),
            _ => {}
        }
    }

    pub fn on_paste(&mut self, text: &str) {
        self.input
            .push_str(&text.replace("\r\n", "\n").replace('\r', "\n"));
    }

    fn scroll_up(&mut self, lines: usize) {
        self.scroll = (self.scroll + lines).min(self.max_scroll.get());
    }

    fn scroll_down(&mut self, lines: usize) {
        self.scroll = self.scroll.saturating_sub(lines);
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

    // --- drawing ------------------------------------------------------------------------------

    /// What the status line says on its right side.
    pub fn activity(&self) -> String {
        if let Some(retry) = &self.retry {
            retry.clone()
        } else if let Some(tool) = &self.tool {
            format!("Using the tool {tool}")
        } else if self.waiting && self.chat.streaming_text().is_empty() {
            "Thinking".to_string()
        } else if self.waiting {
            "Answering".to_string()
        } else {
            "Ready".to_string()
        }
    }

    /// The transcript as lines of the given width.
    pub fn transcript(&self, width: usize) -> Vec<Line<'static>> {
        let mut lines = Vec::new();
        for message in self.chat.messages() {
            self.push_message(&mut lines, message, width);
        }
        if self.chat.is_streaming() {
            let text = format!("{}▌", self.chat.streaming_text());
            push_labelled(&mut lines, &self.imp, Color::Magenta, &text, width);
        }
        if let Some(error) = &self.error {
            let style = Style::default().fg(Color::Red);
            for l in wrap(&format!("Something went wrong: {error}"), width) {
                lines.push(Line::styled(l, style));
            }
        }
        lines
    }

    fn push_message(&self, lines: &mut Vec<Line<'static>>, message: &ChatMessage, width: usize) {
        let dim = Style::default().fg(Color::DarkGray);
        match message.role {
            Role::User => push_labelled(lines, "you", Color::Cyan, &message.content, width),
            Role::Assistant => {
                if !message.content.is_empty() {
                    push_labelled(lines, &self.imp, Color::Magenta, &message.content, width);
                }
                for call in &message.tool_calls {
                    let text = format!("{} uses the tool {}", self.imp, call.name);
                    lines.extend(wrap(&text, width).into_iter().map(|l| Line::styled(l, dim)));
                }
            }
            Role::Tool => {
                let first = message.content.lines().next().unwrap_or("");
                let text = format!("  result: {}", truncate(first, width.saturating_sub(12)));
                lines.push(Line::styled(text, dim));
            }
            Role::System => {}
        }
        if message.role != Role::Tool
            && !(message.role == Role::Assistant && message.content.is_empty())
        {
            lines.push(Line::raw(""));
        }
    }

    pub fn render(&self, frame: &mut Frame) {
        let area = frame.area();
        let input_lines = wrap(&self.input, (area.width as usize).saturating_sub(2).max(1));
        let input_height = (input_lines.len() as u16 + 2).clamp(3, MAX_INPUT_HEIGHT);
        let [top, input_area, status] = Layout::vertical([
            Constraint::Min(1),
            Constraint::Length(input_height),
            Constraint::Length(1),
        ])
        .areas(area);
        self.render_transcript(frame, top);
        self.render_input(frame, input_area, &input_lines);
        frame.render_widget(self.status_line(status.width), status);
    }

    fn render_transcript(&self, frame: &mut Frame, area: Rect) {
        let lines = self.transcript(area.width.max(1) as usize);
        let height = area.height as usize;
        let (start, max) = visible_start(lines.len(), height, self.scroll);
        self.viewport.set(height);
        self.max_scroll.set(max);
        let shown: Vec<Line> = lines.into_iter().skip(start).take(height).collect();
        frame.render_widget(Paragraph::new(shown), area);
    }

    fn render_input(&self, frame: &mut Frame, area: Rect, lines: &[String]) {
        let title = if self.waiting {
            " Message (wait for the answer, then press Enter) "
        } else {
            " Message (Enter sends, Alt+Enter adds a line) "
        };
        let block = Block::default().borders(Borders::ALL).title(title);
        let inner_height = area.height.saturating_sub(2) as usize;
        let skip = lines.len().saturating_sub(inner_height);
        let shown: Vec<Line> = lines
            .iter()
            .skip(skip)
            .map(|l| Line::raw(l.clone()))
            .collect();
        frame.render_widget(Paragraph::new(shown).block(block), area);
        let row = lines.len().saturating_sub(skip).saturating_sub(1) as u16;
        let col = lines.last().map_or(0, |l| text_width(l)) as u16;
        frame.set_cursor_position(Position::new(
            (area.x + 1 + col).min(area.right().saturating_sub(2)),
            area.y + 1 + row,
        ));
    }

    fn status_line(&self, width: u16) -> Line<'static> {
        let left = format!(" {} · {} ", self.imp, self.model);
        let mut right = format!(" {} · Esc quits ", self.activity());
        if text_width(&left) + text_width(&right) > width as usize {
            right = format!(" {} ", self.activity());
        }
        let gap = (width as usize).saturating_sub(text_width(&left) + text_width(&right));
        let style = Style::default().add_modifier(Modifier::REVERSED);
        Line::from(vec![
            Span::styled(left, style.add_modifier(Modifier::BOLD)),
            Span::styled(" ".repeat(gap), style),
            Span::styled(right, style),
        ])
    }
}

fn text_width(s: &str) -> usize {
    textwrap::core::display_width(s)
}

fn truncate(s: &str, max: usize) -> String {
    if text_width(s) <= max {
        return s.to_string();
    }
    let mut out = String::new();
    for c in s.chars() {
        if text_width(&out) + 1 >= max {
            break;
        }
        out.push(c);
    }
    out.push('…');
    out
}

fn push_labelled(
    lines: &mut Vec<Line<'static>>,
    label: &str,
    color: Color,
    text: &str,
    width: usize,
) {
    let prefix = format!("{label}: ");
    let wrapped = wrap(&format!("{prefix}{text}"), width);
    for (i, line) in wrapped.into_iter().enumerate() {
        if i == 0 && line.starts_with(&prefix) {
            let rest = line[prefix.len()..].to_string();
            lines.push(Line::from(vec![
                Span::styled(
                    prefix.clone(),
                    Style::default().fg(color).add_modifier(Modifier::BOLD),
                ),
                Span::raw(rest),
            ]));
        } else {
            lines.push(Line::raw(line));
        }
    }
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

// --- the terminal -------------------------------------------------------------------------------

/// Puts the terminal back as it was, also when the program panics or returns early.
struct Restore;

impl Restore {
    fn start() -> std::io::Result<(Self, ratatui::DefaultTerminal)> {
        let terminal = ratatui::try_init()?;
        let guard = Self;
        execute!(std::io::stdout(), EnableMouseCapture, EnableBracketedPaste)?;
        let previous = std::panic::take_hook();
        std::panic::set_hook(Box::new(move |info| {
            Self::undo();
            previous(info);
        }));
        Ok((guard, terminal))
    }

    fn undo() {
        let _ = execute!(
            std::io::stdout(),
            DisableMouseCapture,
            DisableBracketedPaste
        );
        ratatui::restore();
    }
}

impl Drop for Restore {
    fn drop(&mut self) {
        Self::undo();
    }
}

type AgentRun = Pin<Box<dyn Future<Output = std::result::Result<(), String>>>>;

/// Runs the full-screen chat until the person leaves.
pub async fn run(session: Session) -> Result<()> {
    let (_guard, mut terminal) = Restore::start()?;
    let stop = Arc::new(AtomicBool::new(false));
    let (key_tx, mut key_rx) = tokio::sync::mpsc::unbounded_channel::<Event>();
    let reader_stop = stop.clone();
    std::thread::spawn(move || {
        use ratatui::crossterm::event::{poll, read};
        while !reader_stop.load(Ordering::Relaxed) {
            match poll(Duration::from_millis(100)) {
                Ok(true) => match read() {
                    Ok(event) => {
                        if key_tx.send(event).is_err() {
                            break;
                        }
                    }
                    Err(_) => break,
                },
                Ok(false) => {}
                Err(_) => break,
            }
        }
    });
    let result = event_loop(&mut terminal, session, &mut key_rx).await;
    stop.store(true, Ordering::Relaxed);
    result
}

async fn event_loop(
    terminal: &mut ratatui::DefaultTerminal,
    session: Session,
    keys: &mut tokio::sync::mpsc::UnboundedReceiver<Event>,
) -> Result<()> {
    let mut app = App::new(&session.name, &session.model, &session.system);
    for warning in &session.warnings {
        app.error = Some(warning.clone());
    }
    let (agent_tx, mut agent_rx) = tokio::sync::mpsc::unbounded_channel::<AgentEvent>();
    let mut running: Option<AgentRun> = None;
    loop {
        terminal
            .draw(|frame| app.render(frame))
            .map_err(|e| CliError(e.to_string()))?;
        tokio::select! {
            biased;
            Some(event) = keys.recv() => {
                let action = match event {
                    Event::Key(key) => app.on_key(key),
                    Event::Mouse(mouse) => { app.on_mouse(mouse); Action::None }
                    Event::Paste(text) => { app.on_paste(&text); Action::None }
                    _ => Action::None,
                };
                match action {
                    Action::Quit => return Ok(()),
                    Action::Send(_) => running = Some(start_agent(&session, &app, &agent_tx)),
                    Action::None => {}
                }
            }
            Some(event) = agent_rx.recv() => app.on_agent(&event),
            result = async {
                match running.as_mut() {
                    Some(run) => run.await,
                    None => std::future::pending().await,
                }
            } => {
                while let Ok(event) = agent_rx.try_recv() {
                    app.on_agent(&event);
                }
                running = None;
                app.on_done(result);
            }
        }
    }
}

fn start_agent(
    session: &Session,
    app: &App,
    events: &tokio::sync::mpsc::UnboundedSender<AgentEvent>,
) -> AgentRun {
    let client = session.client.clone();
    let toolbox = session.toolbox.clone();
    let selection = session.selection.clone();
    let (model, steps) = (session.model.clone(), session.max_steps);
    let mut messages = app.chat.request_messages();
    let tx = events.clone();
    Box::pin(async move {
        run_agent(
            &client,
            &model,
            &mut messages,
            &*toolbox,
            &selection,
            steps,
            |e| {
                let _ = tx.send(e);
            },
        )
        .await
        .map(|_| ())
        .map_err(|e| e.to_string())
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use imp_core::{RetryNotice, StreamEvent, ToolCall};
    use ratatui::Terminal;
    use ratatui::backend::TestBackend;

    fn key(code: KeyCode) -> KeyEvent {
        KeyEvent::new(code, KeyModifiers::NONE)
    }

    fn with(code: KeyCode, m: KeyModifiers) -> KeyEvent {
        KeyEvent::new(code, m)
    }

    fn type_text(app: &mut App, text: &str) {
        for c in text.chars() {
            app.on_key(key(KeyCode::Char(c)));
        }
    }

    fn screen(app: &App, w: u16, h: u16) -> Vec<String> {
        let mut terminal = Terminal::new(TestBackend::new(w, h)).unwrap();
        terminal.draw(|f| app.render(f)).unwrap();
        let buffer = terminal.backend().buffer().clone();
        (0..h)
            .map(|y| {
                (0..w)
                    .map(|x| buffer[(x, y)].symbol().to_string())
                    .collect::<String>()
                    .trim_end()
                    .to_string()
            })
            .collect()
    }

    fn answer(app: &mut App, text: &str) {
        for e in [
            AgentEvent::StepStart,
            AgentEvent::Stream(StreamEvent::Text(text.into())),
            AgentEvent::StepEnd,
        ] {
            app.on_agent(&e);
        }
        app.on_done(Ok(()));
    }

    #[test]
    fn wrapping_keeps_breaks_and_splits_long_words() {
        assert_eq!(wrap("one two three", 7), ["one two", "three"]);
        assert_eq!(wrap("a\n\nb", 10), ["a", "", "b"]);
        assert_eq!(wrap("abcdefgh", 3), ["abc", "def", "gh"]);
        assert_eq!(wrap("", 5), [""]);
        assert_eq!(wrap("x", 0), ["x"]);
        assert_eq!(wrap("日本語日本語", 6), ["日本語", "日本語"]);
    }

    #[test]
    fn the_visible_window() {
        assert_eq!(visible_start(3, 10, 0), (0, 0));
        assert_eq!(visible_start(30, 10, 0), (20, 20));
        assert_eq!(visible_start(30, 10, 5), (15, 20));
        assert_eq!(visible_start(30, 10, 99), (0, 20));
    }

    #[test]
    fn typing_editing_and_sending() {
        let mut app = App::new("pip", "m", "sys");
        type_text(&mut app, "helo");
        app.on_key(key(KeyCode::Backspace));
        type_text(&mut app, "lo");
        assert_eq!(app.input(), "hello");
        assert_eq!(
            app.on_key(key(KeyCode::Enter)),
            Action::Send("hello".into())
        );
        assert_eq!(app.input(), "");
        assert!(app.is_waiting());
        assert_eq!(app.chat.messages().len(), 1);
        // Nothing is sent while the answer is on its way.
        type_text(&mut app, "more");
        assert_eq!(app.on_key(key(KeyCode::Enter)), Action::None);
        assert_eq!(app.input(), "more");
        answer(&mut app, "Hi");
        assert!(!app.is_waiting());
        assert_eq!(app.on_key(key(KeyCode::Enter)), Action::Send("more".into()));
    }

    #[test]
    fn empty_input_sends_nothing_and_newlines_are_kept() {
        let mut app = App::new("pip", "m", "sys");
        assert_eq!(app.on_key(key(KeyCode::Enter)), Action::None);
        type_text(&mut app, "a");
        app.on_key(with(KeyCode::Enter, KeyModifiers::ALT));
        type_text(&mut app, "b");
        app.on_key(with(KeyCode::Enter, KeyModifiers::SHIFT));
        app.on_key(with(KeyCode::Char('j'), KeyModifiers::CONTROL));
        type_text(&mut app, "c");
        assert_eq!(app.input(), "a\nb\n\nc");
        app.on_paste("x\r\ny");
        assert_eq!(app.input(), "a\nb\n\ncx\ny");
        app.on_key(with(KeyCode::Char('u'), KeyModifiers::CONTROL));
        assert_eq!(app.input(), "");
    }

    #[test]
    fn leaving_and_commands() {
        let mut app = App::new("pip", "m", "sys");
        assert_eq!(app.on_key(key(KeyCode::Esc)), Action::Quit);
        assert_eq!(
            app.on_key(with(KeyCode::Char('c'), KeyModifiers::CONTROL)),
            Action::Quit
        );
        assert_eq!(
            app.on_key(with(KeyCode::Char('d'), KeyModifiers::CONTROL)),
            Action::Quit
        );
        type_text(&mut app, "/quit");
        assert_eq!(app.on_key(key(KeyCode::Enter)), Action::Quit);
        let mut app = App::new("pip", "m", "sys");
        type_text(&mut app, "hi");
        app.on_key(key(KeyCode::Enter));
        answer(&mut app, "yo");
        type_text(&mut app, "/clear");
        assert_eq!(app.on_key(key(KeyCode::Enter)), Action::None);
        assert!(app.chat.messages().is_empty());
        let mut released = key(KeyCode::Esc);
        released.kind = KeyEventKind::Release;
        assert_eq!(app.on_key(released), Action::None);
    }

    #[test]
    fn scrolling_stays_inside_the_transcript() {
        let mut app = App::new("pip", "m", "sys");
        for i in 0..12 {
            type_text(&mut app, &format!("question {i}"));
            app.on_key(key(KeyCode::Enter));
            answer(&mut app, &format!("answer {i}"));
        }
        let before = screen(&app, 40, 12);
        assert!(before.iter().any(|l| l.contains("answer 11")));
        assert!(!before.iter().any(|l| l.contains("question 0")));
        app.on_key(key(KeyCode::PageUp));
        assert!(app.scroll() > 0);
        let after = screen(&app, 40, 12);
        assert!(!after.iter().any(|l| l.contains("answer 11")));
        for _ in 0..20 {
            app.on_key(key(KeyCode::PageUp));
        }
        let top = screen(&app, 40, 12);
        assert!(top.iter().any(|l| l.contains("question 0")));
        let max = app.scroll();
        app.on_key(key(KeyCode::PageUp));
        assert_eq!(app.scroll(), max);
        app.on_key(key(KeyCode::End));
        assert_eq!(app.scroll(), 0);
        app.on_mouse(MouseEvent {
            kind: MouseEventKind::ScrollUp,
            column: 0,
            row: 0,
            modifiers: KeyModifiers::NONE,
        });
        assert_eq!(app.scroll(), WHEEL_LINES);
        app.on_key(key(KeyCode::PageDown));
        assert_eq!(app.scroll(), 0);
    }

    #[test]
    fn the_screen_shows_transcript_input_and_status() {
        let mut app = App::new("pip", "gpt-5", "sys");
        type_text(&mut app, "Hello there, little friend");
        app.on_key(key(KeyCode::Enter));
        app.on_agent(&AgentEvent::StepStart);
        app.on_agent(&AgentEvent::Stream(StreamEvent::Text(
            "Well hi, this answer wraps around".into(),
        )));
        type_text(&mut app, "draft");
        let rows = screen(&app, 24, 12);
        let text = rows.join("\n");
        assert!(rows[0].starts_with("you: Hello there,"), "{text}");
        assert!(text.contains("pip: Well hi, this"), "{text}");
        assert!(text.contains('▌'));
        assert!(rows[8].contains("Message"), "{text}");
        assert!(rows[9].starts_with("│draft"), "{text}");
        assert!(rows[11].starts_with(" pip · gpt-5"), "{text}");
        assert!(rows[11].contains("Answering"), "{text}");
    }

    #[test]
    fn status_shows_retries_and_tools() {
        let mut app = App::new("pip", "m", "sys");
        assert_eq!(app.activity(), "Ready");
        type_text(&mut app, "go");
        app.on_key(key(KeyCode::Enter));
        assert_eq!(app.activity(), "Thinking");
        app.on_agent(&AgentEvent::StepStart);
        app.on_agent(&AgentEvent::Retry(RetryNotice {
            attempt: 2,
            of: 3,
            delay: Duration::ZERO,
        }));
        assert_eq!(app.activity(), "Retrying 2 of 3");
        assert!(screen(&app, 60, 8)[7].contains("Retrying 2 of 3"));
        app.on_agent(&AgentEvent::Stream(StreamEvent::ToolCallDelta {
            index: 0,
            id: Some("c".into()),
            name: Some("files__read".into()),
            arguments: "{}".into(),
        }));
        app.on_agent(&AgentEvent::StepEnd);
        app.on_agent(&AgentEvent::ToolStart(ToolCall {
            id: "c".into(),
            name: "files__read".into(),
            arguments: "{}".into(),
        }));
        assert_eq!(app.activity(), "Using the tool files__read");
        app.on_agent(&AgentEvent::ToolResult {
            call_id: "c".into(),
            name: "files__read".into(),
            content: "contents\nsecond line".into(),
        });
        let text = screen(&app, 60, 10).join("\n");
        assert!(text.contains("pip uses the tool files__read"), "{text}");
        assert!(text.contains("result: contents"), "{text}");
        assert!(!text.contains("second line"));
    }

    #[test]
    fn a_failed_answer_keeps_what_arrived_and_shows_the_problem() {
        let mut app = App::new("pip", "m", "sys");
        type_text(&mut app, "go");
        app.on_key(key(KeyCode::Enter));
        app.on_agent(&AgentEvent::StepStart);
        app.on_agent(&AgentEvent::Stream(StreamEvent::Text("Half".into())));
        app.on_done(Err("the service answered 500: oops".into()));
        assert!(!app.chat.is_streaming());
        assert_eq!(app.chat.messages().last().unwrap().content, "Half");
        let text = screen(&app, 50, 10).join("\n");
        assert!(
            text.contains("Something went wrong: the service answered 500"),
            "{text}"
        );
        assert_eq!(app.activity(), "Ready");
    }

    #[test]
    fn a_tiny_terminal_does_not_panic() {
        let mut app = App::new("pip", "m", "sys");
        type_text(
            &mut app,
            "hello\nthere\nfriend\nof\nmine\nand\nmore\nlines\nhere",
        );
        for (w, h) in [(1, 1), (3, 4), (10, 3), (80, 2)] {
            let _ = screen(&app, w, h);
        }
    }
}
