//! `imp chat`: the full-screen chat in a terminal (`crate::tui`), or the line chat for pipes and `--plain`.
//!
//! The line chat writes the answer to standard output as it arrives, and everything else (the prompt, tool
//! calls, notes) to standard error, so `imp chat --plain < questions.txt > answers.txt` keeps only answers.

use super::Io;
use crate::chat_state::ChatState;
use crate::custom;
use crate::link::device::DeviceOptions;
use crate::project;
use crate::session::{Session, SessionOptions};
use crate::settings::Settings;
use crate::slash::{self, Context, Outcome};
use crate::transcript::{CallLine, DetailLine, Kind, argument_lines, call_line, result_line};
use crate::{CliError, Result};
use imp_engine::{
    AgentEvent, OpenAiClient, StreamEvent, ToolHost, ToolSelection, Toolbox, run_agent,
};
use std::io::{IsTerminal, Write};
use std::time::Instant;

pub async fn run(
    settings: &Settings,
    name: Option<&str>,
    plain: bool,
    offline: bool,
    io: &mut Io<'_>,
) -> Result<()> {
    let terminal = std::io::stdin().is_terminal() && std::io::stdout().is_terminal();
    if terminal && !plain {
        let options = DeviceOptions::usual(settings)?;
        return crate::tui::run(settings, name, options, !offline).await;
    }
    let mut session = Session::open(settings, name, SessionOptions::default()).await?;
    let result = plain_chat(&mut session, io).await;
    session.close().await;
    result
}

/// The line chat with an Imp's session: messages, and the `/` commands that work without a screen.
async fn plain_chat(session: &mut Session, io: &mut Io<'_>) -> Result<()> {
    for line in session.warnings.iter().chain(&session.notices) {
        writeln!(io.err, "{line}")?;
    }
    writeln!(
        io.err,
        "Chatting with {} ({}). Type /help for commands, /quit to leave.",
        session.name, session.model
    )?;
    let mut chat = session.new_chat();
    loop {
        write!(io.err, "you> ")?;
        io.err.flush()?;
        let Some(line) = io.line()? else { break };
        if line.trim().is_empty() {
            continue;
        }
        // What another app changed in the files is taken before each line.
        match session.sync().await {
            Ok(Some(said)) => writeln!(io.err, "{said}")?,
            Ok(None) => {}
            Err(e) => writeln!(io.err, "! {e}")?,
        }
        chat.set_system(session.system.clone());
        chat.set_exchanges(session.memory_exchanges);
        let commands = project::custom_commands(&session.loaded);
        let mut model_for_line = None;
        let mut made = None;
        if let Some((command, args)) = custom::find(&line, &commands) {
            let prepared = match custom::prepare(command, args, &session.world()).await {
                Ok(prepared) => prepared,
                Err(e) => {
                    writeln!(io.err, "! {e}")?;
                    continue;
                }
            };
            if prepared.subtask {
                let work = session
                    .one_off(prepared.agent.clone(), prepared.model.clone())
                    .run(&prepared.text)
                    .await;
                match work {
                    Ok(text) => writeln!(io.out, "{text}")?,
                    Err(e) => writeln!(io.err, "! {e}")?,
                }
                continue;
            }
            if let Some(agent) = &prepared.agent
                && !agent.eq_ignore_ascii_case(&session.name)
                && let Err(e) = switch_to(session, &mut chat, agent, io).await
            {
                writeln!(io.err, "! {e}")?;
                continue;
            }
            if let Some(model) = &prepared.model {
                match session.client_for(model) {
                    Ok(over) => model_for_line = Some(over),
                    Err(e) => {
                        writeln!(io.err, "! {e}")?;
                        continue;
                    }
                }
            }
            // What the command made is the message, whatever it starts with.
            made = Some(prepared.text);
        } else if slash::is_command(&line) {
            let history = chat.messages().to_vec();
            let mut no_device = None;
            let mut outcome =
                slash::run(&line, plain_context(session, &mut no_device, &history)).await;
            if let Outcome::Secret {
                prompt,
                line: again,
            } = outcome
            {
                outcome = match super::read_secret(&prompt, io) {
                    Ok(key) => {
                        slash::run_with_secret(
                            &again,
                            plain_context(session, &mut no_device, &history),
                            Some(key),
                        )
                        .await
                    }
                    Err(e) => Outcome::Notes(vec![slash::Note::problem(e.0)]),
                };
            }
            match outcome {
                Outcome::Quit => break,
                Outcome::Clear => {
                    chat.clear();
                    writeln!(io.err, "Starting over.")?;
                }
                Outcome::Compact if chat.memory().is_empty() => {
                    writeln!(io.err, "There is nothing to sum up yet.")?;
                }
                Outcome::Compact => match session.recap(chat.memory()).await {
                    Ok(summary) if chat.recapped(&summary) => {
                        writeln!(io.err, "Summed up the chat:\n{summary}")?;
                    }
                    Ok(_) => writeln!(io.err, "! The summary came back empty.")?,
                    Err(e) => writeln!(io.err, "! {e}")?,
                },
                Outcome::Switch(name) => {
                    if let Err(e) = switch_to(session, &mut chat, &name, io).await {
                        writeln!(io.err, "{e}")?;
                    }
                }
                Outcome::Notes(notes) | Outcome::Sent(notes) => {
                    for note in notes {
                        writeln!(io.err, "{}", note.plain())?;
                    }
                }
                Outcome::Visit(_) | Outcome::CameHome { .. } | Outcome::Secret { .. } => writeln!(
                    io.err,
                    "Devices work in the full-screen chat, or keep `imp link` running."
                )?,
            }
            chat.set_system(session.system.clone());
            chat.set_exchanges(session.memory_exchanges);
            continue;
        }
        let typed = line
            .strip_prefix('/')
            .filter(|l| l.starts_with('/'))
            .unwrap_or(&line);
        // Files named with @ go with a typed message. A custom command's files are already in it.
        let attached = match &made {
            Some(_) => crate::mentions::Attached::default(),
            None => crate::mentions::attach(typed, &session.workspace),
        };
        for problem in &attached.problems {
            writeln!(io.err, "{problem}")?;
        }
        let text = made
            .as_deref()
            .or(attached.content.as_deref())
            .unwrap_or(typed);
        let (client, model) =
            model_for_line.unwrap_or_else(|| (session.client.clone(), session.model.clone()));
        answer(
            &client,
            &model,
            &session.name,
            &mut chat,
            text,
            &*session.toolbox,
            &session.tool_selection(),
            session.max_steps,
            io,
        )
        .await?;
        if let Some(tokens) = chat.long_chat_notice(session.long_chat_tokens) {
            writeln!(io.err, "{}", crate::tui::long_chat_sentence(tokens))?;
        }
    }
    Ok(())
}

/// What a command may look at in the line chat: no devices.
fn plain_context<'a>(
    session: &'a mut Session,
    device: &'a mut Option<crate::link::device::Device>,
    history: &'a [imp_engine::ChatMessage],
) -> Context<'a> {
    Context {
        session,
        device,
        // Nothing listens for devices between lines: they need the full-screen chat.
        device_options: None,
        visiting: None,
        history,
    }
}

/// Talks to another Imp from now on, with a chat of its own.
async fn switch_to(
    session: &mut Session,
    chat: &mut ChatState,
    name: &str,
    io: &mut Io<'_>,
) -> Result<()> {
    let next = Session::open(&session.settings, Some(name), SessionOptions::default()).await?;
    session.close().await;
    *session = next;
    *chat = session.new_chat();
    writeln!(
        io.err,
        "Chatting with {} ({}).",
        session.name, session.model
    )?;
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
    let lang = crate::strings::Lang::detect();
    // While the model thinks: when it started. Its reasoning is not printed, only that it thought.
    let mut thinking: Option<Instant> = None;
    let result = run_agent(
        client,
        model,
        &mut messages,
        host,
        selection,
        max_steps,
        |event| {
            if let AgentEvent::Stream(StreamEvent::Reasoning(_)) = &event {
                if thinking.is_none() {
                    thinking = Some(Instant::now());
                    let word = crate::strings::text(lang, "cli.chat.thinking");
                    let _ = writeln!(err, "  ✻ {word}…");
                }
            } else {
                let _ = write_thought(err, lang, thinking.take());
                show(&event, out, err, chat, name);
            }
            chat.apply_agent(&event);
        },
    )
    .await;
    let _ = write_thought(err, lang, thinking.take());
    if let Err(e) = &result {
        chat.abort_reply();
        writeln!(io.out)?;
        writeln!(io.err, "Something went wrong: {e}")?;
    }
    chat.finish_exchange(result.is_ok());
    Ok::<(), CliError>(())
}

/// The line that stands for a phase of thinking that is over.
fn write_thought(
    err: &mut dyn Write,
    lang: crate::strings::Lang,
    since: Option<Instant>,
) -> std::io::Result<()> {
    let Some(since) = since else {
        return Ok(());
    };
    let seconds = since.elapsed().as_secs_f64().ceil().max(1.0) as u64;
    let line = crate::strings::format(
        lang,
        "cli.chat.thought_for",
        &[("seconds", &seconds.to_string())],
    );
    writeln!(err, "  ✻ {line}")
}

/// What an event of the agent shows in the line chat: the answer on `out`, the rest on `err`.
fn show(
    event: &AgentEvent,
    out: &mut dyn Write,
    err: &mut dyn Write,
    chat: &ChatState,
    name: &str,
) {
    match event {
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
                CallLine::Tool(text) => {
                    // The line names the call; what it was given follows whole, since this chat
                    // cannot open a call later.
                    let _ = writeln!(err, "  ⏺ {name} uses {text}");
                    write_details(err, argument_lines(&call.name, &call.arguments))
                }
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
            } else {
                let mark = if failed { "✕" } else { "⎿" };
                let mut lines = content.lines();
                let first = lines
                    .next()
                    .filter(|_| !content.trim().is_empty())
                    .unwrap_or(&text);
                writeln!(err, "    {mark} {first}").and_then(|()| {
                    write_details(
                        err,
                        lines.map(|l| DetailLine {
                            kind: Kind::Plain,
                            text: l.to_string(),
                        }),
                    )
                })
            };
        }
        _ => {}
    }
}

/// Lines of the details of a call under it, each indented and led by its mark.
fn write_details(
    out: &mut dyn Write,
    lines: impl IntoIterator<Item = DetailLine>,
) -> std::io::Result<()> {
    lines
        .into_iter()
        .try_for_each(|l| writeln!(out, "      {}{}", l.kind.marker(), l.text))
}
