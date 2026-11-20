//! The commands typed in a chat after a `/`: `/model`, `/mcp add`, `/send` and the rest. The full-screen chat
//! and the line chat both use them, so they say the same things. The ones that change settings are the command
//! line's (`crate::commands::manage`): every change is saved to the shared configuration and takes effect for
//! the next message. A key is typed hidden, as the front end asks for it (`Outcome::Secret`).

use crate::custom;
use crate::link::device::{Device, DeviceOptions, Update};
use crate::link::{SeedFile, device::reach_note};
use crate::project;
use crate::session::Session;
use crate::{CliError, Result};
use imp_engine::ChatMessage;
use imp_engine::config::Command as Template;
use std::sync::Arc;
use uuid::Uuid;

use crate::grammar::alias;
pub use crate::grammar::{
    COMMANDS, Choice, Command, choices, find, hint, matching, needs_args, suggest, takes_args,
    variants,
};

/// A line the chat shows for a command. Not part of the conversation. The full-screen chat gives each
/// kind its look. [`Note::plain`] is the same line as text, for the line chat.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Note {
    pub kind: NoteKind,
    pub text: String,
    /// What a [`NoteKind::Field`] is: `model` for the value `openai/gpt-6-luna`.
    pub label: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum NoteKind {
    /// A sentence. `code` and **bold** in it show as such.
    Info,
    Problem,
    /// A row of a QR code: drawn black on white, as it is.
    Code,
    /// The command that was typed, at the top of what it says.
    Command,
    /// The title of a group of lines, such as `MCP servers of pip`.
    Heading,
    /// A label and its value. The labels of the fields in a row line up.
    Field,
    /// Something that is on (or connected), or off.
    On,
    Off,
}

impl Note {
    fn new(kind: NoteKind, text: impl Into<String>) -> Self {
        Self {
            kind,
            text: text.into(),
            label: String::new(),
        }
    }

    pub fn info(text: impl Into<String>) -> Self {
        Self::new(NoteKind::Info, text)
    }

    pub fn problem(text: impl Into<String>) -> Self {
        Self::new(NoteKind::Problem, text)
    }

    pub fn code(row: impl Into<String>) -> Self {
        Self::new(NoteKind::Code, row)
    }

    pub fn command(line: impl Into<String>) -> Self {
        Self::new(NoteKind::Command, line)
    }

    pub fn heading(text: impl Into<String>) -> Self {
        Self::new(NoteKind::Heading, text)
    }

    pub fn field(label: impl Into<String>, value: impl Into<String>) -> Self {
        Self {
            label: label.into(),
            ..Self::new(NoteKind::Field, value)
        }
    }

    pub fn check(on: bool, text: impl Into<String>) -> Self {
        Self::new(if on { NoteKind::On } else { NoteKind::Off }, text)
    }

    /// The line as plain text.
    pub fn plain(&self) -> String {
        match self.kind {
            NoteKind::Info | NoteKind::Code | NoteKind::Heading => self.text.clone(),
            NoteKind::Problem => format!("! {}", self.text),
            NoteKind::Command => format!("› {}", self.text),
            NoteKind::Field => format!("  {}  {}", self.label, self.text),
            NoteKind::On => format!("  on   {}", self.text),
            NoteKind::Off => format!("  off  {}", self.text),
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
    /// Sum the conversation up and go on from the summary.
    Compact,
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
    /// The command needs a secret the person types hidden (a key). Run `line` again with it, through
    /// [`run_with_secret`]. It is never shown, kept in the history or sent anywhere else.
    Secret {
        prompt: String,
        line: String,
    },
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

/// Whether a line is a command rather than a message. `//text` sends `/text` as a message.
pub fn is_command(line: &str) -> bool {
    let t = line.trim_start();
    t.starts_with('/') && !t.starts_with("//") && t.len() > 1
}

/// Runs a command. A mistake is shown as a problem note, never an error that ends the chat.
pub async fn run(line: &str, ctx: Context<'_>) -> Outcome {
    run_with_secret(line, ctx, None).await
}

/// [`run`] again for a command that asked for a secret (`Outcome::Secret`), now with what was typed.
pub async fn run_with_secret(line: &str, mut ctx: Context<'_>, secret: Option<String>) -> Outcome {
    match run_inner(line, &mut ctx, secret).await {
        Ok(outcome) => outcome,
        Err(e) => Outcome::Notes(vec![Note::problem(e.0)]),
    }
}

async fn run_inner(line: &str, ctx: &mut Context<'_>, secret: Option<String>) -> Result<Outcome> {
    let words = split(line.trim())?;
    let Some((first, args)) = words.split_first() else {
        return Ok(Outcome::Notes(Vec::new()));
    };
    let name = alias(first).unwrap_or(first.as_str());
    match name {
        "/help" => {
            let mut notes: Vec<Note> = ctx
                .session
                .sync()
                .await?
                .into_iter()
                .map(Note::info)
                .collect();
            let Outcome::Notes(list) = help(&project::custom_commands(&ctx.session.loaded)) else {
                unreachable!("help is notes")
            };
            notes.extend(list);
            Ok(Outcome::Notes(notes))
        }
        "/quit" => Ok(Outcome::Quit),
        "/clear" => Ok(Outcome::Clear),
        "/compact" if ctx.visiting.is_some() => Err(CliError(
            "This Imp is visiting: its chat is kept on its home device.".into(),
        )),
        "/compact" => Ok(Outcome::Compact),
        "/imp" => imp(ctx, args),
        "/tools" => tools(ctx),
        _ if find(name).is_some_and(|c| c.managed) => {
            let mut managed_words = words.clone();
            managed_words[0] = name.to_string();
            managed(ctx, &managed_words, line, secret).await
        }
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

/// Splits a command line into words as a shell does, with the core's rule (the apps use the same):
/// quotes keep spaces in a word, and a backslash takes the next character as it is.
pub fn split(line: &str) -> Result<Vec<String>> {
    let words = imp_engine::mcp::setup::split_words(line);
    if words.unclosed {
        return Err(CliError("A quote is not closed.".into()));
    }
    Ok(words.words)
}

fn help(custom: &[Template]) -> Outcome {
    let mut notes = vec![Note::heading("Commands")];
    for c in COMMANDS.iter() {
        let forms = variants(c);
        notes.push(Note::field(
            if forms.is_empty() { &c.usage } else { &c.name },
            &c.about,
        ));
        for form in forms {
            notes.push(Note::field(format!("    {form}"), ""));
        }
    }
    if !custom.is_empty() {
        notes.push(Note::heading("Custom commands"));
    }
    for c in custom {
        let shadowed = find(&format!("/{}", c.name)).is_some();
        let about = if shadowed {
            "Not used: a built-in command has this name".to_string()
        } else {
            custom::about(c)
        };
        notes.push(Note::field(custom::usage(c), about));
    }
    notes.push(Note::info(
        "A built-in command wins over a custom command of the same name. The commands that change settings work as `imp agent`, `imp mcp`... in a terminal. Tab completes a command. `//text` sends a message that starts with /. `?` lists every key.",
    ));
    Outcome::Notes(notes)
}

/// `/imp`: the Imps, or switch to one.
fn imp(ctx: &mut Context<'_>, args: &[String]) -> Result<Outcome> {
    let loaded = &ctx.session.loaded;
    let visitors = ctx
        .device
        .as_ref()
        .map(Device::visitors)
        .unwrap_or_default();
    match args.first() {
        None => {
            let mut notes = vec![Note::heading("Imps on this computer")];
            for found in loaded.imps() {
                let name = &found.value.name;
                let here = if *name == ctx.session.name && ctx.visiting.is_none() {
                    " (this chat)"
                } else {
                    ""
                };
                let away = ctx
                    .device
                    .as_ref()
                    .and_then(|d| d.away_on(crate::settings::imp_id(loaded, name)))
                    .map_or(String::new(), |on| format!(", on {on}"));
                let folder = if found.scope == imp_engine::config::Scope::Project {
                    ", from this folder"
                } else {
                    ""
                };
                let model = found
                    .value
                    .model
                    .clone()
                    .or_else(|| loaded.config.model.clone())
                    .unwrap_or_else(|| "no model".into());
                notes.push(Note::field(
                    name.clone(),
                    format!("{model}{folder}{away}{here}"),
                ));
            }
            if !visitors.is_empty() {
                notes.push(Note::heading("Visiting"));
                for v in &visitors {
                    let state = if v.awake { "" } else { ", asleep" };
                    let here = if ctx.visiting == Some(v.look.id) {
                        " (this chat)"
                    } else {
                        ""
                    };
                    notes.push(Note::field(
                        v.look.name.clone(),
                        format!("from {}{state}{here}", v.home_name),
                    ));
                }
            }
            notes.push(Note::info("Talk to one with `/imp NAME`."));
            Ok(Outcome::Notes(notes))
        }
        Some(name) => {
            if let Ok(found) = crate::settings::find_imp(loaded, Some(name)) {
                return Ok(Outcome::Switch(found.value.name.clone()));
            }
            let lower = name.to_lowercase();
            if let Some(v) = visitors
                .iter()
                .find(|v| v.look.name.to_lowercase() == lower)
            {
                return Ok(Outcome::Visit(v.look.id));
            }
            let mut names: Vec<String> = loaded.imps().map(|a| a.value.name.clone()).collect();
            names.extend(visitors.iter().map(|v| v.look.name.clone()));
            Err(CliError(format!(
                "There is no Imp called {name}. The Imps are: {}.",
                names.join(", ")
            )))
        }
    }
}

/// `/tools`: what the Imp has, and whether its rules leave each on. Rules change with `/permission`.
fn tools(ctx: &Context<'_>) -> Result<Outcome> {
    if ctx.visiting.is_some() {
        return Err(CliError(
            "This Imp is visiting: its tools are on its home device.".into(),
        ));
    }
    let all = ctx.session.tools();
    if all.is_empty() {
        return Ok(Outcome::say(format!(
            "{} has no tools. `/mcp add` gives it some.",
            ctx.session.name
        )));
    }
    let mut notes = vec![Note::heading(format!("Tools of {}", ctx.session.name))];
    notes.extend(all.into_iter().map(|t| Note::check(t.on, t.id)));
    notes.push(Note::info(
        "Rules decide: `/permission add mcp 'server/*' deny --agent NAME` takes tools away.",
    ));
    Ok(Outcome::Notes(notes))
}

/// The commands that are the command line's: `/agent`, `/provider`, `/mcp`... are parsed by the same grammar
/// and run the same code as `imp agent`, `imp provider`, `imp mcp`..., and the chat takes what they changed
/// at once.
async fn managed(
    ctx: &mut Context<'_>,
    words: &[String],
    line: &str,
    secret: Option<String>,
) -> Result<Outcome> {
    use crate::cli::{AuthAction, Cli, Command as Cmd, Manage};
    use crate::commands::manage;
    use clap::Parser;
    if ctx.visiting.is_some() {
        return Err(CliError(
            "This Imp is visiting: its settings are kept on its home device.".into(),
        ));
    }
    let command = find(&words[0]).expect("a managed command is in the table");
    if let Some(word) = words.get(1)
        && crate::grammar::is_terminal_only(word)
    {
        return Err(CliError(format!(
            "A file is edited in a terminal: `imp {} {word} NAME`.",
            words[0].trim_start_matches('/')
        )));
    }
    let mut argv = vec!["imp".to_string()];
    argv.extend(words.iter().cloned());
    argv[1] = argv[1].trim_start_matches('/').to_string();
    // A name alone does the first thing the grammar lists, which is `list` where there is one.
    if argv.len() == 2 && command.bare && command.forms.iter().any(|f| f.word == "list") {
        argv.push("list".to_string());
    }
    let cli = match Cli::try_parse_from(&argv) {
        Ok(cli) => cli,
        Err(e) if e.use_stderr() => {
            return Err(CliError(
                e.render().to_string().trim_end().replacen("error: ", "", 1),
            ));
        }
        Err(e) => return Ok(lines(&e.render().to_string())),
    };
    let Some(Cmd::Manage(command)) = cli.command else {
        return Err(CliError("That is not a command of a chat.".into()));
    };
    // The key is typed hidden by whoever shows the chat, and the command runs again with it.
    if let (
        Manage::Auth {
            action: AuthAction::Set { provider },
        },
        None,
    ) = (&command, &secret)
    {
        return Ok(Outcome::Secret {
            prompt: format!("Key for {provider}"),
            line: line.to_string(),
        });
    }
    let mut secret = secret;
    let mut typed = |_: &str| -> Result<String> {
        secret
            .take()
            .ok_or_else(|| CliError("A key is needed.".into()))
    };
    let reply = manage::run(&ctx.session.settings, command, &mut typed)?;
    // What this command changed is said by its own reply.
    ctx.session.sync().await?;
    Ok(lines(&reply.render(cli.json)))
}

fn lines(text: &str) -> Outcome {
    Outcome::Notes(text.lines().map(|l| Note::info(l.to_string())).collect())
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
    let mut notes = vec![Note::heading(format!("Devices of {}", device.name()))];
    if peers.is_empty() {
        notes.push(Note::info(
            "No device is linked yet. `/pair` shows a code to scan.",
        ));
    }
    for p in &peers {
        let state = match (p.connected, p.through_hop) {
            (true, true) => "connected through the Hop",
            (true, false) => "connected",
            (false, _) => "not connected",
        };
        let trusted = if p.trusted { " · yours (trusted)" } else { "" };
        let imps: Vec<&str> = p.stage.iter().map(|s| s.imp.name.as_str()).collect();
        let screen = if p.connected && !imps.is_empty() {
            format!(" · on its screen: {}", imps.join(", "))
        } else {
            String::new()
        };
        notes.push(Note::check(
            p.connected,
            format!("**{}**  {state}{trusted}{screen}", p.name),
        ));
    }
    let visitors = device.visitors();
    if !visitors.is_empty() {
        notes.push(Note::heading("Visiting this computer"));
        for v in visitors {
            let state = if v.awake {
                ""
            } else {
                " (asleep: its home is away)"
            };
            notes.push(Note::check(
                v.awake,
                format!("**{}**  from {}{state}", v.look.name, v.home_name),
            ));
        }
    }
    if peers.iter().any(|p| p.connected) {
        notes.push(Note::info(
            "`/send DEVICE` sends this Imp there. `/trust DEVICE` lets Imps use their tools for it.",
        ));
    }
    Ok(Outcome::Notes(notes))
}

async fn pair(ctx: &mut Context<'_>) -> Result<Outcome> {
    let device = device(ctx).await?;
    let invite = device.invite().await?;
    let url = invite.url();
    let mut notes: Vec<Note> = crate::qr::rows(&url)?.into_iter().map(Note::code).collect();
    notes.push(Note::heading("Link a Mac or an iPhone"));
    notes.push(Note::field(
        "scan",
        "Open Imp on the other device, then **Devices → Scan**, and point it at the code.",
    ));
    notes.push(Note::field("works for", "15 minutes, for one device"));
    notes.push(Note::field("network", reach_note(&invite.routes)));
    notes.push(Note::field("as text", format!("`{url}`")));
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
            split(r#"/mcp add files --command npx -y "@scope/server name" '.'"#).unwrap(),
            [
                "/mcp",
                "add",
                "files",
                "--command",
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
    fn commands_and_messages_are_told_apart() {
        assert!(is_command("/model x"));
        assert!(is_command("  /help"));
        assert!(!is_command("//not a command"));
        assert!(!is_command("/"));
        assert!(!is_command("hello /model"));
    }

    #[test]
    fn completion_matches_names_and_aliases() {
        let names = |t: &str| {
            matching(t)
                .iter()
                .map(|c| c.name.as_str())
                .collect::<Vec<_>>()
        };
        assert_eq!(names("/mo"), ["/model"]);
        assert!(names("/").len() == COMMANDS.len());
        // A prefix of an alias completes its command, before the alias is complete.
        assert_eq!(names("/ex"), ["/quit"]);
        assert_eq!(
            suggest("/ex").first().map(|c| c.name.as_str()),
            Some("/quit")
        );
        assert!(names("/model gpt").is_empty());
        assert!(names("hi").is_empty());
    }

    #[test]
    fn every_command_has_help() {
        assert!(
            COMMANDS
                .iter()
                .all(|c| c.usage.starts_with(&c.name) && !c.about.is_empty())
        );
        let Outcome::Notes(lines) = help(&[]) else {
            panic!("help gives notes")
        };
        for c in COMMANDS.iter() {
            let shown = if variants(c).is_empty() {
                &c.usage
            } else {
                &c.name
            };
            assert!(
                lines.iter().any(|l| l.plain().contains(shown.as_str())),
                "{}",
                c.name
            );
        }
    }

    #[test]
    fn help_says_a_built_in_wins_over_a_custom_command() {
        let custom = vec![
            Template::parse("review", "Review $ARGUMENTS").unwrap(),
            Template::parse("model", "never").unwrap(),
        ];
        let Outcome::Notes(lines) = help(&custom) else {
            panic!("help gives notes")
        };
        let text: Vec<String> = lines.iter().map(Note::plain).collect();
        assert!(
            text.iter().any(|l| l.contains("/review ARGUMENTS")),
            "{text:?}"
        );
        assert!(
            text.iter()
                .any(|l| l.contains("a built-in command has this name"))
        );
        assert!(text.iter().any(|l| l.contains("A built-in command wins")));
    }

    #[test]
    fn commands_with_several_forms_list_them() {
        let forms = |name: &str| variants(find(name).unwrap());
        assert_eq!(forms("/project"), ["show", "trust", "untrust"]);
        assert!(forms("/auth").contains(&"clear PROVIDER".to_string()));
        assert!(forms("/model").is_empty());
        assert!(forms("/pair").is_empty());
        let Outcome::Notes(lines) = help(&[]) else {
            panic!("help gives notes")
        };
        assert!(lines.iter().any(|l| l.plain().trim() == "remove NAME"));
    }
}
