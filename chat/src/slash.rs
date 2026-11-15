//! The commands typed in a chat after a `/`: `/model`, `/mcp add`, `/send` and the rest. The full-screen chat
//! and the line chat both use them, so they say the same things. Every change is saved to the settings file
//! and takes effect for the next message. A key is never shown or saved to the settings file.

use crate::config::{McpServerConfig, valid_header_name};
use crate::keys;
use crate::link::device::{Device, DeviceOptions, Update};
use crate::link::{SeedFile, device::reach_note};
use crate::session::{Session, describe_server};
use crate::{CliError, Result};
use imp_engine::ChatMessage;
use std::sync::Arc;
use uuid::Uuid;

/// One command, for `/help` and for completing what is typed.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Command {
    pub name: &'static str,
    pub usage: &'static str,
    pub about: &'static str,
}

const fn cmd(name: &'static str, usage: &'static str, about: &'static str) -> Command {
    Command { name, usage, about }
}

/// Every command, in the order `/help` lists them.
pub const COMMANDS: &[Command] = &[
    cmd("/help", "/help", "List these commands"),
    cmd("/clear", "/clear", "Start the conversation over"),
    cmd("/quit", "/quit", "Leave the chat (also /exit, Esc)"),
    cmd("/model", "/model [NAME]", "Show or change the model"),
    cmd(
        "/base_url",
        "/base_url [URL]",
        "Show or change the service address (OpenAI-compatible)",
    ),
    cmd(
        "/api_key",
        "/api_key [KEY | save KEY | forget]",
        "Use a key for this chat, keep it in the keychain, or remove it",
    ),
    cmd(
        "/api_key_env",
        "/api_key_env [NAME]",
        "Read this Imp's key from another environment variable",
    ),
    cmd(
        "/personality",
        "/personality [TEXT]",
        "Show or change how the Imp behaves",
    ),
    cmd(
        "/imp",
        "/imp [NAME]",
        "List the Imps, or talk to another one",
    ),
    cmd(
        "/mcp",
        "/mcp [add NAME COMMAND [ARGS...] | add NAME URL | remove NAME | reload]",
        "List, add or remove MCP servers",
    ),
    cmd(
        "/tools",
        "/tools [on | off ID]",
        "List the tools, or switch one on or off",
    ),
    cmd("/settings", "/settings", "Show the Imp's settings"),
    cmd(
        "/devices",
        "/devices",
        "List linked devices, the Imps on them and the visitors here",
    ),
    cmd("/pair", "/pair", "Show a code to link a Mac or an iPhone"),
    cmd(
        "/send",
        "/send DEVICE [IMP]",
        "Send this Imp (or another) to a linked device",
    ),
    cmd(
        "/call",
        "/call [IMP]",
        "Bring an Imp back from another device",
    ),
    cmd(
        "/return",
        "/return [VISITOR]",
        "Send a visiting Imp back to its home",
    ),
    cmd(
        "/trust",
        "/trust DEVICE [off]",
        "Let Imps use their tools for a device of yours",
    ),
    cmd("/forget", "/forget DEVICE", "End the link with a device"),
];

/// The commands whose name starts with what was typed, for completion.
pub fn matching(typed: &str) -> Vec<&'static Command> {
    let word = typed.split_whitespace().next().unwrap_or(typed);
    if !word.starts_with('/') || typed.contains(' ') {
        return Vec::new();
    }
    COMMANDS
        .iter()
        .filter(|c| c.name.starts_with(word) || alias(word).is_some_and(|a| a == c.name))
        .collect()
}

/// The commands for a name being typed, best first: those that start with it, then those that
/// contain it, then those with its letters in order. Equal matches keep the order of `COMMANDS`.
pub fn suggest(typed: &str) -> Vec<&'static Command> {
    if !typed.starts_with('/') || typed.contains(char::is_whitespace) {
        return Vec::new();
    }
    let word = typed.to_lowercase();
    let wanted = word.trim_start_matches('/');
    let mut ranked: Vec<(u8, usize, &'static Command)> = Vec::new();
    for (i, c) in COMMANDS.iter().enumerate() {
        let name = c.name.trim_start_matches('/');
        let rank = if name.starts_with(wanted) || alias(&word).is_some_and(|a| a == c.name) {
            0
        } else if name.contains(wanted) {
            1
        } else if in_order(name, wanted) {
            2
        } else {
            continue;
        };
        ranked.push((rank, i, c));
    }
    ranked.sort_by_key(|(rank, i, _)| (*rank, *i));
    ranked.into_iter().map(|(_, _, c)| c).collect()
}

/// Whether the letters of `wanted` all appear in `name`, in that order.
fn in_order(name: &str, wanted: &str) -> bool {
    let mut letters = name.chars();
    wanted.chars().all(|w| letters.any(|n| n == w))
}

/// The command a word names, by its own name or by an alias.
pub fn find(word: &str) -> Option<&'static Command> {
    let word = alias(word).unwrap_or(word);
    COMMANDS.iter().find(|c| c.name == word)
}

/// Whether the command cannot run without something after its name (`/send DEVICE`).
pub fn needs_args(c: &Command) -> bool {
    let rest = c.usage.get(c.name.len()..).unwrap_or("").trim_start();
    !rest.is_empty() && !rest.starts_with('[')
}

/// Whether the command takes anything after its name at all.
pub fn takes_args(c: &Command) -> bool {
    c.usage.len() > c.name.len()
}

/// One word that can follow a command, such as `save` after `/api_key`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Choice {
    pub word: &'static str,
    pub about: &'static str,
    /// Something more is expected after it.
    pub more: bool,
}

const fn choice(word: &'static str, about: &'static str, more: bool) -> Choice {
    Choice { word, about, more }
}

/// The words that can follow a command, when there is a small fixed set of them.
pub fn choices(command: &str) -> &'static [Choice] {
    const API_KEY: &[Choice] = &[
        choice("save", "Use the key and keep it in the keychain", true),
        choice("forget", "Remove the saved key", false),
    ];
    const MCP: &[Choice] = &[
        choice("add", "Add an MCP server", true),
        choice("remove", "Remove an MCP server", true),
        choice("reload", "Start the servers again", false),
    ];
    const TOOLS: &[Choice] = &[
        choice("on", "Switch a tool on", true),
        choice("off", "Switch a tool off", true),
    ];
    match command {
        "/api_key" => API_KEY,
        "/mcp" => MCP,
        "/tools" => TOOLS,
        _ => &[],
    }
}

fn alias(word: &str) -> Option<&'static str> {
    Some(match word {
        "/exit" | "/q" => "/quit",
        "/new" | "/reset" => "/clear",
        "/url" | "/baseurl" | "/base-url" => "/base_url",
        "/key" | "/apikey" | "/api-key" => "/api_key",
        "/imps" => "/imp",
        "/?" => "/help",
        "/config" => "/settings",
        "/link" | "/qr" => "/pair",
        "/visitors" | "/peers" => "/devices",
        _ => return None,
    })
}

/// A line the chat shows for a command. Not part of the conversation.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Note {
    pub kind: NoteKind,
    pub text: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum NoteKind {
    Info,
    Problem,
    /// A row of a QR code: drawn black on white, as it is.
    Code,
}

impl Note {
    pub fn info(text: impl Into<String>) -> Self {
        Self {
            kind: NoteKind::Info,
            text: text.into(),
        }
    }

    pub fn problem(text: impl Into<String>) -> Self {
        Self {
            kind: NoteKind::Problem,
            text: text.into(),
        }
    }
}

/// What the chat does after a command.
#[derive(Debug, Clone, PartialEq)]
pub enum Outcome {
    /// Show these lines.
    Notes(Vec<Note>),
    Quit,
    /// Start the conversation over.
    Clear,
    /// Talk to this Imp of the computer instead.
    Switch(String),
    /// Talk to this visiting Imp.
    Visit(Uuid),
    /// The Imp came back with this conversation (it replaces the one on screen if it is the same Imp).
    CameHome {
        imp: String,
        messages: Vec<ChatMessage>,
    },
    /// The Imp on screen was sent away: it shows the notes and waits for it to land.
    Sent(Vec<Note>),
}

impl Outcome {
    fn say(text: impl Into<String>) -> Self {
        Self::Notes(vec![Note::info(text)])
    }
}

/// Everything a command may look at or change.
pub struct Context<'a> {
    pub session: &'a mut Session,
    /// This computer on the link, once it is started.
    pub device: &'a mut Option<Device>,
    /// How to start it. None where nothing could listen for devices (the line chat).
    pub device_options: Option<&'a DeviceOptions>,
    /// The visiting Imp on screen, if it is one.
    pub visiting: Option<Uuid>,
    /// The conversation on screen, to send with the Imp.
    pub history: &'a [ChatMessage],
}

/// A command as the chat shows it after it was typed: a key given to `/api_key` is hidden.
pub fn shown(line: &str) -> String {
    let t = line.trim();
    let first = t.split_whitespace().next().unwrap_or("");
    if alias(first).unwrap_or(first) != "/api_key" {
        return t.to_string();
    }
    let words: Vec<&str> = t.split_whitespace().collect();
    match words.as_slice() {
        [_] | [_, "forget" | "clear"] => t.to_string(),
        [cmd, "save", ..] => format!("{cmd} save ••••••"),
        [cmd, ..] => format!("{cmd} ••••••"),
        [] => String::new(),
    }
}

/// Whether a line is a command rather than a message. `//text` sends `/text` as a message.
pub fn is_command(line: &str) -> bool {
    let t = line.trim_start();
    t.starts_with('/') && !t.starts_with("//") && t.len() > 1
}

/// Runs a command. A mistake is shown as a problem note, never an error that ends the chat.
pub async fn run(line: &str, mut ctx: Context<'_>) -> Outcome {
    match run_inner(line, &mut ctx).await {
        Ok(outcome) => outcome,
        Err(e) => Outcome::Notes(vec![Note::problem(e.0)]),
    }
}

async fn run_inner(line: &str, ctx: &mut Context<'_>) -> Result<Outcome> {
    let words = split(line.trim())?;
    let Some((first, args)) = words.split_first() else {
        return Ok(Outcome::Notes(Vec::new()));
    };
    let name = alias(first).unwrap_or(first.as_str());
    let rest = || line.trim()[first.len()..].trim().to_string();
    match name {
        "/help" => Ok(help()),
        "/quit" => Ok(Outcome::Quit),
        "/clear" => Ok(Outcome::Clear),
        "/model" => setting(ctx, "model", &rest(), |s| s.model.clone()).await,
        "/base_url" => setting(ctx, "base_url", &rest(), |s| s.imp.base_url.clone()).await,
        "/personality" => setting(ctx, "personality", &rest(), |s| s.imp.personality.clone()).await,
        "/api_key_env" => {
            if args.is_empty() {
                let config = ctx.session.config()?;
                return Ok(Outcome::say(format!(
                    "{} reads its key from {}.",
                    ctx.session.name,
                    keys::env_name(&config, &ctx.session.imp)
                )));
            }
            ctx.session.set("api_key_env", &args[0]).await?;
            Ok(Outcome::say(format!(
                "Saved. {} reads its key from {} now. {}",
                ctx.session.name,
                args[0],
                key_status(ctx.session)
            )))
        }
        "/api_key" => api_key(ctx, args),
        "/imp" => imp(ctx, args),
        "/mcp" => mcp(ctx, args).await,
        "/tools" => tools(ctx, args).await,
        "/settings" => Ok(settings(ctx.session)),
        "/devices" => devices(ctx).await,
        "/pair" => pair(ctx).await,
        "/send" => send(ctx, args).await,
        "/call" => call(ctx, args).await,
        "/return" => give_back(ctx, args).await,
        "/trust" => trust(ctx, args).await,
        "/forget" => forget(ctx, args).await,
        _ => {
            let close = COMMANDS
                .iter()
                .find(|c| c.name.starts_with(&first[..first.len().min(3)]));
            let hint = close.map_or(String::new(), |c| format!(" Did you mean {}?", c.name));
            Err(CliError(format!(
                "There is no command {first}.{hint} Type /help for the list, or //text to send a message that starts with /."
            )))
        }
    }
}

/// Splits a command line into words. Quotes keep spaces in a word, as in a shell.
pub fn split(line: &str) -> Result<Vec<String>> {
    let mut words = Vec::new();
    let mut word = String::new();
    let mut quote: Option<char> = None;
    let mut started = false;
    let mut chars = line.chars();
    while let Some(c) = chars.next() {
        match (quote, c) {
            (Some(q), c) if c == q => quote = None,
            (Some(_), '\\') => word.extend(chars.next()),
            (Some(_), c) => word.push(c),
            (None, '"' | '\'') => {
                quote = Some(c);
                started = true;
            }
            (None, '\\') => {
                word.extend(chars.next());
                started = true;
            }
            (None, c) if c.is_whitespace() => {
                if started {
                    words.push(std::mem::take(&mut word));
                    started = false;
                }
            }
            (None, c) => {
                word.push(c);
                started = true;
            }
        }
    }
    if quote.is_some() {
        return Err(CliError("A quote is not closed.".into()));
    }
    if started {
        words.push(word);
    }
    Ok(words)
}

fn help() -> Outcome {
    let width = COMMANDS
        .iter()
        .map(|c| c.usage.len())
        .max()
        .unwrap_or(0)
        .min(34);
    let mut notes = vec![Note::info("Commands:")];
    for c in COMMANDS {
        let pad = width.saturating_sub(c.usage.len()) + 2;
        if c.usage.len() > width {
            notes.push(Note::info(format!("  {}", c.usage)));
            notes.push(Note::info(format!(
                "  {}{}",
                " ".repeat(width + 2),
                c.about
            )));
        } else {
            notes.push(Note::info(format!(
                "  {}{}{}",
                c.usage,
                " ".repeat(pad),
                c.about
            )));
        }
    }
    notes.push(Note::info(
        "Tab completes a command. //text sends a message that starts with /.",
    ));
    Outcome::Notes(notes)
}

async fn setting(
    ctx: &mut Context<'_>,
    key: &str,
    value: &str,
    current: impl Fn(&Session) -> String,
) -> Result<Outcome> {
    if ctx.visiting.is_some() {
        return Err(CliError(
            "This Imp is visiting: its settings are kept on its home device.".into(),
        ));
    }
    if value.is_empty() {
        return Ok(Outcome::say(format!(
            "{}'s {key} is {}.",
            ctx.session.name,
            current(ctx.session)
        )));
    }
    ctx.session.set(key, value).await?;
    Ok(Outcome::say(format!(
        "Saved. {}'s {key} is {} now.",
        ctx.session.name,
        current(ctx.session)
    )))
}

fn key_status(session: &Session) -> String {
    match &session.key_source {
        Some(source) => format!("The API key comes from {}.", source.describe()),
        None => "There is no API key, which is fine for a local model.".into(),
    }
}

fn api_key(ctx: &mut Context<'_>, args: &[String]) -> Result<Outcome> {
    let name = ctx.session.name.clone();
    match args {
        [] => Ok(Outcome::say(format!(
            "{} The key itself is never shown.",
            key_status(ctx.session)
        ))),
        [word] if word == "forget" || word == "clear" => {
            ctx.session.use_key(None)?;
            let removed = keys::remove_from_keychain(&name).is_ok();
            let what = if removed {
                "Removed the key from the system keychain."
            } else {
                "There was no key in the system keychain."
            };
            Ok(Outcome::say(format!("{what} {}", key_status(ctx.session))))
        }
        [word, key] if word == "save" => {
            keys::save_to_keychain(&name, key)?;
            ctx.session.use_key(Some(key.clone()))?;
            let config = ctx.session.config()?;
            let var = keys::env_name(&config, &ctx.session.imp).to_string();
            let later = if keys::real_env(&var).is_some_and(|v| !v.trim().is_empty()) {
                format!(" Next time {var} is set and comes first.")
            } else {
                String::new()
            };
            Ok(Outcome::say(format!(
                "Saved the key for {name} in the system keychain and using it now.{later}"
            )))
        }
        [key] => {
            ctx.session.use_key(Some(key.clone()))?;
            Ok(Outcome::say(
                "Using that key until the chat ends. /api_key save KEY keeps it in the system keychain.",
            ))
        }
        _ => Err(CliError(
            "Write /api_key KEY, /api_key save KEY or /api_key forget.".into(),
        )),
    }
}

fn imp(ctx: &mut Context<'_>, args: &[String]) -> Result<Outcome> {
    let config = ctx.session.config()?;
    let visitors = ctx
        .device
        .as_ref()
        .map(Device::visitors)
        .unwrap_or_default();
    match args.first() {
        None => {
            let mut notes = vec![Note::info("Imps on this computer:")];
            for (name, imp) in &config.imps {
                let here = if *name == ctx.session.name && ctx.visiting.is_none() {
                    " (this chat)"
                } else {
                    ""
                };
                let away = ctx
                    .device
                    .as_ref()
                    .and_then(|d| d.away_on(imp.id.unwrap_or_default()))
                    .map_or(String::new(), |on| format!(", on {on}"));
                notes.push(Note::info(format!("  {name}  {}{away}{here}", imp.model)));
            }
            if !visitors.is_empty() {
                notes.push(Note::info("Visiting:"));
                for v in &visitors {
                    let state = if v.awake { "" } else { ", asleep" };
                    let here = if ctx.visiting == Some(v.look.id) {
                        " (this chat)"
                    } else {
                        ""
                    };
                    notes.push(Note::info(format!(
                        "  {}  from {}{state}{here}",
                        v.look.name, v.home_name
                    )));
                }
            }
            notes.push(Note::info("Talk to one with /imp NAME."));
            Ok(Outcome::Notes(notes))
        }
        Some(name) => {
            if config.imps.contains_key(name) {
                return Ok(Outcome::Switch(name.clone()));
            }
            let lower = name.to_lowercase();
            if let Some(v) = visitors
                .iter()
                .find(|v| v.look.name.to_lowercase() == lower)
            {
                return Ok(Outcome::Visit(v.look.id));
            }
            let mut names: Vec<String> = config.imps.keys().cloned().collect();
            names.extend(visitors.iter().map(|v| v.look.name.clone()));
            Err(CliError(format!(
                "There is no Imp called {name}. The Imps are: {}.",
                names.join(", ")
            )))
        }
    }
}

async fn mcp(ctx: &mut Context<'_>, args: &[String]) -> Result<Outcome> {
    if ctx.visiting.is_some() {
        return Err(CliError(
            "This Imp is visiting: its tools are on its home device.".into(),
        ));
    }
    match args.first().map(String::as_str) {
        None | Some("list") => Ok(mcp_list(ctx.session)),
        Some("add") => {
            let [_, name, target, rest @ ..] = args else {
                return Err(CliError(
                    "Write /mcp add NAME COMMAND [ARGS...] or /mcp add NAME URL. For example: /mcp add files npx -y @modelcontextprotocol/server-filesystem .".into(),
                ));
            };
            if !crate::config::valid_imp_name(name) {
                return Err(CliError(
                    "A server's name can have 1 to 32 letters, digits, dashes and underscores."
                        .into(),
                ));
            }
            let server = server_from(target, rest)?;
            let mut config = ctx.session.config()?;
            let imp = config
                .imps
                .get_mut(&ctx.session.name)
                .ok_or_else(|| CliError("This Imp is no longer in the settings file.".into()))?;
            let replaced = imp
                .mcp_servers
                .insert(name.clone(), server.clone())
                .is_some();
            config.save(&ctx.session.path)?;
            ctx.session.reconnect_tools().await?;
            let mut notes = vec![Note::info(format!(
                "{} the MCP server {name} ({}) and saved it.",
                if replaced { "Replaced" } else { "Added" },
                describe_server(&server)
            ))];
            notes.extend(server_line(ctx.session, name));
            Ok(Outcome::Notes(notes))
        }
        Some("remove" | "rm" | "delete") => {
            let Some(name) = args.get(1) else {
                return Err(CliError("Write /mcp remove NAME.".into()));
            };
            let mut config = ctx.session.config()?;
            let imp = config
                .imps
                .get_mut(&ctx.session.name)
                .ok_or_else(|| CliError("This Imp is no longer in the settings file.".into()))?;
            if imp.mcp_servers.remove(name).is_none() {
                return Err(CliError(format!(
                    "{} has no MCP server called {name}.",
                    ctx.session.name
                )));
            }
            config.save(&ctx.session.path)?;
            ctx.session.reconnect_tools().await?;
            Ok(Outcome::say(format!("Removed the MCP server {name}.")))
        }
        Some("reload" | "restart") => {
            ctx.session.reconnect_tools().await?;
            Ok(mcp_list(ctx.session))
        }
        Some(other) => Err(CliError(format!(
            "/mcp has no {other}. Use /mcp, /mcp add, /mcp remove or /mcp reload."
        ))),
    }
}

/// A server from what was typed after its name: an address, or a command and its arguments. `--env NAME`
/// and `--header NAME` list names to pass on: their values are read when the server starts.
pub fn server_from(target: &str, rest: &[String]) -> Result<McpServerConfig> {
    let mut server = McpServerConfig {
        command: None,
        args: Vec::new(),
        env: Vec::new(),
        url: None,
        headers: Vec::new(),
    };
    let mut words = rest.iter();
    let mut args = Vec::new();
    while let Some(word) = words.next() {
        match word.as_str() {
            "--env" => {
                let name = words
                    .next()
                    .ok_or_else(|| CliError("--env needs a NAME.".into()))?;
                if !crate::config::valid_env_name(name) {
                    return Err(CliError(
                        "--env takes the NAME of an environment variable, not its value.".into(),
                    ));
                }
                server.env.push(name.clone());
            }
            "--header" => {
                let name = words
                    .next()
                    .ok_or_else(|| CliError("--header needs a NAME.".into()))?;
                if !valid_header_name(name) {
                    return Err(CliError(
                        "--header takes the NAME of a header, such as Authorization, not its value."
                            .into(),
                    ));
                }
                server.headers.push(name.clone());
            }
            _ => args.push(word.clone()),
        }
    }
    if target.starts_with("http://") || target.starts_with("https://") {
        if !args.is_empty() || !server.env.is_empty() {
            return Err(CliError(
                "A server at an address takes no arguments. Only --header NAME.".into(),
            ));
        }
        server.url = Some(target.to_string());
    } else {
        if !server.headers.is_empty() {
            return Err(CliError(
                "--header is for a server at an address. A command takes --env NAME.".into(),
            ));
        }
        server.command = Some(target.to_string());
        server.args = args;
    }
    Ok(server)
}

fn server_line(session: &Session, name: &str) -> Vec<Note> {
    session
        .servers
        .iter()
        .filter(|s| s.name == name)
        .map(|s| match &s.tools {
            Ok(n) => Note::info(format!("  {}  {} tools  {}", s.name, n, s.target)),
            Err(why) => Note::problem(format!("  {}  {why}", s.name)),
        })
        .collect()
}

fn mcp_list(session: &Session) -> Outcome {
    if session.servers.is_empty() {
        return Outcome::Notes(vec![
            Note::info(format!("{} has no MCP servers.", session.name)),
            Note::info(
                "Add one with /mcp add NAME COMMAND [ARGS...], for example the files of this folder:",
            ),
            Note::info("  /mcp add files npx -y @modelcontextprotocol/server-filesystem ."),
        ]);
    }
    let mut notes = vec![Note::info(format!("MCP servers of {}:", session.name))];
    for s in &session.servers {
        notes.extend(server_line(session, &s.name));
    }
    notes.push(Note::info("/tools lists their tools."));
    Outcome::Notes(notes)
}

async fn tools(ctx: &mut Context<'_>, args: &[String]) -> Result<Outcome> {
    if ctx.visiting.is_some() {
        return Err(CliError(
            "This Imp is visiting: its tools are on its home device.".into(),
        ));
    }
    match args {
        [] => {
            let all = ctx.session.tools();
            if all.is_empty() {
                return Ok(Outcome::say(format!(
                    "{} has no tools. /mcp add gives it some.",
                    ctx.session.name
                )));
            }
            let mut notes = vec![Note::info(format!("Tools of {}:", ctx.session.name))];
            for t in all {
                let state = if t.on { "on " } else { "off" };
                notes.push(Note::info(format!("  {state}  {}", t.id)));
            }
            notes.push(Note::info(
                "/tools off ID switches one off, /tools on ID back on.",
            ));
            Ok(Outcome::Notes(notes))
        }
        [switch, id] if switch == "on" || switch == "off" => {
            let on = switch == "on";
            let known = ctx.session.tools().iter().any(|t| t.id == *id);
            let mut config = ctx.session.config()?;
            let imp = config
                .imps
                .get_mut(&ctx.session.name)
                .ok_or_else(|| CliError("This Imp is no longer in the settings file.".into()))?;
            imp.tools_off.retain(|t| t != id);
            if !on {
                if !known {
                    return Err(CliError(format!(
                        "There is no tool {id}. /tools lists them by id."
                    )));
                }
                imp.tools_off.push(id.clone());
            }
            config.save(&ctx.session.path)?;
            ctx.session.reload(&config)?;
            Ok(Outcome::say(format!(
                "Saved. {id} is {}.",
                if on { "on" } else { "off" }
            )))
        }
        _ => Err(CliError(
            "Write /tools, /tools on ID or /tools off ID.".into(),
        )),
    }
}

fn settings(session: &Session) -> Outcome {
    let imp = &session.imp;
    let mut notes = vec![
        Note::info(session.name.clone()),
        Note::info(format!("  model        {}", imp.model)),
        Note::info(format!("  base_url     {}", imp.base_url)),
        Note::info(format!("  personality  {}", imp.personality)),
        Note::info(format!("  api key      {}", key_status(session))),
        Note::info(format!("  folder       {}", session.workspace.display())),
        Note::info(format!(
            "  mcp servers  {}",
            if session.servers.is_empty() {
                "none".to_string()
            } else {
                session
                    .servers
                    .iter()
                    .map(|s| s.name.clone())
                    .collect::<Vec<_>>()
                    .join(", ")
            }
        )),
    ];
    if !imp.tools_off.is_empty() {
        notes.push(Note::info(format!(
            "  tools off    {}",
            imp.tools_off.join(", ")
        )));
    }
    notes.push(Note::info(format!(
        "  file         {}",
        session.path.display()
    )));
    Outcome::Notes(notes)
}

fn no_devices_here() -> CliError {
    CliError("Devices work in the full-screen chat, or keep `imp link` running.".into())
}

/// The device, started now if it was not.
async fn device<'a>(ctx: &'a mut Context<'_>) -> Result<&'a mut Device> {
    if ctx.device.is_none() {
        let options = ctx.device_options.ok_or_else(no_devices_here)?;
        let device = Device::start(
            options,
            Arc::new(SeedFile::moving_from_keychain(&options.data_dir)),
        )
        .await
        .map_err(|e| CliError(e.to_string()))?;
        ctx.session.set_remote(Some(device.remote()));
        *ctx.device = Some(device);
    }
    Ok(ctx.device.as_mut().expect("started above"))
}

/// The device, if this computer was ever linked. Not started just to say there is nothing.
async fn linked_device<'a>(ctx: &'a mut Context<'_>) -> Result<&'a mut Device> {
    let options = ctx.device_options.ok_or_else(no_devices_here)?;
    if ctx.device.is_none() && !options.has_book() {
        return Err(CliError(
            "This computer is not linked with any device yet. Use /pair and scan the code with Imp on a Mac or an iPhone.".into(),
        ));
    }
    device(ctx).await
}

async fn devices(ctx: &mut Context<'_>) -> Result<Outcome> {
    let device = linked_device(ctx).await?;
    let peers = device.peers();
    let mut notes = vec![Note::info(format!(
        "This computer is {} on the link.",
        device.name()
    ))];
    if peers.is_empty() {
        notes.push(Note::info(
            "No device is linked yet. /pair shows a code to scan.",
        ));
    }
    for p in &peers {
        let state = match (p.connected, p.through_hop) {
            (true, true) => "connected through the Hop",
            (true, false) => "connected",
            (false, _) => "not connected",
        };
        let trusted = if p.trusted { ", yours (trusted)" } else { "" };
        notes.push(Note::info(format!("  {}  {state}{trusted}", p.name)));
        let imps: Vec<&str> = p.stage.iter().map(|s| s.imp.name.as_str()).collect();
        if p.connected && !imps.is_empty() {
            notes.push(Note::info(format!(
                "    on its screen: {}",
                imps.join(", ")
            )));
        }
    }
    let visitors = device.visitors();
    if !visitors.is_empty() {
        notes.push(Note::info("Visiting this computer:"));
        for v in visitors {
            let state = if v.awake {
                ""
            } else {
                " (asleep: its home is away)"
            };
            notes.push(Note::info(format!(
                "  {}  from {}{state}",
                v.look.name, v.home_name
            )));
        }
    }
    if peers.iter().any(|p| p.connected) {
        notes.push(Note::info(
            "/send DEVICE sends this Imp there. /trust DEVICE lets Imps use their tools for it.",
        ));
    }
    Ok(Outcome::Notes(notes))
}

async fn pair(ctx: &mut Context<'_>) -> Result<Outcome> {
    let device = device(ctx).await?;
    let invite = device.invite().await?;
    let url = invite.url();
    let mut notes: Vec<Note> = crate::qr::rows(&url)?
        .into_iter()
        .map(|row| Note {
            kind: NoteKind::Code,
            text: row,
        })
        .collect();
    notes.push(Note::info(
        "Scan this code with Imp on a Mac or an iPhone (Devices, then Scan). It works for 15 minutes.",
    ));
    notes.push(Note::info(reach_note(&invite.routes)));
    notes.push(Note::info(format!("The code as text: {url}")));
    Ok(Outcome::Notes(notes))
}

async fn send(ctx: &mut Context<'_>, args: &[String]) -> Result<Outcome> {
    let Some(to) = args.first() else {
        return Err(CliError("Write /send DEVICE, such as /send iPhone.".into()));
    };
    let visiting = ctx.visiting;
    let current = ctx.session.name.clone();
    let history = ctx.history.to_vec();
    let which = args.get(1).cloned();
    let device = linked_device(ctx).await?;
    let peer = device.find_peer(to)?;
    if let Some(visitor) = visiting.filter(|_| which.is_none()) {
        device.send_visitor(visitor, &peer).await?;
        return Ok(Outcome::Sent(vec![Note::info(format!(
            "Sending it to {}…",
            peer.name
        ))]));
    }
    let name = which.unwrap_or(current.clone());
    let messages = if name == current { history } else { Vec::new() };
    device.send_imp(&name, messages, &peer).await?;
    let note = Note::info(format!("Sending {name} to {}…", peer.name));
    if name == current && visiting.is_none() {
        Ok(Outcome::Sent(vec![note]))
    } else {
        Ok(Outcome::Notes(vec![note]))
    }
}

async fn call(ctx: &mut Context<'_>, args: &[String]) -> Result<Outcome> {
    let name = args
        .first()
        .cloned()
        .unwrap_or_else(|| ctx.session.name.clone());
    let device = linked_device(ctx).await?;
    match device.call_home(&name).await? {
        Update::CameHome { imp, messages } => Ok(Outcome::CameHome { imp, messages }),
        _ => Ok(Outcome::say(format!("{name} is back."))),
    }
}

async fn give_back(ctx: &mut Context<'_>, args: &[String]) -> Result<Outcome> {
    let visiting = ctx.visiting;
    let device = linked_device(ctx).await?;
    let visitors = device.visitors();
    let visitor = match args.first() {
        Some(name) => visitors
            .iter()
            .find(|v| v.look.name.eq_ignore_ascii_case(name))
            .ok_or_else(|| CliError(format!("No Imp called {name} is visiting.")))?,
        None => visiting
            .and_then(|id| visitors.iter().find(|v| v.look.id == id))
            .ok_or_else(|| CliError("Write /return NAME. /devices lists the visitors.".into()))?,
    };
    let (id, name, home) = (
        visitor.look.id,
        visitor.look.name.clone(),
        visitor.home_name.clone(),
    );
    device.send_home(id).await?;
    Ok(Outcome::say(format!("{name} is going back to {home}.")))
}

async fn trust(ctx: &mut Context<'_>, args: &[String]) -> Result<Outcome> {
    let Some(name) = args.first() else {
        return Err(CliError(
            "Write /trust DEVICE, or /trust DEVICE off.".into(),
        ));
    };
    let on = args.get(1).is_none_or(|w| w != "off");
    let device = linked_device(ctx).await?;
    let peer = device.find_peer(name)?;
    device.set_trusted(peer.id, on).await;
    Ok(Outcome::say(if on {
        format!(
            "{} is one of your devices now: Imps of this computer use their tools (files, MCP servers) for what it asks.",
            peer.name
        )
    } else {
        format!(
            "{} is not trusted now: Imps of this computer only talk for it, without tools.",
            peer.name
        )
    }))
}

async fn forget(ctx: &mut Context<'_>, args: &[String]) -> Result<Outcome> {
    let Some(name) = args.first() else {
        return Err(CliError("Write /forget DEVICE.".into()));
    };
    let device = linked_device(ctx).await?;
    let peer = device.find_peer(name)?;
    let updates = device.forget(peer.id).await;
    let mut notes = vec![Note::info(format!(
        "Forgot {}. Scan a new code to link it again.",
        peer.name
    ))];
    for update in updates {
        if let Update::CameHome { imp, .. } = update {
            notes.push(Note::info(format!("{imp} came back.")));
        }
    }
    Ok(Outcome::Notes(notes))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn words_split_like_a_shell() {
        assert_eq!(
            split(r#"/mcp add files npx -y "@scope/server name" '.'"#).unwrap(),
            [
                "/mcp",
                "add",
                "files",
                "npx",
                "-y",
                "@scope/server name",
                "."
            ]
        );
        assert_eq!(split("  /model   a  ").unwrap(), ["/model", "a"]);
        assert_eq!(split(r"a\ b").unwrap(), ["a b"]);
        assert_eq!(split(r#"x """#).unwrap(), ["x", ""]);
        assert!(split("\"open").is_err());
    }

    #[test]
    fn a_key_is_never_shown() {
        assert_eq!(shown("/api_key sk-secret"), "/api_key ••••••");
        assert_eq!(shown("/key save sk-secret"), "/key save ••••••");
        assert_eq!(shown("/api_key forget"), "/api_key forget");
        assert_eq!(shown("/model x"), "/model x");
    }

    #[test]
    fn commands_and_messages_are_told_apart() {
        assert!(is_command("/model x"));
        assert!(is_command("  /help"));
        assert!(!is_command("//not a command"));
        assert!(!is_command("/"));
        assert!(!is_command("hello /model"));
    }

    #[test]
    fn completion_matches_names_and_aliases() {
        let names = |t: &str| matching(t).iter().map(|c| c.name).collect::<Vec<_>>();
        assert_eq!(names("/mo"), ["/model"]);
        assert!(names("/").len() == COMMANDS.len());
        assert_eq!(names("/url"), ["/base_url"]);
        assert!(names("/model gpt").is_empty());
        assert!(names("hi").is_empty());
    }

    #[test]
    fn a_server_is_a_command_or_an_address() {
        let words = |s: &str| s.split(' ').map(String::from).collect::<Vec<_>>();
        let files = server_from(
            "npx",
            &words("-y @modelcontextprotocol/server-filesystem . --env TOKEN"),
        )
        .unwrap();
        assert_eq!(files.command.as_deref(), Some("npx"));
        assert_eq!(
            files.args,
            ["-y", "@modelcontextprotocol/server-filesystem", "."]
        );
        assert_eq!(files.env, ["TOKEN"]);
        let web = server_from(
            "https://mcp.example.org/mcp",
            &words("--header Authorization"),
        )
        .unwrap();
        assert_eq!(web.url.as_deref(), Some("https://mcp.example.org/mcp"));
        assert_eq!(web.headers, ["Authorization"]);
        assert!(server_from("https://x/mcp", &words("extra")).is_err());
        assert!(server_from("npx", &words("--header Authorization")).is_err());
        assert!(server_from("npx", &words("--env sk-abc123")).is_err());
    }

    #[test]
    fn every_command_has_help_and_a_unique_name() {
        let mut names: Vec<&str> = COMMANDS.iter().map(|c| c.name).collect();
        names.sort_unstable();
        names.dedup();
        assert_eq!(names.len(), COMMANDS.len());
        assert!(
            COMMANDS
                .iter()
                .all(|c| c.usage.starts_with(c.name) && !c.about.is_empty())
        );
        let Outcome::Notes(lines) = help() else {
            panic!("help gives notes")
        };
        for c in COMMANDS {
            assert!(lines.iter().any(|l| l.text.contains(c.usage)), "{}", c.name);
        }
    }
}
