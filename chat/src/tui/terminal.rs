//! The real terminal: raw mode, the reader thread and the event loop. The loop owns the session (the Imp on
//! screen), this computer on the link once it is started, and the answer that is arriving. It waits for
//! keys, the answer and the link at once, so a phone can talk to an Imp here while the chat is open.

use super::{Action, App};
use crate::chat_state::ChatState;
use crate::link::SeedFile;
use crate::link::device::{Device, DeviceOptions, StartError, Update};
use crate::session::{Session, SessionOptions};
use crate::slash::{self, Context, Note, Outcome};
use crate::{CliError, Result};
use imp_engine::{AgentEvent, run_agent};
use ratatui::crossterm::event::{
    DisableBracketedPaste, DisableMouseCapture, EnableBracketedPaste, EnableMouseCapture, Event,
};
use ratatui::crossterm::execute;
use std::future::Future;
use std::path::Path;
use std::pin::Pin;
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
        Event::Mouse(mouse) => {
            app.on_mouse(mouse);
            Action::None
        }
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
        let folder = self.session.workspace.display().to_string();
        let mut app = App::new(
            &self.session.name,
            &self.session.model,
            &self.session.system,
        )
        .in_folder(&folder);
        for warning in &self.session.warnings {
            app.note(Note::problem(warning.clone()));
        }
        if let Some(note) = device_note {
            app.note(Note::info(note));
        }
        self.note_away(&mut app);
        let (agent_tx, mut agent_rx) = tokio::sync::mpsc::unbounded_channel::<AgentEvent>();
        let mut running: Option<AgentRun> = None;
        // Redraws once a second while an answer arrives, so the seconds in the status line move.
        let mut tick = tokio::time::interval(Duration::from_secs(1));
        loop {
            terminal
                .draw(|frame| app.render(frame))
                .map_err(|e| CliError(format!("The screen could not be drawn: {e}")))?;
            tokio::select! {
                biased;
                Some(event) = keys.recv() => match handle(&mut app, event) {
                    Action::Quit => return Ok(()),
                    Action::Send(text) => match self.visiting {
                        Some(visitor) => {
                            let asked = match &self.device {
                                Some(d) => d.ask_visitor(visitor, &text).await,
                                None => Err(CliError("The link stopped.".into())),
                            };
                            if let Err(e) = asked {
                                app.on_done(Err(e.0));
                            }
                        }
                        None => running = Some(start_agent(&self.session, &app, &agent_tx)),
                    },
                    Action::Stop => {
                        if running.take().is_some() {
                            while let Ok(event) = agent_rx.try_recv() {
                                app.on_agent(&event);
                            }
                            app.on_done(Ok(()));
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
                }
                update = next_update(&mut self.device) => self.on_update(&mut app, update),
                _ = tick.tick(), if app.is_waiting() => {}
            }
        }
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
                }
            }
            Outcome::Sent(notes) => app.notes_from(notes),
            Outcome::Switch(name) => self.switch(app, &name).await,
            Outcome::Visit(id) => {
                let visitor = self.device.as_ref().and_then(|d| d.visitor(id));
                if let Some(visitor) = visitor {
                    if self.visiting.is_none() {
                        self.stash = Some(std::mem::take(&mut app.chat));
                    }
                    self.visiting = Some(id);
                    app.show_visitor(&visitor);
                    app.note(Note::info(format!(
                        "{} is visiting from {}: it thinks there, and what you say goes there. /return sends it back, /imp {} comes back here.",
                        visitor.look.name, visitor.home_name, self.session.name
                    )));
                }
            }
            Outcome::CameHome { imp, messages } => self.came_home(app, &imp, messages),
        }
        false
    }

    /// Talk to another Imp of this computer.
    async fn switch(&mut self, app: &mut App, name: &str) {
        if name == self.session.name {
            if self.visiting.take().is_none() {
                app.note(Note::info(format!("This is {name} already.")));
                return;
            }
            let chat = self
                .stash
                .take()
                .unwrap_or_else(|| ChatState::new(self.session.system.clone()));
            app.switch(&self.session.name, &self.session.model, chat);
            self.note_away(app);
            return;
        }
        let options = SessionOptions {
            workspace: Some(self.session.workspace.clone()),
            remote: self.device.as_ref().map(Device::remote),
        };
        match Session::open(&self.session.path, Some(name), options).await {
            Ok(next) => {
                let old = std::mem::replace(&mut self.session, next);
                old.close().await;
                self.visiting = None;
                self.stash = None;
                let chat = ChatState::new(self.session.system.clone());
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
            let mut chat = ChatState::from_messages(self.session.system.clone(), messages);
            // What was said here before it left is kept when it says nothing new.
            if chat.messages().is_empty() {
                chat = ChatState::from_messages(
                    self.session.system.clone(),
                    app.chat.messages().to_vec(),
                );
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
