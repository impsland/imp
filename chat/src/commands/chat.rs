//! `imp chat`: the full-screen chat in a terminal (`crate::tui`), or the line chat for pipes and `--plain`.
//!
//! The line chat writes the answer to standard output as it arrives, and everything else (the prompt, tool
//! calls, notes) to standard error, so `imp chat --plain < questions.txt > answers.txt` keeps only answers.

use super::Io;
use crate::chat_state::ChatState;
use crate::link::device::DeviceOptions;
use crate::session::{Session, SessionOptions};
use crate::slash::{self, Context, NoteKind, Outcome};
use crate::transcript::{CallLine, call_line, result_line};
use crate::{CliError, Result};
use imp_engine::{
    AgentEvent, OpenAiClient, StreamEvent, ToolHost, ToolSelection, Toolbox, run_agent,
};
use std::io::IsTerminal;
use std::path::Path;

pub async fn run(
    path: &Path,
    name: Option<&str>,
    plain: bool,
    offline: bool,
    io: &mut Io<'_>,
) -> Result<()> {
    let terminal = std::io::stdin().is_terminal() && std::io::stdout().is_terminal();
    if terminal && !plain {
        let mut options = DeviceOptions::usual(path)?;
        options.workspace = Some(std::env::current_dir()?);
        return crate::tui::run(path, name, options, !offline).await;
    }
    let mut session = Session::open(path, name, SessionOptions::default()).await?;
    let result = plain_chat(&mut session, io).await;
    session.close().await;
    result
}

/// The line chat with an Imp's session: messages, and the `/` commands that work without a screen.
async fn plain_chat(session: &mut Session, io: &mut Io<'_>) -> Result<()> {
    for warning in &session.warnings {
        writeln!(io.err, "{warning}")?;
    }
    writeln!(
        io.err,
        "Chatting with {} ({}). Type /help for commands, /quit to leave.",
        session.name, session.model
    )?;
    let mut chat = ChatState::new(session.system.clone());
    loop {
        write!(io.err, "you> ")?;
        io.err.flush()?;
        let Some(line) = io.line()? else { break };
        if line.trim().is_empty() {
            continue;
        }
        if slash::is_command(&line) {
            let history = chat.messages().to_vec();
            let mut no_device = None;
            let outcome = slash::run(
                &line,
                Context {
                    session,
                    device: &mut no_device,
                    // Nothing listens for devices between lines: they need the full-screen chat.
                    device_options: None,
                    visiting: None,
                    history: &history,
                },
            )
            .await;
            match outcome {
                Outcome::Quit => break,
                Outcome::Clear => {
                    chat.clear();
                    writeln!(io.err, "Starting over.")?;
                }
                Outcome::Switch(name) => {
                    let next =
                        Session::open(&session.path, Some(&name), SessionOptions::default()).await;
                    match next {
                        Ok(next) => {
                            session.close().await;
                            *session = next;
                            chat = ChatState::new(session.system.clone());
                            writeln!(
                                io.err,
                                "Chatting with {} ({}).",
                                session.name, session.model
                            )?;
                        }
                        Err(e) => writeln!(io.err, "{e}")?,
                    }
                }
                Outcome::Notes(notes) | Outcome::Sent(notes) => {
                    for note in notes {
                        match note.kind {
                            NoteKind::Code => writeln!(io.err, "{}", note.text)?,
                            NoteKind::Info => writeln!(io.err, "{}", note.text)?,
                            NoteKind::Problem => writeln!(io.err, "! {}", note.text)?,
                        }
                    }
                }
                Outcome::Visit(_) | Outcome::CameHome { .. } => writeln!(
                    io.err,
                    "Devices work in the full-screen chat, or keep `imp link` running."
                )?,
            }
            chat.set_system(session.system.clone());
            continue;
        }
        let text = line
            .strip_prefix('/')
            .filter(|l| l.starts_with('/'))
            .unwrap_or(&line);
        answer(
            &session.client,
            &session.model,
            &session.name,
            &mut chat,
            text,
            &*session.toolbox,
            &session.selection,
            session.max_steps,
            io,
        )
        .await?;
    }
    Ok(())
}

/// The line-based chat without tools: one line in, one streamed reply out.
pub async fn chat_loop(
    client: &OpenAiClient,
    model: &str,
    name: &str,
    chat: ChatState,
    io: &mut Io<'_>,
) -> Result<()> {
    chat_loop_with(
        client,
        model,
        name,
        chat,
        &Toolbox::new(),
        &ToolSelection::all(),
        10,
        io,
    )
    .await
}

/// The line-based chat: one line in, one streamed reply out, with tools run as the Imp asks. Only `/quit`
/// and `/clear` are known here: the settings commands need a session.
#[allow(clippy::too_many_arguments)]
pub async fn chat_loop_with(
    client: &OpenAiClient,
    model: &str,
    name: &str,
    mut chat: ChatState,
    host: &dyn ToolHost,
    selection: &ToolSelection,
    max_steps: usize,
    io: &mut Io<'_>,
) -> Result<()> {
    writeln!(
        io.err,
        "Chatting with {name} ({model}). Type /quit to leave and /clear to start over."
    )?;
    loop {
        write!(io.err, "you> ")?;
        io.err.flush()?;
        let Some(line) = io.line()? else { break };
        match line.trim() {
            "" => continue,
            "/quit" | "/exit" => break,
            "/clear" => {
                chat.clear();
                writeln!(io.err, "Starting over.")?;
                continue;
            }
            _ => {}
        }
        answer(
            client, model, name, &mut chat, &line, host, selection, max_steps, io,
        )
        .await?;
    }
    Ok(())
}

/// Sends one message and writes the answer as it streams. Tool calls and messages to other Imps get a line
/// each on standard error.
#[allow(clippy::too_many_arguments)]
async fn answer(
    client: &OpenAiClient,
    model: &str,
    name: &str,
    chat: &mut ChatState,
    line: &str,
    host: &dyn ToolHost,
    selection: &ToolSelection,
    max_steps: usize,
    io: &mut Io<'_>,
) -> Result<()> {
    if !chat.push_user(line) {
        return Ok(());
    }
    let mut messages = chat.request_messages();
    let (out, err) = (&mut *io.out, &mut *io.err);
    let result = run_agent(
        client,
        model,
        &mut messages,
        host,
        selection,
        max_steps,
        |event| {
            match &event {
                AgentEvent::Stream(StreamEvent::Text(text)) => {
                    let _ = write!(out, "{text}");
                    let _ = out.flush();
                }
                AgentEvent::StepEnd if !chat.streaming_text().is_empty() => {
                    let _ = writeln!(out);
                }
                AgentEvent::Retry(notice) => {
                    let _ = writeln!(err, "  {}", notice.text());
                }
                AgentEvent::ToolStart(call) => {
                    let _ = match call_line(&call.name, &call.arguments) {
                        CallLine::Tool(text) => writeln!(err, "  ⏺ {name} uses {text}"),
                        CallLine::Message { to, text } => {
                            writeln!(err, "  ⇢ {name} asks {to}: {text}")
                        }
                    };
                }
                AgentEvent::ToolResult {
                    name: tool,
                    content,
                    ..
                } => {
                    let (text, failed) = result_line(content);
                    let _ = if tool == crate::troupe::TOOL_NAME {
                        writeln!(err, "  ⇠ {text}")
                    } else if failed {
                        writeln!(err, "    ✕ {text}")
                    } else {
                        writeln!(err, "    ⎿ {text}")
                    };
                }
                _ => {}
            }
            chat.apply_agent(&event);
        },
    )
    .await;
    if let Err(e) = result {
        chat.abort_reply();
        writeln!(io.out)?;
        writeln!(io.err, "Something went wrong: {e}")?;
    }
    Ok::<(), CliError>(())
}
