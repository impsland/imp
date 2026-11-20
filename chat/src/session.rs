//! An Imp ready to chat: its agent, its model client, its MCP servers, its tools and the rules that decide
//! what it may do. Everything comes from the shared configuration (`crate::settings`). The session takes
//! the configuration again when a file changed (`sync`), whoever changed it: the chat itself with a `/`
//! command, `imp` in another terminal or the Mac app.

use crate::chat_state::ChatState;
use crate::gate::{Asker, Gate, Gated, NoOne};
use crate::project::{SkillHost, shown_path};
use crate::settings::{self, Settings};
use crate::troupe::{ImpMessageHost, Later, Remote};
use crate::{CliError, Result};
use imp_engine::config::{Agent, Loaded, McpServer, Resolved, effective_rules, resolve};
use imp_engine::link::LinkImp;
use imp_engine::memory::ChatMemory;
use imp_engine::troupe::TalkWaiting;
use imp_engine::{
    ChatMessage, McpEndpoint, McpHost, McpServerSpec, OpenAiClient, TalkStore, ToolSelection,
    Toolbox,
};
use std::path::{Path, PathBuf};
use std::rc::Rc;
use std::time::Duration;

/// How long an MCP server may take to start and to answer one request.
const MCP_TIMEOUT: Duration = Duration::from_secs(60);

/// What the model is told in a chat: what it is, the folder the chat was started in, and what that folder's
/// `AGENTS.md` files and skills say. All of it stays the same for the whole chat, so a service that caches
/// the start of a request can reuse it.
fn system_in(loaded: &Loaded, agent: &Agent, workspace: &Path) -> String {
    format!(
        "{}\n\nThe person started this chat in the folder {}. When they talk about files or \"this folder\", they mean that one. Tools that take a path want it inside that folder, written in full. When a message ends with <attached_files>, those are files the person picked with @ for you to read.{}",
        settings::system_prompt(agent, loaded.config.imps.get(&agent.name)),
        workspace.display(),
        loaded.system_suffix()
    )
}

/// Replaces `${workspaceFolder}` and `${cwd}` with the folder the chat was started in, and a leading `~`
/// with the home folder, so one configuration works in every folder.
pub fn expand(arg: &str, workspace: &Path, home: Option<&Path>) -> String {
    let folder = workspace.display().to_string();
    let out = arg
        .replace("${workspaceFolder}", &folder)
        .replace("${cwd}", &folder);
    match (out.as_str(), home) {
        ("~", Some(home)) => home.display().to_string(),
        (_, Some(home)) if out.starts_with("~/") => home.join(&out[2..]).display().to_string(),
        _ => out,
    }
}

/// The MCP servers of the configuration as ways to reach them. `names` limits them to these servers.
pub fn mcp_specs(
    loaded: &Loaded,
    names: &[String],
    workspace: &Path,
    home: Option<&Path>,
) -> Vec<McpServerSpec> {
    names
        .iter()
        .filter_map(|name| {
            let endpoint = match loaded.config.mcp.get(name)? {
                McpServer::Local {
                    command,
                    environment,
                    ..
                } => {
                    let (first, rest) = command.split_first()?;
                    McpEndpoint::Command {
                        command: expand(first, workspace, home),
                        args: rest.iter().map(|a| expand(a, workspace, home)).collect(),
                        env: environment.clone().into_iter().collect::<Vec<_>>().into(),
                    }
                }
                McpServer::Remote { url, headers, .. } => McpEndpoint::Http {
                    url: url.clone(),
                    headers: headers.clone().into_iter().collect::<Vec<_>>().into(),
                },
            };
            Some(McpServerSpec {
                name: name.clone(),
                endpoint,
            })
        })
        .collect()
}

/// The folder for saved data: `IMP_DATA_DIR`, or the usual data folder for `imp` (see `folders`).
pub fn data_dir() -> Result<PathBuf> {
    if let Some(dir) = std::env::var("IMP_DATA_DIR")
        .ok()
        .filter(|d| !d.trim().is_empty())
    {
        return Ok(PathBuf::from(dir));
    }
    crate::folders::data_dir()
        .ok_or_else(|| CliError("Could not find a folder for data. Set IMP_DATA_DIR.".into()))
}

/// What a session is opened with, apart from the configuration.
#[derive(Clone, Default)]
pub struct SessionOptions {
    /// Imps on other devices this Imp can message.
    pub remote: Option<Rc<dyn Remote>>,
    /// The chat gives the Imp the answers to messages it sent without waiting (it polls `Session::later`).
    /// Without it every message to another Imp waits for the answer.
    pub answers_later: bool,
    /// Whoever can be asked when a rule says `ask`. Nobody if left out: `ask` is then `deny`.
    pub asker: Option<Rc<dyn Asker>>,
}

/// One MCP server of the session and how it went.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ServerStatus {
    pub name: String,
    /// `npx -y ...` or the address.
    pub target: String,
    /// The number of tools it offers, or why it is not there.
    pub tools: std::result::Result<usize, String>,
}

/// One tool the Imp could be offered.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ToolInfo {
    pub id: String,
    pub name: String,
    pub on: bool,
}

/// Everything a chat needs, ready to use: the Imp, its model client and its tools.
pub struct Session {
    pub settings: Settings,
    pub loaded: Loaded,
    pub name: String,
    pub agent: Agent,
    /// How the model was resolved: the service, its key, the variant's request fields.
    pub resolved: Resolved,
    /// What requests call the model (`gpt-6-luna`), and what people read (`openrouter/gpt-6-luna#high`).
    pub model: String,
    pub model_label: String,
    pub client: Rc<OpenAiClient>,
    pub system: String,
    pub gate: Rc<Gate>,
    /// The tools as the rules leave them.
    pub toolbox: Rc<Gated>,
    /// The MCP servers behind the toolbox, to end their sessions when the chat ends.
    pub mcp: Rc<McpHost>,
    pub servers: Vec<ServerStatus>,
    pub max_steps: usize,
    /// Whether a message to another Imp waits for the answer (`talk.waiting`).
    pub waiting: TalkWaiting,
    /// The messages sent without waiting and their answers, when the chat takes them (`answers_later`).
    pub later: Option<Rc<Later>>,
    /// How many remembered exchanges go with each message (0: all), and when a chat counts as long.
    pub memory_exchanges: usize,
    pub long_chat_tokens: usize,
    /// Plain sentences about things that did not start, such as an MCP server or a broken file.
    pub warnings: Vec<String>,
    /// Plain sentences about the folder that need nothing fixed, such as settings waiting to be trusted.
    pub notices: Vec<String>,
    pub workspace: PathBuf,
    options: SessionOptions,
    stamp: u64,
    mcp_specs: Vec<McpServerSpec>,
}

impl Session {
    pub async fn open(
        settings: &Settings,
        name: Option<&str>,
        options: SessionOptions,
    ) -> Result<Self> {
        let loaded = settings.load();
        let agent = settings::find_imp(&loaded, name)?.value.clone();
        let resolved = resolve(&loaded.config, &loaded.auth, &agent, None).map_err(CliError)?;
        let asker = options.asker.clone().unwrap_or_else(|| Rc::new(NoOne));
        let gate = Rc::new(Gate::new(
            &agent.name,
            effective_rules(&loaded.config, &agent),
            settings.env.home_dir().map(|h| h.display().to_string()),
            asker,
            settings.store.clone(),
        ));
        let mut session = Self {
            settings: settings.clone(),
            client: Rc::new(client_of(&loaded, &resolved)?),
            system: system_in(&loaded, &agent, &settings.workspace),
            max_steps: settings::steps_of(&agent),
            waiting: settings::talk_of(&loaded).waiting,
            later: options.answers_later.then(|| Rc::new(Later::new())),
            memory_exchanges: settings::memory_exchanges(&loaded, &agent.name),
            long_chat_tokens: settings::long_chat_tokens(&loaded, &agent.name),
            model: resolved.model.clone(),
            model_label: resolved.reference(),
            name: agent.name.clone(),
            toolbox: Rc::new(Gated {
                gate: gate.clone(),
                inner: Rc::new(Toolbox::new()),
            }),
            gate,
            mcp: Rc::new(McpHost::connect(&[], MCP_TIMEOUT).await.0),
            servers: Vec::new(),
            warnings: Vec::new(),
            notices: Vec::new(),
            workspace: settings.workspace.clone(),
            stamp: settings.stamp(),
            mcp_specs: Vec::new(),
            agent,
            resolved,
            loaded,
            options,
        };
        session.connect_tools().await;
        Ok(session)
    }

    /// How other devices see this Imp.
    pub fn look(&self) -> LinkImp {
        let mut look = settings::look_of(
            &self.loaded,
            &self.agent,
            &settings::servers_of(&self.loaded, &self.agent),
        );
        let started: Vec<String> = self
            .servers
            .iter()
            .filter(|s| s.tools.is_ok())
            .map(|s| s.name.clone())
            .collect();
        if !started.is_empty() {
            look.abilities = imp_engine::troupe::ability_tags(&started);
        }
        look
    }

    /// The file of the agent: where the Imp is defined.
    pub fn agent_file(&self) -> Option<&Path> {
        self.loaded.agents.get(&self.name).map(|a| a.path.as_path())
    }

    /// Takes the configuration again when a file changed since it was last read (`Settings::stamp`, cheap
    /// enough to ask before every message), and says in one short sentence what is different now. None when
    /// nothing changed. A change that cannot be taken (the Imp is gone, the model has no service) is the
    /// error, once: the chat goes on with what it had.
    pub async fn sync(&mut self) -> Result<Option<String>> {
        let stamp = self.settings.stamp();
        if stamp == self.stamp {
            return Ok(None);
        }
        let before = Snapshot::of(self);
        if let Err(e) = self.reload().await {
            self.stamp = stamp;
            return Err(e);
        }
        Ok(Some(before.changes(&Snapshot::of(self))))
    }

    /// Reads the configuration again and rebuilds what changed: the model client, the system text, the
    /// rules, and the MCP servers when they are other ones.
    pub async fn reload(&mut self) -> Result<()> {
        let loaded = self.settings.load();
        let agent = settings::find_imp(&loaded, Some(&self.name))
            .map_err(|_| CliError(format!("{} is no longer there.", self.name)))?
            .value
            .clone();
        let resolved = resolve(&loaded.config, &loaded.auth, &agent, None).map_err(CliError)?;
        self.client = Rc::new(client_of(&loaded, &resolved)?);
        self.model = resolved.model.clone();
        self.model_label = resolved.reference();
        self.system = system_in(&loaded, &agent, &self.workspace);
        self.max_steps = settings::steps_of(&agent);
        self.waiting = settings::talk_of(&loaded).waiting;
        self.memory_exchanges = settings::memory_exchanges(&loaded, &agent.name);
        self.long_chat_tokens = settings::long_chat_tokens(&loaded, &agent.name);
        self.stamp = self.settings.stamp();
        self.resolved = resolved;
        self.agent = agent;
        self.loaded = loaded;
        let wanted = self.wanted_specs();
        if wanted == self.mcp_specs {
            self.update_gate();
            self.build_toolbox();
        } else {
            self.reconnect_tools().await?;
        }
        Ok(())
    }

    fn wanted_specs(&self) -> Vec<McpServerSpec> {
        let names = settings::servers_of(&self.loaded, &self.agent);
        mcp_specs(
            &self.loaded,
            &names,
            &self.workspace,
            self.settings.env.home_dir(),
        )
    }

    fn update_gate(&self) {
        self.gate.update(
            effective_rules(&self.loaded.config, &self.agent),
            self.loaded.config.mcp.keys().cloned().collect(),
        );
    }

    /// Starts the MCP servers again and rebuilds the tools.
    pub async fn reconnect_tools(&mut self) -> Result<()> {
        self.mcp.close().await;
        self.connect_tools().await;
        Ok(())
    }

    async fn connect_tools(&mut self) {
        let specs = self.wanted_specs();
        let sign_in: Rc<dyn imp_engine::McpSignIn> = Rc::new(crate::mcp_auth::ChatSignIn::new(
            self.settings.store.clone(),
            &self.loaded.config.mcp,
        ));
        let (mcp, problems) = McpHost::connect_with(&specs, MCP_TIMEOUT, Some(sign_in)).await;
        let mcp = Rc::new(mcp);
        let offered = imp_engine::ToolHost::tools(&*mcp);
        self.servers = specs
            .iter()
            .map(|spec| {
                let group = imp_engine::tools::mcp_group_id(&spec.name);
                let count = offered
                    .iter()
                    .filter(|t| t.entry.as_ref().is_some_and(|e| e.group == group))
                    .count();
                let problem = problems
                    .iter()
                    .find(|p| p.contains(&format!(" {} ", spec.name)));
                ServerStatus {
                    name: spec.name.clone(),
                    target: describe_endpoint(&spec.endpoint),
                    tools: match problem {
                        Some(p) => Err(p.clone()),
                        None => Ok(count),
                    },
                }
            })
            .collect();
        self.warnings = problems;
        self.warnings
            .extend(self.loaded.diagnostics.iter().map(ToString::to_string));
        self.notices = notices(&self.loaded);
        self.mcp = mcp;
        self.mcp_specs = specs;
        self.update_gate();
        self.build_toolbox();
    }

    /// Lets the Imp message the Imps on other devices (or not), keeping its MCP servers running.
    pub fn set_remote(&mut self, remote: Option<Rc<dyn Remote>>) {
        self.options.remote = remote;
        self.build_toolbox();
    }

    /// The tools: the MCP servers', the skills' and, with other Imps around, `imp_message`.
    fn build_toolbox(&mut self) {
        let mut toolbox = Toolbox::new();
        toolbox.add(self.mcp.clone());
        if let Some(skills) = SkillHost::new(&self.loaded.skills) {
            toolbox.add(Rc::new(skills));
        }
        if self.loaded.imps().count() > 1 || self.options.remote.is_some() {
            match self.settings.talks_dir() {
                Ok(dir) => {
                    let host =
                        ImpMessageHost::new(&self.name, self.loaded.clone(), TalkStore::new(dir))
                            .with_remote(self.look(), self.options.remote.clone())
                            .with_later(self.waiting, self.later.clone());
                    toolbox.add(Rc::new(host));
                }
                Err(e) => self
                    .warnings
                    .push(format!("Messaging other Imps is off. {e}")),
            }
        }
        self.toolbox = Rc::new(Gated {
            gate: self.gate.clone(),
            inner: Rc::new(toolbox),
        });
    }

    /// Every tool the Imp has, with whether its rules leave it on.
    pub fn tools(&self) -> Vec<ToolInfo> {
        use imp_engine::ToolHost;
        let offered: Vec<String> = self
            .toolbox
            .tools()
            .into_iter()
            .map(|t| t.spec.name)
            .collect();
        self.toolbox
            .inner
            .tools()
            .into_iter()
            .map(|t| ToolInfo {
                on: offered.contains(&t.spec.name),
                id: t.entry.map_or_else(|| t.spec.name.clone(), |e| e.id),
                name: t.spec.name,
            })
            .collect()
    }

    /// The client and model name for `model` (`provider/model#variant`) in place of the Imp's own, for one
    /// message.
    pub fn client_for(&self, model: &str) -> Result<(Rc<OpenAiClient>, String)> {
        let reference: imp_engine::config::ModelRef = model
            .parse()
            .map_err(|e: imp_engine::config::ModelRefError| CliError(e.to_string()))?;
        let resolved = resolve(
            &self.loaded.config,
            &self.loaded.auth,
            &self.agent,
            Some(&reference),
        )
        .map_err(CliError)?;
        Ok((
            Rc::new(client_of(&self.loaded, &resolved)?),
            resolved.model.clone(),
        ))
    }

    /// Gets ready to run a conversation of its own, a custom command with `subtask`: by this Imp, or by
    /// `agent` (opened for it and closed after), with `model` in place of the Imp's own. The rules and the
    /// questions are the Imp's.
    pub fn one_off(&self, agent: Option<String>, model: Option<String>) -> OneOff {
        OneOff {
            other: agent.filter(|a| !a.eq_ignore_ascii_case(&self.name)),
            settings: self.settings.clone(),
            options: self.options.clone(),
            mine: (self.client.clone(), self.model.clone()),
            model_here: model.as_deref().map(|m| self.client_for(m)),
            model,
            toolbox: self.toolbox.clone(),
            system: self.system.clone(),
            steps: self.max_steps,
        }
    }

    /// The shell and the files of this computer behind this Imp's rules, for what a custom command reads.
    pub fn world(&self) -> crate::custom::Local {
        crate::custom::Local {
            gate: self.gate.clone(),
            workspace: self.workspace.clone(),
            home: self.settings.env.home_dir().map(Path::to_path_buf),
        }
    }

    /// A new chat with this Imp.
    pub fn new_chat(&self) -> ChatState {
        let mut chat = ChatState::new(self.system.clone());
        chat.set_exchanges(self.memory_exchanges);
        chat
    }

    /// A chat with this Imp that goes on from `messages`.
    pub fn chat_from(&self, messages: Vec<ChatMessage>) -> ChatState {
        let mut chat = ChatState::from_messages(self.system.clone(), messages);
        chat.set_exchanges(self.memory_exchanges);
        chat
    }

    /// Has the model sum up what it remembers of a chat, as the apps do, so the chat can go on with
    /// the summary in place of its history. The request is the core's.
    pub async fn recap(&self, memory: &ChatMemory) -> Result<String> {
        let mut messages: Vec<ChatMessage> = memory
            .recap_request(&self.name)
            .iter()
            .map(ChatMessage::from)
            .collect();
        imp_engine::run_agent(
            &self.client,
            &self.model,
            &mut messages,
            &Toolbox::new(),
            &ToolSelection::all(),
            1,
            |_| {},
        )
        .await
        .map_err(|e| CliError(format!("The chat could not be summed up: {e}")))
    }

    /// Ends the sessions of the MCP servers.
    pub async fn close(&self) {
        self.mcp.close().await;
    }
}

/// A conversation of its own, ready to run (see [`Session::one_off`]). It owns what it needs, so it can run
/// while the chat goes on being drawn.
pub struct OneOff {
    other: Option<String>,
    settings: Settings,
    options: SessionOptions,
    mine: (Rc<OpenAiClient>, String),
    model: Option<String>,
    model_here: Option<Result<(Rc<OpenAiClient>, String)>>,
    toolbox: Rc<Gated>,
    system: String,
    steps: usize,
}

impl OneOff {
    /// Sends `text` and gives the answer. Nothing of the conversation is kept.
    pub async fn run(self, text: &str) -> std::result::Result<String, String> {
        let opened = match &self.other {
            Some(other) => Some(
                Session::open(&self.settings, Some(other), self.options.clone())
                    .await
                    .map_err(|e| e.0)?,
            ),
            None => None,
        };
        let answer = self.ask(opened.as_ref(), text).await;
        if let Some(opened) = opened {
            opened.close().await;
        }
        answer
    }

    async fn ask(
        &self,
        opened: Option<&Session>,
        text: &str,
    ) -> std::result::Result<String, String> {
        let ((client, name), toolbox, system, steps) = match (opened, &self.model) {
            (Some(s), Some(m)) => (
                s.client_for(m).map_err(|e| e.0)?,
                s.toolbox.clone(),
                s.system.clone(),
                s.max_steps,
            ),
            (Some(s), None) => (
                (s.client.clone(), s.model.clone()),
                s.toolbox.clone(),
                s.system.clone(),
                s.max_steps,
            ),
            (None, _) => (
                match &self.model_here {
                    Some(Ok(over)) => over.clone(),
                    Some(Err(e)) => return Err(e.0.clone()),
                    None => self.mine.clone(),
                },
                self.toolbox.clone(),
                self.system.clone(),
                self.steps,
            ),
        };
        let mut chat = ChatState::new(system);
        chat.push_user(text);
        let mut messages = chat.request_messages();
        imp_engine::run_agent(
            &client,
            &name,
            &mut messages,
            &*toolbox,
            &ToolSelection::all(),
            steps,
            |_| {},
        )
        .await
        .map_err(|e| e.to_string())
    }
}

/// What a person would notice changing in a session, to say it when another app changed the files.
struct Snapshot {
    model: String,
    imps: Vec<String>,
    services: Vec<String>,
    servers: Vec<String>,
    rules: usize,
    skills: Vec<String>,
    commands: Vec<String>,
    trusted: bool,
}

impl Snapshot {
    fn of(s: &Session) -> Self {
        let keys = |names: Vec<String>| {
            let mut names = names;
            names.sort();
            names
        };
        Self {
            model: s.model_label.clone(),
            imps: keys(s.loaded.imps().map(|a| a.value.name.clone()).collect()),
            services: keys(
                s.loaded
                    .config
                    .providers
                    .keys()
                    .cloned()
                    .chain(s.loaded.auth.providers.keys().map(|k| format!("{k} key")))
                    .collect(),
            ),
            servers: keys(s.loaded.config.mcp.keys().cloned().collect()),
            rules: effective_rules(&s.loaded.config, &s.agent).len(),
            skills: keys(s.loaded.skills.keys().cloned().collect()),
            commands: keys(s.loaded.commands.keys().cloned().collect()),
            trusted: s.loaded.project.as_ref().is_some_and(|p| p.trusted),
        }
    }

    /// `Settings changed: model is now x, tool servers, permissions.`
    fn changes(&self, now: &Self) -> String {
        let mut what = Vec::new();
        if self.model != now.model {
            what.push(format!("model is now {}", now.model));
        }
        if self.imps != now.imps {
            what.push("Imps".to_string());
        }
        if self.services != now.services {
            what.push("services or keys".to_string());
        }
        if self.servers != now.servers {
            what.push("tool servers".to_string());
        }
        if self.rules != now.rules {
            what.push("permissions".to_string());
        }
        if self.skills != now.skills {
            what.push("skills".to_string());
        }
        if self.commands != now.commands {
            what.push("commands".to_string());
        }
        if self.trusted != now.trusted {
            what.push(
                if now.trusted {
                    "this folder is trusted"
                } else {
                    "this folder is not trusted"
                }
                .to_string(),
            );
        }
        if what.is_empty() {
            "Settings changed.".to_string()
        } else {
            format!("Settings changed: {}.", what.join(", "))
        }
    }
}

/// The client for a resolved model: its address and key, the retry rule, and the request's own headers
/// and body fields.
pub fn client_of(loaded: &Loaded, resolved: &Resolved) -> Result<OpenAiClient> {
    Ok(OpenAiClient::new(
        &resolved.base_url,
        resolved.api_key.clone(),
        settings::retry_policy(loaded),
    )?
    .with_request(resolved.headers.clone(), resolved.body.clone()))
}

/// Plain sentences about what the folder asks for.
fn notices(loaded: &Loaded) -> Vec<String> {
    let mut out = Vec::new();
    if let Some(project) = &loaded.project
        && project.digest.is_some()
        && !project.trusted
    {
        let files: Vec<String> = project.config_files.iter().map(|f| shown_path(f)).collect();
        out.push(format!(
            "{} wants to add services, tool servers or permissions. They wait until you trust this folder: /project trust.",
            files.join(", ")
        ));
    }
    out
}

/// A server in a few words: its command line or its address.
pub fn describe_endpoint(endpoint: &McpEndpoint) -> String {
    match endpoint {
        McpEndpoint::Http { url, .. } => url.clone(),
        McpEndpoint::Command { command, args, .. } => std::iter::once(command.as_str())
            .chain(args.iter().map(String::as_str))
            .collect::<Vec<_>>()
            .join(" "),
    }
}
