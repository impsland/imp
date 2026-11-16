//! The real terminal: raw mode, the reader thread and the event loop. The loop owns the session (the Imp on
//! screen), this computer on the link once it is started, and the answer that is arriving. It waits for
//! keys, the answer and the link at once, so a phone can talk to an Imp here while the chat is open.

use super::{Action, App, clipboard};
use crate::chat_state::ChatState;
use crate::link::SeedFile;
use crate::link::device::{Device, DeviceOptions, StartError, Update};
use crate::mentions;
use crate::project::shown_path;
use crate::session::{Session, SessionOptions};
use crate::slash::{self, Context, Note, Outcome};
use crate::troupe::{Arrival, Later};
use crate::{CliError, Result};
use imp_engine::{AgentEvent, run_agent};
use ratatui::crossterm::event::{
    DisableBracketedPaste, DisableMouseCapture, EnableBracketedPaste, EnableMouseCapture, Event,
};
use ratatui::crossterm::execute;
use std::collections::VecDeque;
use std::future::Future;
use std::path::Path;
use std::pin::Pin;
use std::rc::Rc;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::Duration;
use uuid::Uuid;

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
type Events = tokio::sync::mpsc::UnboundedReceiver<Event>;

/// Reads terminal events on a thread of its own until `stop` is set.
fn read_events(stop: Arc<AtomicBool>, events: tokio::sync::mpsc::UnboundedSender<Event>) {
    use ratatui::crossterm::event::{poll, read};
    while !stop.load(Ordering::Relaxed) {
        match poll(Duration::from_millis(100)) {
            Ok(true) => match read() {
                Ok(event) => {
                    if events.send(event).is_err() {
                        break;
                    }
                }
                Err(_) => break,
            },
            Ok(false) => {}
            Err(_) => break,
        }
    }
}

/// Runs the full-screen chat until the person leaves. `online`: go online for the linked devices, if this
/// computer was ever linked.
pub async fn run(
    path: &Path,
    name: Option<&str>,
    options: DeviceOptions,
    online: bool,
) -> Result<()> {
    let mut device = None;
    let mut device_note = None;
    if online && options.has_book() {
        match Device::start(
            &options,
            // The chat never reads the system keychain, so it never asks for a password.
            Arc::new(SeedFile::for_dir(&options.data_dir)),
        )
        .await
        {
            Ok(d) => device = Some(d),
            Err(StartError::Busy) => device_note = Some(StartError::Busy.to_string()),
            Err(e) => device_note = Some(format!("Your devices can't reach this chat: {e}")),
        }
    }
    let session = Session::open(
        path,
        name,
        SessionOptions {
            workspace: options.workspace.clone(),
            remote: device.as_ref().map(Device::remote),
            agents_home: None,
            answers_later: true,
        },
    )
    .await?;
    let (_guard, mut terminal) = Restore::start()?;
    let stop = Arc::new(AtomicBool::new(false));
    let (key_tx, mut key_rx) = tokio::sync::mpsc::unbounded_channel::<Event>();
    let reader_stop = stop.clone();
    std::thread::spawn(move || read_events(reader_stop, key_tx));
    let mut chat = Chat {
        session,
        device,
        options,
        visiting: None,
        stash: None,
        arrived: VecDeque::new(),
    };
    let result = chat
        .event_loop(&mut terminal, &mut key_rx, device_note)
        .await;
    stop.store(true, Ordering::Relaxed);
    chat.session.close().await;
    if let Some(device) = chat.device.take() {
        device.stop().await;
    }
    result
}

fn handle(app: &mut App, event: Event) -> Action {
    match event {
        Event::Key(key) => app.on_key(key),
        Event::Mouse(mouse) => app.on_mouse(mouse),
        Event::Paste(text) => {
            app.on_paste(&text);
            Action::None
        }
        _ => Action::None,
    }
}

/// Everything the loop owns apart from the screen.
struct Chat {
    session: Session,
    device: Option<Device>,
    options: DeviceOptions,
    /// The visitor on screen, if it is one.
    visiting: Option<Uuid>,
    /// The conversation with this computer's Imp, kept while a visitor is on screen.
    stash: Option<ChatState>,
    /// Answers to messages the Imp sent without waiting, for when it is free to read them. Each becomes a new
    /// message at the end of its chat. Nothing earlier is changed.
    arrived: VecDeque<Arrival>,
}

/// Waits for the next answer to a message the Imp sent without waiting, or forever when it can't send any.
async fn next_answer(later: Option<Rc<Later>>) -> Arrival {
    match later {
        Some(later) => later.next().await,
        None => std::future::pending().await,
    }
}

/// Waits for the next update of the device, or forever when there is none.
async fn next_update(device: &mut Option<Device>) -> Update {
    match device {
        Some(d) => d.next().await,
        None => std::future::pending().await,
    }
}

impl Chat {
    async fn event_loop(
        &mut self,
        terminal: &mut ratatui::DefaultTerminal,
        keys: &mut Events,
        device_note: Option<String>,
    ) -> Result<()> {
        let folder = shown_path(&self.session.workspace);
        let mut app = App::new(
            &self.session.name,
            &self.session.model,
            &self.session.system,
        )
        .in_folder(&folder)
        .with_context(&self.context(crate::strings::Lang::detect()));
        app.chat.set_exchanges(self.session.memory_exchanges);
        app.set_files(mentions::list_files(&self.session.workspace));
        app.set_custom_commands(crate::project::load_custom_commands(
            &self.session.workspace,
        ));
        for warning in &self.session.warnings {
            app.note(Note::problem(warning.clone()));
        }
        for notice in &self.session.notices {
            app.note(Note::info(notice.clone()));
        }
        if let Some(note) = device_note {
            app.note(Note::info(note));
        }
        self.note_away(&mut app);
        let (agent_tx, mut agent_rx) = tokio::sync::mpsc::unbounded_channel::<AgentEvent>();
        let mut running: Option<AgentRun> = None;
        // Redraws ten times a second while an answer is on its way, so the spinner turns and the seconds
        // move, and once in a while for a word in the status line that goes away.
        let mut tick = tokio::time::interval(Duration::from_millis(100));
        tick.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
        // Scrolls while text is dragged past the top or bottom of the transcript.
        let mut edge = tokio::time::interval(Duration::from_millis(50));
        loop {
            self.wake(&mut app, &mut running, &agent_tx);
            terminal
                .draw(|frame| app.render(frame))
                .map_err(|e| CliError(format!("The screen could not be drawn: {e}")))?;
            let later = self.session.later.clone();
            tokio::select! {
                biased;
                Some(event) = keys.recv() => match handle(&mut app, event) {
                    Action::Quit => return Ok(()),
                    Action::Copy(text) => {
                        clipboard::copy(&text);
                        app.copied();
                    }
                    Action::Send(text) => {
                        let text = self.attach(&mut app, text);
                        match self.visiting {
                        Some(visitor) => {
                            let asked = match &self.device {
                                Some(d) => d.ask_visitor(visitor, &text).await,
                                None => Err(CliError("The link stopped.".into())),
                            };
                            if let Err(e) = asked {
                                app.on_done(Err(e.0));
                            }
                        }
                        None => {
                            if let Some(later) = &self.session.later {
                                later.set_depth(0);
                            }
                            running = Some(start_agent(&self.session, &app, &agent_tx));
                        }
                        }
                    }
                    Action::Stop => {
                        if running.take().is_some() {
                            while let Ok(event) = agent_rx.try_recv() {
                                app.on_agent(&event);
                            }
                            app.on_stopped();
                            app.note(Note::info("Stopped."));
                        } else if let (Some(visitor), Some(device)) = (self.visiting, &self.device) {
                            device.tell_visitor(visitor, false).await;
                        }
                    }
                    Action::Command(line) => {
                        app.set_busy(Some(format!("Running {}…", line.split_whitespace().next().unwrap_or(""))));
                        terminal
                            .draw(|frame| app.render(frame))
                            .map_err(|e| CliError(format!("The screen could not be drawn: {e}")))?;
                        let quit = self.command(&mut app, &line).await;
                        app.set_busy(None);
                        if quit {
                            return Ok(());
                        }
                    }
                    Action::None => {}
                },
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
                    self.note_long_chat(&mut app);
                    // The Imp may have made or removed files, and a command may have been added.
                    app.set_files(mentions::list_files(&self.session.workspace));
                    app.set_custom_commands(crate::project::load_custom_commands(&self.session.workspace));
                }
                update = next_update(&mut self.device) => self.on_update(&mut app, update),
                arrival = next_answer(later) => self.arrived.push_back(arrival),
                _ = tick.tick(), if app.is_animating() || app.has_flash() => {}
                _ = edge.tick(), if app.edge_scrolling() => app.on_edge_tick(),
            }
        }
    }

    /// An answer to a message the Imp sent without waiting wakes it when it is free: the answer is added to
    /// its chat as a new message, framed as an event, and it takes a turn on it like on any message. While a
    /// turn is running (or a visitor or a command is on screen) the answer waits its turn.
    fn wake(
        &mut self,
        app: &mut App,
        running: &mut Option<AgentRun>,
        events: &tokio::sync::mpsc::UnboundedSender<AgentEvent>,
    ) {
        let idle = running.is_none()
            && self.visiting.is_none()
            && app.away().is_none()
            && !app.is_waiting();
        if !idle {
            return;
        }
        let Some(arrival) = self.arrived.front() else {
            return;
        };
        if !app.wake(&arrival.event()) {
            return;
        }
        if let Some(later) = &self.session.later {
            later.set_depth(arrival.wakes_at());
        }
        self.arrived.pop_front();
        *running = Some(start_agent(&self.session, app, events));
    }

    /// Puts the files a message names with `@` in it, for the model. The chat shows what was written.
    fn attach(&self, app: &mut App, text: String) -> String {
        let attached = mentions::attach(&text, &self.session.workspace);
        for problem in attached.problems {
            app.note(Note::problem(problem));
        }
        match attached.content {
            Some(content) => {
                app.chat.amend_last_user(content.clone());
                content
            }
            None => text,
        }
    }

    /// What the folder adds, in a few words for the empty screen: `AGENTS.md · 3 skills · mcp.json`.
    fn context(&self, lang: crate::strings::Lang) -> String {
        let project = &self.session.project;
        let mut parts: Vec<String> = Vec::new();
        if !project.instructions.is_empty() {
            parts.push("AGENTS.md".into());
        }
        if !project.skills.is_empty() {
            parts.push(crate::strings::format(
                lang,
                "cli.chat.context_skills",
                &[("count", &project.skills.len().to_string())],
            ));
        }
        if let Some(file) = self.session.agent_file() {
            let name = file.file_name().map(|n| n.to_string_lossy().to_string());
            parts.extend(name);
        }
        if project.mcp.iter().any(|f| f.trusted) {
            parts.push("mcp.json".into());
        }
        parts.join(" · ")
    }

    /// Runs a `/` command. True when the chat should end.
    async fn command(&mut self, app: &mut App, line: &str) -> bool {
        let history = app.chat.messages().to_vec();
        let outcome = slash::run(
            line,
            Context {
                session: &mut self.session,
                device: &mut self.device,
                device_options: Some(&self.options),
                visiting: self.visiting,
                history: &history,
            },
        )
        .await;
        match outcome {
            Outcome::Quit => return true,
            Outcome::Clear => {
                if let (Some(visitor), Some(device)) = (self.visiting, &self.device) {
                    device.tell_visitor(visitor, true).await;
                }
                app.clear();
            }
            Outcome::Notes(notes) => {
                app.notes_from(notes);
                if self.visiting.is_none() {
                    app.set_model(&self.session.model, &self.session.system);
                    app.chat.set_exchanges(self.session.memory_exchanges);
                }
            }
            Outcome::Compact => self.compact(app).await,
            Outcome::Sent(notes) => app.notes_from(notes),
            Outcome::Switch(name) => self.switch(app, &name).await,
            Outcome::Visit(id) => self.visit(app, id),
            Outcome::CameHome { imp, messages } => self.came_home(app, &imp, messages),
        }
        false
    }

    /// `/compact`: the model sums up what it remembers, and the chat goes on from the summary.
    async fn compact(&mut self, app: &mut App) {
        if app.chat.memory().is_empty() {
            app.note(Note::info("There is nothing to sum up yet."));
            return;
        }
        match self.session.recap(app.chat.memory()).await {
            Ok(summary) if app.chat.recapped(&summary) => {
                app.note(Note::info(format!(
                    "Summed up the chat. {} goes on from this instead of everything said before the last message:",
                    self.session.name
                )));
                app.note(Note::info(summary));
            }
            Ok(_) => app.note(Note::problem(
                "The summary came back empty, so nothing changed.",
            )),
            Err(e) => app.note(Note::problem(e.0)),
        }
    }

    /// Says once when a chat has grown long, and what to do about it.
    fn note_long_chat(&self, app: &mut App) {
        if self.visiting.is_some() {
            return;
        }
        if let Some(tokens) = app.chat.long_chat_notice(self.session.long_chat_tokens) {
            app.note(Note::info(long_chat_sentence(tokens)));
        }
    }

    /// Talk to a visiting Imp: its chat lives at its home. This computer's conversation waits.
    fn visit(&mut self, app: &mut App, id: Uuid) {
        let Some(visitor) = self.device.as_ref().and_then(|d| d.visitor(id)) else {
            return;
        };
        if self.visiting.is_none() {
            self.stash = Some(std::mem::take(&mut app.chat));
        }
        self.visiting = Some(id);
        app.show_visitor(&visitor);
        app.note(Note::info(format!(
            "{} is visiting from {}: it thinks there, and what you say goes there. `/return` sends it back, `/imp {}` comes back here.",
            visitor.look.name, visitor.home_name, self.session.name
        )));
    }

    /// A visitor came over. As on a desktop it shows at once, when nothing is going on here: the Imp on
    /// screen is away, or nothing was said yet. Otherwise the note says how to talk to it.
    fn arrived(&mut self, app: &mut App, id: Uuid) {
        let idle = self.visiting.is_none()
            && !app.is_waiting()
            && (app.away().is_some() || app.chat.messages().is_empty());
        if idle {
            self.visit(app, id);
        }
    }

    /// Talk to another Imp of this computer.
    async fn switch(&mut self, app: &mut App, name: &str) {
        if name == self.session.name {
            if self.visiting.take().is_none() {
                app.note(Note::info(format!("This is {name} already.")));
                return;
            }
            let chat = self.stash.take().unwrap_or_else(|| self.session.new_chat());
            app.switch(&self.session.name, &self.session.model, chat);
            self.note_away(app);
            return;
        }
        let options = SessionOptions {
            workspace: Some(self.session.workspace.clone()),
            remote: self.device.as_ref().map(Device::remote),
            agents_home: None,
            answers_later: true,
        };
        match Session::open(&self.session.path, Some(name), options).await {
            Ok(next) => {
                let old = std::mem::replace(&mut self.session, next);
                old.close().await;
                self.visiting = None;
                self.stash = None;
                // Answers to what the other Imp sent are lost with it.
                self.arrived.clear();
                let chat = self.session.new_chat();
                app.switch(&self.session.name, &self.session.model, chat);
                for warning in &self.session.warnings {
                    app.note(Note::problem(warning.clone()));
                }
                self.note_away(app);
            }
            Err(e) => app.note(Note::problem(e.0)),
        }
    }

    /// Says so when the Imp on screen is on another device.
    fn note_away(&self, app: &mut App) {
        let id = self.session.imp.id.unwrap_or_default();
        if let Some(on) = self.device.as_ref().and_then(|d| d.away_on(id)) {
            app.set_away(Some(on.clone()));
            app.note(Note::info(format!(
                "{} is on {on}. It thinks here while this chat is open. /call brings it back.",
                self.session.name
            )));
        }
    }

    fn came_home(&mut self, app: &mut App, imp: &str, messages: Vec<imp_engine::ChatMessage>) {
        if imp == self.session.name && self.visiting.is_none() {
            let mut chat = self.session.chat_from(messages);
            // What was said here before it left is kept when it says nothing new.
            if chat.messages().is_empty() {
                chat = self.session.chat_from(app.chat.messages().to_vec());
            }
            app.switch(&self.session.name, &self.session.model, chat);
            app.note(Note::info(format!("{imp} is back.")));
        } else {
            app.note(Note::info(format!("{imp} is back on this computer.")));
        }
    }

    fn on_update(&mut self, app: &mut App, update: Update) {
        match update {
            Update::Note(text) => app.note(Note::info(text)),
            Update::Problem(text) => app.note(Note::problem(text)),
            Update::Visitor(id) => {
                if self.visiting == Some(id)
                    && let Some(visitor) = self.device.as_ref().and_then(|d| d.visitor(id))
                {
                    app.show_visitor(&visitor);
                }
            }
            Update::Arrived(id) => self.arrived(app, id),
            Update::Left(id) => {
                if self.visiting == Some(id) {
                    app.visitor_left();
                    app.note(Note::info(format!(
                        "It left. /imp {} goes back to your Imp.",
                        self.session.name
                    )));
                }
            }
            Update::Away { imp, device } => {
                if imp == self.session.name && self.visiting.is_none() {
                    app.set_away(Some(device.clone()));
                    app.note(Note::info(format!(
                        "{imp} is on {device} now, with this conversation. It thinks here while this chat is open. /call brings it back."
                    )));
                } else {
                    app.note(Note::info(format!("{imp} is on {device} now.")));
                }
            }
            Update::CameHome { imp, messages } => self.came_home(app, &imp, messages),
            Update::Asked { imp, line } => {
                if imp == self.session.name && self.visiting.is_none() {
                    app.note(Note::info(format!("↳ {line}")));
                }
            }
        }
    }
}

/// What the chat says when it has grown long.
pub fn long_chat_sentence(tokens: usize) -> String {
    format!(
        "This chat is long: about {}k tokens go with each message. /compact sums it up so it costs less, /clear starts over.",
        tokens / 1000
    )
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
