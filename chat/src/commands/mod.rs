//! What each command does. Input and output are passed in, so tests can drive them.
//!
//! `config_cmd` is `imp config`, `imps` is `imp imp`, `mcp_cmd` is `imp mcp`, `chat` is `imp chat` (the
//! line chat is in it, the full-screen one in `crate::tui`), `serve` is `imp serve`. `imp qr` and
//! `imp link` are in `crate::qr`.

mod chat;
mod config_cmd;
mod imps;
mod mcp_cmd;
mod serve;

use crate::cli::{Cli, Command, ConfigAction};
use crate::config::Config;
use crate::link::SeedFile;
use crate::link::device::{Device, DeviceOptions};
use crate::serve::Services;
use crate::{CliError, Result};
use std::io::{BufRead, Write};
use std::path::PathBuf;
use std::sync::Arc;

pub use crate::session::{Session, mcp_specs, system_prompt, talks_dir};
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

    fn ask(&mut self, label: &str, default: Option<&str>) -> Result<Option<String>> {
        match default {
            Some(d) => write!(self.err, "{label} [{d}]: ")?,
            None => write!(self.err, "{label}: ")?,
        }
        self.err.flush()?;
        let answer = self
            .line()?
            .map(|a| a.trim().to_string())
            .filter(|a| !a.is_empty());
        Ok(answer.or_else(|| default.map(str::to_string)))
    }
}

pub async fn run(cli: Cli, io: &mut Io<'_>) -> Result<()> {
    let path = match cli.config {
        Some(p) => p,
        None => Config::default_path()?,
    };
    // No command at all is the same as `imp chat`: the chat opens at once with the default Imp.
    let command = cli.command.unwrap_or(Command::Chat {
        imp: None,
        plain: false,
        offline: false,
    });
    match command {
        Command::Config { action } => {
            config_cmd::run(&path, action.unwrap_or(ConfigAction::Show), io)
        }
        Command::Imp { action } => imps::run(&path, action, io),
        Command::Mcp { action } => mcp_cmd::run(&path, action, io),
        Command::Chat {
            imp,
            plain,
            offline,
        } => chat::run(&path, imp.as_deref(), plain, offline, io).await,
        Command::Serve {
            den_only,
            hop_only,
            host,
            den_port,
            hop_port,
            public_url,
            data_dir,
        } => {
            let services = match (den_only, hop_only) {
                (true, _) => Services::DenOnly,
                (_, true) => Services::HopOnly,
                _ => Services::Both,
            };
            let data_dir = match data_dir {
                Some(dir) => dir,
                None if services.den() => crate::serve::default_data_dir()?,
                None => PathBuf::new(),
            };
            let options = crate::serve::ServeOptions {
                services,
                data_dir,
                host,
                den_port,
                hop_port,
                public_url,
            };
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
                let options = device_options(&path, name, hosts, hop, data_dir)?;
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
            let options = device_options(&path, name, Vec::new(), hop, data_dir)?;
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

async fn ctrl_c() {
    let _ = tokio::signal::ctrl_c().await;
}

fn device_options(
    config: &std::path::Path,
    name: Option<String>,
    hosts: Vec<String>,
    hop: Option<String>,
    data_dir: Option<PathBuf>,
) -> Result<DeviceOptions> {
    Ok(DeviceOptions {
        name,
        hosts,
        hop,
        data_dir: match data_dir {
            Some(dir) => dir,
            None => crate::session::data_dir()?,
        },
        config: config.to_path_buf(),
        workspace: None,
    })
}
