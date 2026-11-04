//! What each command does. Input and output are passed in, so tests can drive them.

use crate::chat_state::ChatState;
use crate::cli::{Cli, Command, ConfigAction, ImpAction};
use crate::config::{
    Config, DEFAULT_PERSONALITY, DEFAULT_URL, ImpConfig, valid_env_name, valid_imp_name,
};
use crate::keys;
use crate::serve::Services;
use crate::troupe::ImpMessageHost;
use crate::{CliError, Result};
use imp_core::{
    AgentEvent, McpHost, McpServerSpec, OpenAiClient, RetryPolicy, StreamEvent, TalkStore,
    ToolHost, ToolSelection, Toolbox, run_agent,
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
            config_command(&path, action.unwrap_or(ConfigAction::Show), io)
        }
        Command::Imp { action } => imp_command(&path, action, io),
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
            light_terminal,
        } => match text {
            Some(text) => {
                write!(io.out, "{}", crate::qr::render(&text, light_terminal)?)?;
                writeln!(io.out)?;
                Ok(())
            }
            None => Err(CliError(crate::qr::NOT_YET.into())),
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

fn config_command(path: &Path, action: ConfigAction, io: &mut Io<'_>) -> Result<()> {
    match action {
        ConfigAction::Path => writeln!(io.out, "{}", path.display())?,
        ConfigAction::Show => show_config(path, io)?,
        ConfigAction::Set { key, value } => {
            let mut config = Config::load(path)?;
            config.set(&key, &value)?;
            config.save(path)?;
            writeln!(io.out, "Saved {key}.")?;
        }
        ConfigAction::SetKey { imp } => {
            let config = Config::load(path)?;
            let (name, _) = config.pick_imp(imp.as_deref())?;
            writeln!(
                io.err,
                "Paste the key and press enter. It goes to the system keychain and is not shown again."
            )?;
            let key = io
                .line()?
                .map(|k| k.trim().to_string())
                .filter(|k| !k.is_empty());
            let key = key.ok_or_else(|| CliError("No key was given.".into()))?;
            keys::save_to_keychain(name, &key)?;
            writeln!(io.out, "Saved the key for {name} in the system keychain.")?;
        }
        ConfigAction::ClearKey { imp } => {
            let config = Config::load(path)?;
            let (name, _) = config.pick_imp(imp.as_deref())?;
            keys::remove_from_keychain(name)?;
            writeln!(
                io.out,
                "Removed the key for {name} from the system keychain."
            )?;
        }
    }
    Ok(())
}

fn show_config(path: &Path, io: &mut Io<'_>) -> Result<()> {
    let config = Config::load(path)?;
    writeln!(
        io.out,
        "Settings file: {}{}",
        path.display(),
        if path.exists() { "" } else { " (not made yet)" }
    )?;
    writeln!(
        io.out,
        "default_imp:   {}",
        config.default_imp.as_deref().unwrap_or("(none)")
    )?;
    writeln!(io.out, "api_key_env:   {}", config.api_key_env)?;
    writeln!(io.out, "retries:       {}", config.retries)?;
    if config.imps.is_empty() {
        writeln!(
            io.out,
            "\nNo Imps yet. Make one with `imp imp new NAME --model MODEL`."
        )?;
        return Ok(());
    }
    writeln!(io.out, "\nAPI keys (the keys themselves are never shown):")?;
    for (name, imp) in &config.imps {
        let var = keys::env_name(&config, imp);
        let status = if keys::real_env(var).is_some_and(|v| !v.trim().is_empty()) {
            format!("found in the environment variable {var}")
        } else {
            format!("{var} is not set, so the system keychain is tried when you chat")
        };
        writeln!(io.out, "  {name}: {status}")?;
    }
    Ok(())
}

fn imp_command(path: &Path, action: ImpAction, io: &mut Io<'_>) -> Result<()> {
    let mut config = Config::load(path)?;
    match action {
        ImpAction::List => {
            if config.imps.is_empty() {
                writeln!(
                    io.out,
                    "No Imps yet. Make one with `imp imp new NAME --model MODEL`."
                )?;
                return Ok(());
            }
            let width = config
                .imps
                .keys()
                .map(String::len)
                .max()
                .unwrap_or(4)
                .max(4);
            let model_width = config
                .imps
                .values()
                .map(|i| i.model.len())
                .max()
                .unwrap_or(5)
                .max(5);
            writeln!(
                io.out,
                "  {:width$}  {:model_width$}  BRAIN",
                "NAME", "MODEL"
            )?;
            for (name, imp) in &config.imps {
                let mark = if config.default_imp.as_deref() == Some(name) {
                    '*'
                } else {
                    ' '
                };
                writeln!(
                    io.out,
                    "{mark} {name:width$}  {:model_width$}  {}",
                    imp.model, imp.base_url
                )?;
            }
        }
        ImpAction::New {
            name,
            personality,
            url,
            model,
            api_key_env,
            default,
        } => {
            let name = match name {
                Some(n) => n,
                None => io
                    .ask("Name", None)?
                    .ok_or_else(|| CliError("A name is needed. Use imp imp new NAME.".into()))?,
            };
            if !valid_imp_name(&name) {
                return Err(CliError(
                    "An Imp's name can have 1 to 32 letters, digits, dashes and underscores."
                        .into(),
                ));
            }
            if config.imps.contains_key(&name) {
                return Err(CliError(format!("There is already an Imp called {name}.")));
            }
            let personality = match personality {
                Some(p) => p,
                None => io
                    .ask("Personality", Some(DEFAULT_PERSONALITY))?
                    .unwrap_or_default(),
            };
            let base_url = match url {
                Some(u) => u,
                None => io
                    .ask(
                        "Brain address (an OpenAI-compatible service)",
                        Some(DEFAULT_URL),
                    )?
                    .unwrap_or_default(),
            };
            if !(base_url.starts_with("http://") || base_url.starts_with("https://")) {
                return Err(CliError(
                    "The brain address must start with http:// or https://.".into(),
                ));
            }
            let model = match model {
                Some(m) => m,
                None => io
                    .ask("Model", None)?
                    .ok_or_else(|| CliError("A model is needed. Use --model NAME.".into()))?,
            };
            if let Some(var) = &api_key_env
                && !valid_env_name(var)
            {
                return Err(CliError(
                    "--api-key-env is the NAME of an environment variable, not the key itself."
                        .into(),
                ));
            }
            let first = config.imps.is_empty();
            config.imps.insert(
                name.clone(),
                ImpConfig {
                    api_key_env,
                    ..ImpConfig::new(personality, base_url, model)
                },
            );
            if default || first {
                config.default_imp = Some(name.clone());
            }
            config.save(path)?;
            writeln!(io.out, "Made {name}.")?;
            let imp = &config.imps[&name];
            writeln!(
                io.out,
                "Give it a key by setting {} or running `imp config set-key --imp {name}`, unless its brain needs none.\nThen chat with `imp chat --imp {name}`.",
                keys::env_name(&config, imp)
            )?;
        }
        ImpAction::Remove { name } => {
            if config.imps.remove(&name).is_none() {
                return Err(CliError(format!("There is no Imp called {name}.")));
            }
            if config.default_imp.as_deref() == Some(name.as_str()) {
                config.default_imp = None;
            }
            config.save(path)?;
            writeln!(io.out, "Removed {name}.")?;
        }
    }
    Ok(())
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
    pub selection: ToolSelection,
    pub max_steps: usize,
    /// Plain sentences about things that did not start, such as an MCP server.
    pub warnings: Vec<String>,
}

/// How long an MCP server may take to start and to answer one request.
const MCP_TIMEOUT: Duration = Duration::from_secs(60);

/// The MCP servers of an Imp as start instructions. Values of the listed environment variables
/// are read now and passed on. They are never stored.
pub fn mcp_specs(imp: &ImpConfig, env: impl Fn(&str) -> Option<String>) -> Vec<McpServerSpec> {
    imp.mcp_servers
        .iter()
        .map(|(name, server)| McpServerSpec {
            name: name.clone(),
            command: server.command.clone(),
            args: server.args.clone(),
            env: server
                .env
                .iter()
                .filter(|n| valid_env_name(n))
                .filter_map(|n| env(n).map(|v| (n.clone(), v)))
                .collect(),
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
        RetryPolicy::new(config.retries, 1.0, 2.0, 20.0),
    )?;
    let mut toolbox = Toolbox::new();
    let (mcp, mut warnings) = McpHost::connect(&mcp_specs(imp, keys::real_env), MCP_TIMEOUT).await;
    toolbox.add(Rc::new(mcp));
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
        selection,
        max_steps: config.max_steps,
        warnings,
    })
}

async fn chat_command(path: &Path, name: Option<&str>, plain: bool, io: &mut Io<'_>) -> Result<()> {
    let session = open_session(path, name).await?;
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
