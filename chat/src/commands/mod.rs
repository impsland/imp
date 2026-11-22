//! What each command does. Input and output are passed in, so tests can drive them.
//!
//! `manage` is every command that changes or shows the configuration (`imp agent`, `imp provider`, ...): one
//! function per action, answering with a `reply::Reply` that the terminal prints and a chat can show.
//! `chat` is `imp chat` (the line chat is in it, the full-screen one in `crate::tui`), `serve` is
//! `imp serve`. `imp qr` and `imp link` are in `crate::qr`.

mod chat;
pub mod manage;
pub mod reply;
mod serve;

use crate::cli::{Cli, Command};
use crate::link::SeedFile;
use crate::link::device::{Device, DeviceOptions};
use crate::settings::Settings;
use crate::{CliError, Result};
use std::io::{BufRead, IsTerminal, Write};
use std::path::PathBuf;
use std::sync::Arc;

pub use crate::session::{Session, mcp_specs};
pub use chat::{chat_loop, chat_loop_with};

/// Where a command reads and writes. Replies go to `out`, notes and prompts to `err`.
pub struct Io<'a> {
    pub input: &'a mut dyn BufRead,
    pub out: &'a mut dyn Write,
    pub err: &'a mut dyn Write,
}

impl Io<'_> {
    fn line(&mut self) -> Result<Option<String>> {
        let mut line = String::new();
        let read = self.input.read_line(&mut line)?;
        Ok((read > 0).then(|| line.trim_end_matches(['\n', '\r']).to_string()))
    }
}

pub async fn run(cli: Cli, io: &mut Io<'_>) -> Result<()> {
    let settings = Settings::here()?;
    run_with(cli, &settings, io).await
}

/// [`run`] with the configuration given: tests and other callers that know better.
pub async fn run_with(cli: Cli, settings: &Settings, io: &mut Io<'_>) -> Result<()> {
    // No command at all is the same as `imp chat`.
    let command = cli.command.unwrap_or(Command::Chat {
        imp: None,
        plain: false,
        offline: false,
    });
    match command {
        Command::Manage(manage) => {
            let mut secret = |label: &str| read_secret(label, io);
            let reply = manage::run(settings, manage, &mut secret)?;
            writeln!(io.out, "{}", reply.render(cli.json))?;
            Ok(())
        }
        Command::Chat {
            imp,
            plain,
            offline,
        } => chat::run(settings, imp.as_deref(), plain, offline, io).await,
        Command::Serve { host, hop_port } => {
            let options = crate::serve::ServeOptions { host, hop_port };
            serve::run(&options, io).await
        }
        Command::Qr {
            text,
            name,
            hosts,
            hop,
            data_dir,
        } => match text {
            Some(text) => {
                write!(io.out, "{}", crate::qr::render(&text)?)?;
                writeln!(io.out)?;
                Ok(())
            }
            None => {
                let options = device_options(settings, name, hosts, hop, data_dir)?;
                crate::qr::pair(
                    &options,
                    Arc::new(SeedFile::moving_from_keychain(&options.data_dir)),
                    io.out,
                    io.err,
                    ctrl_c(),
                )
                .await
            }
        },
        Command::Link {
            name,
            hop,
            data_dir,
        } => {
            let options = device_options(settings, name, Vec::new(), hop, data_dir)?;
            if !options.has_book() {
                return Err(CliError(
                    "This computer is not linked with any device yet. Run `imp qr` and scan the code with Imp on a Mac or an iPhone.".into(),
                ));
            }
            let device = Device::start(
                &options,
                Arc::new(SeedFile::moving_from_keychain(&options.data_dir)),
            )
            .await
            .map_err(|e| CliError(e.to_string()))?;
            writeln!(
                io.err,
                "{} is online for your linked devices.",
                device.name()
            )?;
            for peer in device.peers() {
                writeln!(io.err, "  {}", peer.name)?;
            }
            crate::qr::stay_online(device, io.err, ctrl_c(), false).await
        }
    }
}

/// A secret from the person: typed without being shown in a terminal, else the first line of the input.
fn read_secret(label: &str, io: &mut Io<'_>) -> Result<String> {
    use ratatui::crossterm::event::{Event, KeyCode, KeyEventKind, KeyModifiers, read};
    use ratatui::crossterm::terminal::{disable_raw_mode, enable_raw_mode};
    if !std::io::stdin().is_terminal() {
        return Ok(io.line()?.unwrap_or_default().trim().to_string());
    }
    write!(io.err, "{label} (not shown): ")?;
    io.err.flush()?;
    enable_raw_mode()?;
    let mut typed = String::new();
    let outcome = loop {
        match read() {
            Ok(Event::Key(key)) if key.kind != KeyEventKind::Release => match key.code {
                KeyCode::Enter => break Ok(()),
                KeyCode::Backspace => {
                    typed.pop();
                }
                KeyCode::Char('c') if key.modifiers.contains(KeyModifiers::CONTROL) => {
                    break Err(CliError("Cancelled. Nothing was saved.".into()));
                }
                KeyCode::Char(c) => typed.push(c),
                _ => {}
            },
            Ok(_) => {}
            Err(e) => break Err(CliError::from(e)),
        }
    };
    let _ = disable_raw_mode();
    writeln!(io.err)?;
    outcome.map(|()| typed.trim().to_string())
}

async fn ctrl_c() {
    let _ = tokio::signal::ctrl_c().await;
}

fn device_options(
    settings: &Settings,
    name: Option<String>,
    hosts: Vec<String>,
    hop: Option<String>,
    data_dir: Option<PathBuf>,
) -> Result<DeviceOptions> {
    let mut options = DeviceOptions::usual(settings)?;
    options.name = name;
    options.hosts = hosts;
    options.hop = hop;
    if let Some(dir) = data_dir {
        options.data_dir = dir;
    }
    Ok(options)
}
