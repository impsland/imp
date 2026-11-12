//! The real terminal: raw mode, the reader thread and the event loop.

use super::{Action, App};
use crate::commands::Session;
use crate::{CliError, Result};
use imp_core::{AgentEvent, run_agent};
use ratatui::crossterm::event::{
    DisableBracketedPaste, DisableMouseCapture, EnableBracketedPaste, EnableMouseCapture, Event,
};
use ratatui::crossterm::execute;
use std::future::Future;
use std::pin::Pin;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::Duration;

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

/// Runs the full-screen chat until the person leaves.
pub async fn run(session: Session) -> Result<()> {
    let (_guard, mut terminal) = Restore::start()?;
    let stop = Arc::new(AtomicBool::new(false));
    let (key_tx, mut key_rx) = tokio::sync::mpsc::unbounded_channel::<Event>();
    let reader_stop = stop.clone();
    std::thread::spawn(move || read_events(reader_stop, key_tx));
    let result = event_loop(&mut terminal, session, &mut key_rx).await;
    stop.store(true, Ordering::Relaxed);
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

async fn event_loop(
    terminal: &mut ratatui::DefaultTerminal,
    session: Session,
    keys: &mut Events,
) -> Result<()> {
    let mut app = App::new(&session.name, &session.model, &session.system);
    for warning in &session.warnings {
        app.warn(warning);
    }
    let (agent_tx, mut agent_rx) = tokio::sync::mpsc::unbounded_channel::<AgentEvent>();
    let mut running: Option<AgentRun> = None;
    loop {
        terminal
            .draw(|frame| app.render(frame))
            .map_err(|e| CliError(format!("The screen could not be drawn: {e}")))?;
        tokio::select! {
            biased;
            Some(event) = keys.recv() => match handle(&mut app, event) {
                Action::Quit => return Ok(()),
                Action::Send(_) => running = Some(start_agent(&session, &app, &agent_tx)),
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
