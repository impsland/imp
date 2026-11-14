//! What each command does. Input and output are passed in, so tests can drive them.
//!
//! `config_cmd` is `imp config` and `imps` is `imp imp`. The chat, the serve command and the pairing are here.

mod config_cmd;
mod imps;

use crate::chat_state::ChatState;
use crate::cli::{Cli, Command, ConfigAction};
use crate::config::{Config, ImpConfig, valid_env_name};
use crate::keys;
use crate::serve::Services;
use crate::troupe::ImpMessageHost;
use crate::{CliError, Result};
use imp_core::{
    AgentEvent, McpEndpoint, McpHost, McpServerSpec, OpenAiClient, RequestLimits, StreamEvent,
    TalkStore, ToolHost, ToolSelection, Toolbox, run_agent,
};
use std::io::{BufRead, IsTerminal, Write};
use std::path::{Path, PathBuf};
use std::rc::Rc;
use std::time::Duration;

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
    match cli.command {
        Command::Config { action } => {
            config_cmd::run(&path, action.unwrap_or(ConfigAction::Show), io)
        }
        Command::Imp { action } => imps::run(&path, action, io),
        Command::Chat { imp, plain } => chat_command(&path, imp.as_deref(), plain, io).await,
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
            serve_command(&options, io).await
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
                let options = crate::qr::PairOptions {
                    name,
                    hosts,
                    hop,
                    data_dir: match data_dir {
                        Some(dir) => dir,
                        None => crate::serve::default_data_dir()?,
                    },
                };
                let stop = async {
                    let _ = tokio::signal::ctrl_c().await;
                };
                crate::qr::pair(
                    &options,
                    std::sync::Arc::new(crate::link::SystemSeedStore),
                    io.out,
                    io.err,
                    stop,
                )
                .await
            }
        },
    }
}

async fn serve_command(options: &crate::serve::ServeOptions, io: &mut Io<'_>) -> Result<()> {
    let bound = crate::serve::bind(options).await?;
    if let (Some(addr), Some(url)) = (bound.den_addr, &bound.public_url) {
        writeln!(io.err, "The Den is listening on {addr}")?;
        writeln!(
            io.err,
            "  Its data is kept in {}. The secret stays in the file den-secret there.",
            options.data_dir.display()
        )?;
        writeln!(io.err, "  Its public address is {url}")?;
    }
    if let Some(addr) = bound.hop_addr {
        writeln!(io.err, "The Hop is listening on {addr}")?;
        writeln!(io.err, "  It keeps no data and does not need The Den.")?;
    }
    writeln!(
        io.err,
        "\nTo use it, open the Imp settings on a Mac or the Imp app on an iPhone and set:"
    )?;
    if let Some(url) = &bound.public_url {
        writeln!(io.err, "  Server  {url}")?;
    }
    if bound.hop_addr.is_some() {
        writeln!(io.err, "  Hop     {}", hop_name(options, &bound))?;
    }
    if options.host.is_loopback() {
        writeln!(
            io.err,
            "Only this computer can reach it. Use --host 0.0.0.0 to let devices on your network in."
        )?;
    }
    writeln!(io.err, "Press Ctrl-C to stop.")?;
    bound
        .run(async {
            let _ = tokio::signal::ctrl_c().await;
        })
        .await?;
    writeln!(io.err, "Stopped.")?;
    Ok(())
}

fn hop_name(options: &crate::serve::ServeOptions, bound: &crate::serve::Bound) -> String {
    let name = match options.host {
        std::net::IpAddr::V4(a) if a.is_loopback() || a.is_unspecified() => "localhost".to_owned(),
        std::net::IpAddr::V4(a) => a.to_string(),
        std::net::IpAddr::V6(a) => format!("[{a}]"),
    };
    let port = bound.hop_addr.map_or(0, |a| a.port());
    format!("{name}:{port}")
}

/// What the model is told it is.
pub fn system_prompt(name: &str, imp: &ImpConfig) -> String {
    format!(
        "You are {name}, an Imp: a small character that lives on the person's computer and chats with them. {}",
        imp.personality
    )
}

/// Everything a chat needs, ready to use: the Imp, its model client and its tools.
pub struct Session {
    pub name: String,
    pub model: String,
    pub client: Rc<OpenAiClient>,
    pub system: String,
    pub toolbox: Rc<Toolbox>,
    /// The MCP servers behind the toolbox, to end their sessions when the chat ends.
    pub mcp: Rc<McpHost>,
    pub selection: ToolSelection,
    pub max_steps: usize,
    /// Plain sentences about things that did not start, such as an MCP server.
    pub warnings: Vec<String>,
}

/// How long an MCP server may take to start and to answer one request.
const MCP_TIMEOUT: Duration = Duration::from_secs(60);

/// The MCP servers of an Imp as ways to reach them. Values of the listed environment variables
/// and headers are read now and passed on. They are never stored. A header's value comes from the
/// environment variable named by `keys::header_env`, or else from the key store.
pub fn mcp_specs(
    imp: &ImpConfig,
    env: impl Fn(&str) -> Option<String>,
    keychain: impl Fn(&str) -> Option<String>,
) -> Vec<McpServerSpec> {
    imp.mcp_servers
        .iter()
        .filter_map(|(name, server)| {
            let endpoint = if let Some(url) = &server.url {
                McpEndpoint::Http {
                    url: url.clone(),
                    headers: server
                        .headers
                        .iter()
                        .filter_map(|header| {
                            env(&keys::header_env(name, header))
                                .filter(|v| !v.trim().is_empty())
                                .or_else(|| keychain(&keys::header_account(name, header)))
                                .map(|v| (header.clone(), v.trim().to_string()))
                        })
                        .collect::<Vec<_>>()
                        .into(),
                }
            } else {
                McpEndpoint::Command {
                    command: server.command.clone()?,
                    args: server.args.clone(),
                    env: server
                        .env
                        .iter()
                        .filter(|n| valid_env_name(n))
                        .filter_map(|n| env(n).map(|v| (n.clone(), v)))
                        .collect::<Vec<_>>()
                        .into(),
                }
            };
            Some(McpServerSpec {
                name: name.clone(),
                endpoint,
            })
        })
        .collect()
}

/// The folder for the conversations between Imps. `IMP_DATA_DIR` overrides the usual place.
pub fn talks_dir() -> Result<PathBuf> {
    if let Some(dir) = keys::real_env("IMP_DATA_DIR").filter(|d| !d.trim().is_empty()) {
        return Ok(PathBuf::from(dir).join("talks"));
    }
    directories::ProjectDirs::from("", "", "imp")
        .map(|d| d.data_dir().join("talks"))
        .ok_or_else(|| CliError("Could not find a folder for data. Set IMP_DATA_DIR.".into()))
}

pub async fn open_session(path: &Path, name: Option<&str>) -> Result<Session> {
    let config = Config::load(path)?;
    let (name, imp) = config.pick_imp(name)?;
    let client = OpenAiClient::new(
        &imp.base_url,
        keys::find(&config, name, imp, keys::real_env, keys::real_keychain).map(|k| k.key),
        RequestLimits {
            retries: i64::from(config.retries),
            ..RequestLimits::default()
        }
        .policy(),
    )?;
    let mut toolbox = Toolbox::new();
    let (mcp, mut warnings) = McpHost::connect(
        &mcp_specs(imp, keys::real_env, keys::real_keychain),
        MCP_TIMEOUT,
    )
    .await;
    let mcp = Rc::new(mcp);
    toolbox.add(mcp.clone());
    if config.imps.len() > 1 {
        match talks_dir() {
            Ok(dir) => {
                let global = config.clone();
                toolbox.add(Rc::new(ImpMessageHost::new(
                    name,
                    config.clone(),
                    TalkStore::new(dir),
                    Box::new(move |n, i| {
                        keys::find(&global, n, i, keys::real_env, keys::real_keychain)
                            .map(|k| k.key)
                    }),
                )));
            }
            Err(e) => warnings.push(format!("Messaging other Imps is off. {e}")),
        }
    }
    let selection = ToolSelection {
        tools_off: imp.tools_off.iter().cloned().collect(),
        ..ToolSelection::all()
    };
    Ok(Session {
        name: name.to_string(),
        model: imp.model.clone(),
        client: Rc::new(client),
        system: system_prompt(name, imp),
        toolbox: Rc::new(toolbox),
        mcp,
        selection,
        max_steps: config.max_steps,
        warnings,
    })
}

async fn chat_command(path: &Path, name: Option<&str>, plain: bool, io: &mut Io<'_>) -> Result<()> {
    let session = open_session(path, name).await?;
    let mcp = session.mcp.clone();
    let result = run_chat(session, plain, io).await;
    mcp.close().await;
    result
}

async fn run_chat(session: Session, plain: bool, io: &mut Io<'_>) -> Result<()> {
    let terminal = std::io::stdin().is_terminal() && std::io::stdout().is_terminal();
    if terminal && !plain {
        return crate::tui::run(session).await;
    }
    for warning in &session.warnings {
        writeln!(io.err, "{warning}")?;
    }
    chat_loop_with(
        &session.client,
        &session.model,
        &session.name,
        ChatState::new(session.system.clone()),
        &*session.toolbox,
        &session.selection,
        session.max_steps,
        io,
    )
    .await
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

/// The line-based chat: one line in, one streamed reply out, with tools run as the Imp asks.
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
        chat.push_user(&line);
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
                        let _ = writeln!(err, "{}", notice.text());
                    }
                    AgentEvent::ToolStart(call) => {
                        let _ = writeln!(err, "({name} uses the tool {})", call.name);
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
    }
    Ok(())
}
