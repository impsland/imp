//! An Imp ready to chat: its settings, its model client, its MCP servers and its tools.
//!
//! A session can change while the chat runs (`/model`, `/base_url`, `/api_key`, `/mcp` ...). Each change is
//! saved to the settings file first, then only the part it touches is rebuilt: the client for an address or
//! a key, the tools for an MCP server.

use crate::config::{Config, ImpConfig, McpServerConfig, valid_env_name};
use crate::keys::{self, KeySource};
use crate::troupe::{ImpMessageHost, Remote};
use crate::{CliError, Result};
use imp_core::link::{LinkImp, LinkTraits};
use imp_core::{
    McpEndpoint, McpHost, McpServerSpec, OpenAiClient, RequestLimits, TalkStore, ToolHost,
    ToolSelection, Toolbox,
};
use std::path::{Path, PathBuf};
use std::rc::Rc;
use std::time::Duration;
use uuid::Uuid;

/// How long an MCP server may take to start and to answer one request.
const MCP_TIMEOUT: Duration = Duration::from_secs(60);

/// What the model is told it is.
pub fn system_prompt(name: &str, imp: &ImpConfig) -> String {
    format!(
        "You are {name}, an Imp: a small character that lives on the person's computer and chats with them. {}",
        imp.personality
    )
}

/// What the model is told in a chat: what it is, and the folder the chat was started in (`workspace`).
fn system_prompt_in(name: &str, imp: &ImpConfig, workspace: &Path) -> String {
    format!(
        "{}\n\nThe person started this chat in the folder {}. When they talk about files or \"this folder\", they mean that one. Tools that take a path want it inside that folder, written in full.",
        system_prompt(name, imp),
        workspace.display()
    )
}

/// Replaces `${workspaceFolder}` and `${cwd}` with the folder the chat was started in, and a leading `~/`
/// with the home folder, so one settings file works in every folder.
pub fn expand(arg: &str, workspace: &Path) -> String {
    let folder = workspace.display().to_string();
    let mut out = arg
        .replace("${workspaceFolder}", &folder)
        .replace("${cwd}", &folder);
    if let Some(rest) = out.strip_prefix("~/")
        && let Some(home) = directories::BaseDirs::new()
    {
        out = home.home_dir().join(rest).display().to_string();
    }
    out
}

/// The MCP servers of an Imp as ways to reach them. Values of the listed environment variables
/// and headers are read now and passed on. They are never stored. A header's value comes from the
/// environment variable named by `keys::header_env`, or else from the key store.
pub fn mcp_specs(
    imp: &ImpConfig,
    env: impl Fn(&str) -> Option<String>,
    keychain: impl Fn(&str) -> Option<String>,
) -> Vec<McpServerSpec> {
    mcp_specs_in(imp, Path::new("."), env, keychain)
}

/// Like [`mcp_specs`], with the placeholders of [`expand`] filled in for `workspace`.
pub fn mcp_specs_in(
    imp: &ImpConfig,
    workspace: &Path,
    env: impl Fn(&str) -> Option<String>,
    keychain: impl Fn(&str) -> Option<String>,
) -> Vec<McpServerSpec> {
    imp.mcp_servers
        .iter()
        .filter_map(|(name, server)| {
            Some(McpServerSpec {
                name: name.clone(),
                endpoint: endpoint(name, server, workspace, &env, &keychain)?,
            })
        })
        .collect()
}

fn endpoint(
    name: &str,
    server: &McpServerConfig,
    workspace: &Path,
    env: &impl Fn(&str) -> Option<String>,
    keychain: &impl Fn(&str) -> Option<String>,
) -> Option<McpEndpoint> {
    if let Some(url) = &server.url {
        return Some(McpEndpoint::Http {
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
        });
    }
    Some(McpEndpoint::Command {
        command: expand(server.command.as_deref()?, workspace),
        args: server.args.iter().map(|a| expand(a, workspace)).collect(),
        env: server
            .env
            .iter()
            .filter(|n| valid_env_name(n))
            .filter_map(|n| env(n).map(|v| (n.clone(), v)))
            .collect::<Vec<_>>()
            .into(),
    })
}

/// The folder for saved data: `IMP_DATA_DIR`, or the usual data folder for `imp`.
pub fn data_dir() -> Result<PathBuf> {
    if let Some(dir) = keys::real_env("IMP_DATA_DIR").filter(|d| !d.trim().is_empty()) {
        return Ok(PathBuf::from(dir));
    }
    directories::ProjectDirs::from("", "", "imp")
        .map(|d| d.data_dir().to_path_buf())
        .ok_or_else(|| CliError("Could not find a folder for data. Set IMP_DATA_DIR.".into()))
}

/// The folder for the conversations between Imps.
pub fn talks_dir() -> Result<PathBuf> {
    data_dir().map(|d| d.join("talks"))
}

/// What a session is opened with, apart from the settings file.
#[derive(Clone, Default)]
pub struct SessionOptions {
    /// The folder the chat was started in. The current folder if left out.
    pub workspace: Option<PathBuf>,
    /// Imps on other devices this Imp can message.
    pub remote: Option<Rc<dyn Remote>>,
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
    pub path: PathBuf,
    pub name: String,
    pub imp: ImpConfig,
    pub model: String,
    pub client: Rc<OpenAiClient>,
    pub system: String,
    pub toolbox: Rc<Toolbox>,
    /// The MCP servers behind the toolbox, to end their sessions when the chat ends.
    pub mcp: Rc<McpHost>,
    pub servers: Vec<ServerStatus>,
    pub selection: ToolSelection,
    pub max_steps: usize,
    /// Plain sentences about things that did not start, such as an MCP server.
    pub warnings: Vec<String>,
    pub workspace: PathBuf,
    /// Where the API key came from. None: no key (fine for a local model).
    pub key_source: Option<KeySource>,
    /// A key given in the chat, used before the others until the chat ends.
    key_override: Option<String>,
    options: SessionOptions,
}

impl Session {
    pub async fn open(path: &Path, name: Option<&str>, options: SessionOptions) -> Result<Self> {
        let config = Config::load_with_ids(path)?;
        let (name, imp) = config.pick_imp(name)?;
        let workspace = match &options.workspace {
            Some(w) => w.clone(),
            None => std::env::current_dir()?,
        };
        let mut session = Self {
            path: path.to_path_buf(),
            name: name.to_string(),
            imp: imp.clone(),
            model: imp.model.clone(),
            client: Rc::new(OpenAiClient::new(&imp.base_url, None, policy(&config))?),
            system: system_prompt_in(name, imp, &workspace),
            toolbox: Rc::new(Toolbox::new()),
            mcp: Rc::new(McpHost::connect(&[], MCP_TIMEOUT).await.0),
            servers: Vec::new(),
            selection: ToolSelection::all(),
            max_steps: config.max_steps,
            warnings: Vec::new(),
            workspace,
            key_source: None,
            key_override: None,
            options,
        };
        session.rebuild_client(&config)?;
        session.connect_tools(&config).await;
        Ok(session)
    }

    /// The settings file as it is now.
    pub fn config(&self) -> Result<Config> {
        Config::load_with_ids(&self.path)
    }

    /// How other devices see this Imp.
    pub fn look(&self) -> LinkImp {
        look_of(&self.name, &self.imp)
    }

    /// Changes one of the Imp's settings, saves the file and rebuilds what it touches.
    pub async fn set(&mut self, key: &str, value: &str) -> Result<()> {
        let mut config = self.config()?;
        let imp = config
            .imps
            .get_mut(&self.name)
            .ok_or_else(|| CliError(format!("{} is no longer in the settings file.", self.name)))?;
        imp.set(key, value)?;
        config.save(&self.path)?;
        self.reload(&config)
    }

    /// Uses `key` as the API key until the chat ends. None goes back to the usual places.
    pub fn use_key(&mut self, key: Option<String>) -> Result<()> {
        self.key_override = key.filter(|k| !k.trim().is_empty());
        let config = self.config()?;
        self.rebuild_client(&config)
    }

    /// Takes the Imp's settings from `config` again: the model, the address, the personality.
    pub fn reload(&mut self, config: &Config) -> Result<()> {
        let imp = config
            .imps
            .get(&self.name)
            .ok_or_else(|| CliError(format!("{} is no longer in the settings file.", self.name)))?;
        self.imp = imp.clone();
        self.model = imp.model.clone();
        self.system = system_prompt_in(&self.name, imp, &self.workspace);
        self.max_steps = config.max_steps;
        self.selection = ToolSelection {
            tools_off: imp.tools_off.iter().cloned().collect(),
            ..ToolSelection::all()
        };
        self.rebuild_client(config)
    }

    fn rebuild_client(&mut self, config: &Config) -> Result<()> {
        let (key, source) = match &self.key_override {
            Some(key) => (Some(key.clone()), Some(KeySource::Chat)),
            None => match keys::find(
                config,
                &self.name,
                &self.imp,
                keys::real_env,
                keys::real_keychain,
            ) {
                Some(found) => (Some(found.key), Some(found.source)),
                None => (None, None),
            },
        };
        self.client = Rc::new(OpenAiClient::new(&self.imp.base_url, key, policy(config))?);
        self.key_source = source;
        Ok(())
    }

    /// Starts the MCP servers again (after one was added or removed) and rebuilds the tools.
    pub async fn reconnect_tools(&mut self) -> Result<()> {
        let config = self.config()?;
        self.reload(&config)?;
        self.mcp.close().await;
        self.connect_tools(&config).await;
        Ok(())
    }

    async fn connect_tools(&mut self, config: &Config) {
        let specs = mcp_specs_in(
            &self.imp,
            &self.workspace,
            keys::real_env,
            keys::real_keychain,
        );
        let (mcp, problems) = McpHost::connect(&specs, MCP_TIMEOUT).await;
        let mcp = Rc::new(mcp);
        let offered = mcp.tools();
        self.servers = self
            .imp
            .mcp_servers
            .iter()
            .map(|(name, server)| {
                let group = imp_core::tools::mcp_group_id(name);
                let count = offered
                    .iter()
                    .filter(|t| t.entry.as_ref().is_some_and(|e| e.group == group))
                    .count();
                let problem = problems.iter().find(|p| p.contains(&format!(" {name} ")));
                ServerStatus {
                    name: name.clone(),
                    target: describe_server(server),
                    tools: match problem {
                        Some(p) => Err(p.clone()),
                        None => Ok(count),
                    },
                }
            })
            .collect();
        self.warnings = problems;
        self.mcp = mcp;
        self.build_toolbox(config);
    }

    /// Lets the Imp message the Imps on other devices (or not), keeping its MCP servers running.
    pub fn set_remote(&mut self, remote: Option<Rc<dyn Remote>>) {
        self.options.remote = remote;
        if let Ok(config) = self.config() {
            self.build_toolbox(&config);
        }
    }

    /// The tools: the MCP servers' and, with other Imps around, `imp_message`.
    fn build_toolbox(&mut self, config: &Config) {
        let mut toolbox = Toolbox::new();
        toolbox.add(self.mcp.clone());
        if config.imps.len() > 1 || self.options.remote.is_some() {
            match talks_dir() {
                Ok(dir) => {
                    let global = config.clone();
                    let host = ImpMessageHost::new(
                        &self.name,
                        config.clone(),
                        TalkStore::new(dir),
                        Box::new(move |n, i| {
                            keys::find(&global, n, i, keys::real_env, keys::real_keychain)
                                .map(|k| k.key)
                        }),
                    )
                    .with_remote(self.look(), self.options.remote.clone());
                    toolbox.add(Rc::new(host));
                }
                Err(e) => self
                    .warnings
                    .push(format!("Messaging other Imps is off. {e}")),
            }
        }
        self.toolbox = Rc::new(toolbox);
        self.selection = ToolSelection {
            tools_off: self.imp.tools_off.iter().cloned().collect(),
            ..ToolSelection::all()
        };
    }

    /// Every tool the Imp has, with whether it is on.
    pub fn tools(&self) -> Vec<ToolInfo> {
        self.toolbox
            .tools()
            .into_iter()
            .map(|t| ToolInfo {
                on: self.selection.allows(t.entry.as_ref()),
                id: t.entry.map_or_else(|| t.spec.name.clone(), |e| e.id),
                name: t.spec.name,
            })
            .collect()
    }

    /// Ends the sessions of the MCP servers.
    pub async fn close(&self) {
        self.mcp.close().await;
    }
}

/// How other devices see an Imp of this computer.
pub fn look_of(name: &str, imp: &ImpConfig) -> LinkImp {
    LinkImp {
        id: imp.id.unwrap_or_else(Uuid::nil),
        name: name.to_string(),
        hue: imp.hue_for(name),
        scale: 1.0,
        traits: LinkTraits::default(),
    }
}

/// A server in a few words: its command line or its address.
pub fn describe_server(server: &McpServerConfig) -> String {
    match (&server.command, &server.url) {
        (_, Some(url)) => url.clone(),
        (Some(command), None) => std::iter::once(command.as_str())
            .chain(server.args.iter().map(String::as_str))
            .collect::<Vec<_>>()
            .join(" "),
        (None, None) => String::new(),
    }
}

fn policy(config: &Config) -> imp_core::RetryPolicy {
    RequestLimits {
        retries: i64::from(config.retries),
        ..RequestLimits::default()
    }
    .policy()
}
