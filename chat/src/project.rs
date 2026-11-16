//! What a folder tells its Imps, in the shared `.agents/` layout that other coding agents read too:
//!
//! - `AGENTS.md` (in the project's folders, and `.agents/AGENTS.md`): standing instructions. They go in
//!   the system text, after who the Imp is, so they hold for the whole chat and survive `/clear`.
//! - `.agents/skills/NAME/SKILL.md`: skills. Only each one's name and description go in the system text.
//!   The tool `use_skill` reads the whole file when a task needs it, so many skills cost few words.
//! - `.agents/agents/NAME.md`: the Imp NAME in this folder. Its front matter can set `model`, `base_url`,
//!   `api_key_env` (or `api_key: ${NAME}`), `tools`, `disallowedTools`, `hue` and `default`, and the text
//!   under it is how the Imp behaves. One file is enough for a whole Imp. What it leaves out comes from
//!   the default Imp of the settings file.
//! - `.agents/mcp.json`: MCP servers for every Imp in this folder, in the usual `mcpServers` format.
//!
//! The project is the nearest folder, from the chat's folder up, with a `.agents` folder or a `.git`. The
//! same layout in the home folder (`~/.agents/`) is the person's own, read for every chat and trusted.
//!
//! A downloaded project could start programs (MCP servers) or send an API key to its own address
//! (`base_url` with `api_key_env`). So a project's servers and service settings wait until the person
//! allows them with `/project trust`, and wait again when they change. A key itself is never written in
//! these files, only the name of the environment variable that holds it.
//!
//! The rules of the files (front matter, agent and skill files, `mcp.json`, the system text, the trust
//! digest) are in `imp_engine::agents` and `imp_engine::mcp::setup`, shared with the apps. This module
//! finds the folders, reads the files, remembers what was trusted and fits the Imps into the settings.

use crate::config::{Config, DEFAULT_PERSONALITY, DEFAULT_URL, ImpConfig, valid_imp_name};
use crate::session::expand;
use crate::{CliError, Result};
use imp_engine::agents::{
    self, AgentSpec, Instructions, LeftOut, MOST_INSTRUCTIONS, MOST_SKILLS, SKILL_GROUP, SkillSpec,
};
use imp_engine::mcp::setup::{self, SetupServer};
use imp_engine::{BoxFuture, HostTool, McpEndpoint, McpServerSpec, ToolEntry, ToolHost};
use serde_json::Value;
use sha2::{Digest, Sha256};
use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use uuid::Uuid;

pub use imp_engine::agents::SKILL_TOOL;

/// One `AGENTS.md` file.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Doc {
    pub path: PathBuf,
    pub text: String,
}

/// One skill: its name and when to use it, and its file. The file is read when the Imp asks for it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Skill {
    pub spec: SkillSpec,
    /// The `SKILL.md` file.
    pub path: PathBuf,
}

/// An Imp as `.agents/agents/NAME.md` describes it, and where the file is.
#[derive(Debug, Clone, PartialEq)]
pub struct AgentFile {
    pub path: PathBuf,
    pub spec: AgentSpec,
    /// In the home folder: the person's own, always trusted.
    pub own: bool,
}

/// An `mcp.json` file and whether its servers may start.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct McpFile {
    pub path: PathBuf,
    pub servers: BTreeMap<String, SetupServer>,
    /// The person's own file (in the home folder), or one of a project they trusted as it is now.
    pub trusted: bool,
    /// In the home folder: always trusted.
    pub own: bool,
}

/// Everything the folder of a chat adds to its Imps.
#[derive(Debug, Clone, PartialEq, Default)]
pub struct Project {
    /// The project's folder: where its `.agents` is, or would be.
    pub root: PathBuf,
    /// `AGENTS.md` files, the person's own first, then from the project's folder down to the chat's.
    pub instructions: Vec<Doc>,
    pub skills: Vec<Skill>,
    pub agents: BTreeMap<String, AgentFile>,
    /// The person's own servers, then the project's.
    pub mcp: Vec<McpFile>,
    /// What needs the person's trust (the project's servers and service settings), as a digest, if
    /// anything does. What changed after it was trusted waits to be trusted again.
    pub trust_digest: Option<String>,
    /// The person allowed it as it is now.
    pub trusted: bool,
    /// Plain sentences about files that could not be used.
    pub problems: Vec<String>,
}

impl Project {
    /// Reads the project of `workspace`, with `home` for `~/.agents` and `trust` for the folders the
    /// person allowed.
    pub fn load(workspace: &Path, home: Option<&Path>, trust: &TrustStore) -> Self {
        let root = project_root(workspace, home);
        let mut project = Self {
            root: root.clone(),
            ..Self::default()
        };
        let own = home
            .map(|h| h.join(".agents"))
            .filter(|d| d.is_dir() && *d != root.join(".agents"));
        let here = root.join(".agents");
        let mut docs: Vec<PathBuf> = Vec::new();
        if let Some(own) = &own {
            docs.push(own.join("AGENTS.md"));
        }
        for dir in folders_down(&root, workspace) {
            docs.push(dir.join("AGENTS.md"));
            if dir == root {
                docs.push(here.join("AGENTS.md"));
            }
        }
        project.read_instructions(&docs);
        if let Some(own) = &own {
            project.read_skills(&own.join("skills"));
            project.read_agents(&own.join("agents"), true);
        }
        project.read_skills(&here.join("skills"));
        project.read_agents(&here.join("agents"), false);
        if let Some(own) = &own {
            project.read_mcp(&own.join("mcp.json"), true);
        }
        let config_text = project.read_mcp(&here.join("mcp.json"), false);
        let asking: Vec<&AgentSpec> = project
            .agents
            .values()
            .filter(|a| !a.own)
            .map(|a| &a.spec)
            .collect();
        project.trust_digest = agents::trust_digest(config_text.as_deref(), &asking);
        project.trusted = project
            .trust_digest
            .as_deref()
            .is_some_and(|d| trust.allows(&project.root, d));
        let trusted = project.trusted;
        for file in &mut project.mcp {
            file.trusted = file.own || trusted;
        }
        project.skills.sort_by(|a, b| a.spec.name.cmp(&b.spec.name));
        project
    }

    /// Reads the project of `workspace` with saved trust, and `home` (the person's home folder if
    /// left out) for their own `.agents/`.
    pub fn load_here(workspace: &Path, home: Option<&Path>) -> Self {
        let found = directories::BaseDirs::new().map(|b| b.home_dir().to_path_buf());
        let home = home.or(found.as_deref());
        Self::load(workspace, home, &TrustStore::default_store())
    }

    /// The project's Imps whose service settings need the person's trust.
    pub fn waiting_agents(&self) -> impl Iterator<Item = &AgentFile> {
        self.agents
            .values()
            .filter(|a| !a.own && a.spec.needs_trust())
    }

    /// Whether the folder adds anything at all.
    pub fn is_empty(&self) -> bool {
        self.instructions.is_empty()
            && self.skills.is_empty()
            && self.agents.is_empty()
            && self.mcp.is_empty()
    }

    fn read_instructions(&mut self, paths: &[PathBuf]) {
        let mut seen: Vec<PathBuf> = Vec::new();
        let mut found: Vec<(PathBuf, Instructions)> = Vec::new();
        for path in paths {
            let Ok(real) = path.canonicalize() else {
                continue;
            };
            if seen.contains(&real) {
                continue;
            }
            seen.push(real);
            if let Ok(text) = std::fs::read_to_string(path) {
                let label = shown_path(path);
                found.push((path.clone(), Instructions { label, text }));
            }
        }
        let paths: BTreeMap<String, PathBuf> = found
            .iter()
            .map(|(p, d)| (d.label.clone(), p.clone()))
            .collect();
        let (kept, left) = agents::fit_instructions(found.into_iter().map(|(_, d)| d).collect());
        let most = MOST_INSTRUCTIONS / 1024;
        for out in left {
            self.problems.push(match out {
                LeftOut::Cut(label) => format!(
                    "{label} was cut short: the AGENTS.md files are longer than {most} KB together."
                ),
                LeftOut::Dropped(label) => format!(
                    "{label} was left out: the AGENTS.md files are longer than {most} KB together."
                ),
            });
        }
        self.instructions = kept
            .into_iter()
            .map(|d| Doc {
                path: paths.get(&d.label).cloned().unwrap_or_default(),
                text: d.text,
            })
            .collect();
    }

    fn read_skills(&mut self, dir: &Path) {
        for folder in sorted_entries(dir).into_iter().filter(|p| p.is_dir()) {
            let path = folder.join("SKILL.md");
            let Ok(text) = std::fs::read_to_string(&path) else {
                continue;
            };
            let folder_name = folder
                .file_name()
                .map(|n| n.to_string_lossy().to_string())
                .unwrap_or_default();
            let spec = match SkillSpec::parse(&folder_name, &text) {
                Ok(spec) => spec,
                Err(why) => {
                    self.problems
                        .push(format!("The skill {}: {why}", path.display()));
                    continue;
                }
            };
            // The project's skill replaces the person's own of the same name.
            self.skills.retain(|s| s.spec.name != spec.name);
            if self.skills.len() >= MOST_SKILLS {
                self.problems.push(format!(
                    "Only the first {MOST_SKILLS} skills are offered. {} is left out.",
                    spec.name
                ));
                continue;
            }
            self.skills.push(Skill { spec, path });
        }
    }

    fn read_agents(&mut self, dir: &Path, own: bool) {
        for path in sorted_entries(dir) {
            if path.extension().and_then(|e| e.to_str()) != Some("md") {
                continue;
            }
            let Ok(text) = std::fs::read_to_string(&path) else {
                continue;
            };
            let stem = path
                .file_stem()
                .map(|n| n.to_string_lossy().to_string())
                .unwrap_or_default();
            match AgentSpec::parse(&stem, &text) {
                Ok(spec) if valid_imp_name(&spec.name) => {
                    self.agents
                        .insert(spec.name.clone(), AgentFile { path, spec, own });
                }
                Ok(spec) => self.problems.push(format!(
                    "{}: the Imp name {:?} is not allowed. Use 1 to 32 letters, digits, - and _.",
                    path.display(),
                    spec.name
                )),
                Err(why) => self.problems.push(format!("{}: {why}", path.display())),
            }
        }
    }

    /// Reads an `mcp.json`. Returns its text when it has servers, for the trust digest.
    fn read_mcp(&mut self, path: &Path, own: bool) -> Option<String> {
        let text = std::fs::read_to_string(path).ok()?;
        let servers = match setup::parse_config_file(&text).and_then(checked_servers) {
            Ok(servers) => servers,
            Err(why) => {
                self.problems
                    .push(format!("{} is not valid: {why}", path.display()));
                return None;
            }
        };
        if servers.is_empty() {
            return None;
        }
        self.mcp.push(McpFile {
            path: path.to_path_buf(),
            servers,
            trusted: own,
            own,
        });
        Some(text)
    }

    /// The project's own `mcp.json`, if it has one.
    pub fn project_mcp(&self) -> Option<&McpFile> {
        self.mcp.iter().find(|m| !m.own)
    }

    /// The servers that may start, by name. A name that comes twice keeps the first.
    pub fn trusted_servers(&self) -> Vec<(&str, &SetupServer, &McpFile)> {
        let mut out: Vec<(&str, &SetupServer, &McpFile)> = Vec::new();
        for file in self.mcp.iter().filter(|f| f.trusted) {
            for (name, server) in &file.servers {
                if !out.iter().any(|(n, _, _)| n == name) {
                    out.push((name, server, file));
                }
            }
        }
        out
    }

    /// What waits for `/project trust`, in plain words, or nothing.
    pub fn waiting(&self) -> Vec<String> {
        if self.trusted {
            return Vec::new();
        }
        let mut out: Vec<String> = self
            .mcp
            .iter()
            .filter(|f| !f.trusted)
            .map(|f| {
                let names: Vec<&str> = f.servers.keys().map(String::as_str).collect();
                format!(
                    "the MCP servers of {} ({}), which run programs on this computer",
                    shown_path(&f.path),
                    names.join(", ")
                )
            })
            .collect();
        for agent in self.waiting_agents() {
            let spec = &agent.spec;
            let at = spec
                .base_url
                .as_deref()
                .map_or(String::new(), |u| format!(" at {u}"));
            let key = spec
                .api_key_env
                .as_deref()
                .map_or(String::new(), |k| format!(" with the key in {k}"));
            out.push(format!(
                "{}'s service{at}{key} ({})",
                spec.name,
                shown_path(&agent.path)
            ));
        }
        out
    }

    /// Sentences for the start of a chat: what waits for `/project trust`.
    pub fn notices(&self) -> Vec<String> {
        let waiting = self.waiting();
        if waiting.is_empty() {
            return Vec::new();
        }
        vec![format!(
            "This folder asks for {}. Nothing of that is used until you allow it: /project trust.",
            waiting.join(", and ")
        )]
    }

    /// Puts this folder's Imps in `config`: an Imp in the settings file takes the file's settings, and an
    /// Imp that is only in the folder is made from the default Imp's service. Doing it twice changes nothing.
    pub fn apply(&self, config: &mut Config) {
        let template = config.pick_imp(None).ok().map(|(_, imp)| imp.clone());
        if let Some(agent) = self.agents.values().find(|a| a.spec.default) {
            config.default_imp = Some(agent.spec.name.clone());
        }
        for (name, agent) in &self.agents {
            let spec = &agent.spec;
            let imp = config.imps.entry(name.clone()).or_insert_with(|| {
                let mut imp = template.clone().unwrap_or_else(|| {
                    ImpConfig::new(
                        DEFAULT_PERSONALITY.into(),
                        DEFAULT_URL.into(),
                        String::new(),
                    )
                });
                imp.id = Some(folder_imp_id(&self.root, name));
                imp.hue = None;
                imp.personality = DEFAULT_PERSONALITY.into();
                imp.description = None;
                imp.mcp_servers.clear();
                imp.tools_off.clear();
                imp
            });
            if let Some(model) = &spec.model {
                imp.model.clone_from(model);
            }
            if let Some(personality) = &spec.personality {
                imp.personality.clone_from(personality);
            }
            if spec.description.is_some() {
                imp.description.clone_from(&spec.description);
            }
            if spec.hue.is_some() {
                imp.hue = spec.hue;
            }
            if agent.own || self.trusted {
                if let Some(url) = &spec.base_url {
                    imp.base_url.clone_from(url);
                }
                if spec.api_key_env.is_some() {
                    imp.api_key_env.clone_from(&spec.api_key_env);
                }
            }
            for off in &spec.tools_off {
                if !imp.tools_off.contains(off) {
                    imp.tools_off.push(off.clone());
                }
            }
        }
    }

    /// The file that sets `name`'s `key` setting in this folder, so a change in the settings file would not show.
    pub fn sets(&self, name: &str, key: &str) -> Option<&Path> {
        let agent = self.agents.get(name)?;
        agent.spec.sets(key).then_some(agent.path.as_path())
    }

    /// What goes after who the Imp is in the system text: the instructions and the list of skills.
    pub fn prompt(&self) -> String {
        let docs: Vec<Instructions> = self
            .instructions
            .iter()
            .map(|d| Instructions {
                label: shown_path(&d.path),
                text: d.text.clone(),
            })
            .collect();
        let skills: Vec<SkillSpec> = self.skills.iter().map(|s| s.spec.clone()).collect();
        agents::prompt(&docs, &skills)
    }

    /// The tool that reads a skill, when there are any.
    pub fn skill_host(&self) -> Option<SkillHost> {
        (!self.skills.is_empty()).then(|| SkillHost {
            skills: self.skills.clone(),
        })
    }
}

/// The servers of a config file keyed by name, with names and variables the settings file allows.
fn checked_servers(
    servers: Vec<SetupServer>,
) -> std::result::Result<BTreeMap<String, SetupServer>, String> {
    let mut out = BTreeMap::new();
    for server in servers {
        if !valid_imp_name(&server.name) {
            return Err(format!(
                "the server name {:?} is not allowed: use 1 to 32 letters, digits, - and _.",
                server.name
            ));
        }
        if server.env.keys().any(|k| !agents::valid_env_name(k)) {
            return Err(format!(
                "{} has an environment variable name that is not allowed.",
                server.name
            ));
        }
        out.insert(server.name.clone(), server);
    }
    Ok(out)
}

/// The nearest folder from `workspace` up (and below `home`) with a `.agents` folder or a `.git`, or
/// `workspace` itself.
fn project_root(workspace: &Path, home: Option<&Path>) -> PathBuf {
    for dir in workspace.ancestors() {
        if home.is_some_and(|h| dir == h) {
            break;
        }
        if dir.join(".agents").is_dir() || dir.join(".git").exists() {
            return dir.to_path_buf();
        }
    }
    workspace.to_path_buf()
}

/// The folders from `root` down to `workspace`, both included. Just `workspace` if it is not inside `root`.
fn folders_down(root: &Path, workspace: &Path) -> Vec<PathBuf> {
    let Ok(rest) = workspace.strip_prefix(root) else {
        return vec![workspace.to_path_buf()];
    };
    let mut out = vec![root.to_path_buf()];
    let mut at = root.to_path_buf();
    for part in rest.components() {
        at.push(part);
        out.push(at.clone());
    }
    out
}

/// The entries of a folder, by name. None for a folder that is not there.
fn sorted_entries(dir: &Path) -> Vec<PathBuf> {
    let Ok(read) = std::fs::read_dir(dir) else {
        return Vec::new();
    };
    let mut out: Vec<PathBuf> = read.filter_map(|e| e.ok().map(|e| e.path())).collect();
    out.sort();
    out
}

/// A custom command: `.agents/commands/NAME.md`. Typing `/NAME ARGUMENTS` sends its text to the Imp, with
/// `$ARGUMENTS` replaced by the arguments. What a command sends is the person's own request, so it needs no trust.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CustomCommand {
    pub name: String,
    pub text: String,
}

/// The custom commands of the folder of `workspace` and of the person's home folder (`~/.agents/commands`).
/// A folder's own command wins over the home one of the same name.
pub fn custom_commands(workspace: &Path, home: Option<&Path>) -> Vec<CustomCommand> {
    let root = project_root(workspace, home);
    let mut found: BTreeMap<String, CustomCommand> = BTreeMap::new();
    let mut folders: Vec<PathBuf> = home
        .map(|h| h.join(".agents").join("commands"))
        .into_iter()
        .collect();
    folders.push(root.join(".agents").join("commands"));
    for folder in folders {
        let Ok(entries) = std::fs::read_dir(&folder) else {
            continue;
        };
        let mut paths: Vec<PathBuf> = entries.filter_map(|e| e.ok().map(|e| e.path())).collect();
        paths.sort();
        for path in paths {
            if path.extension().and_then(|e| e.to_str()) != Some("md") {
                continue;
            }
            let Some(name) = path.file_stem().and_then(|n| n.to_str()) else {
                continue;
            };
            if !valid_command_name(name) {
                continue;
            }
            let Ok(text) = std::fs::read_to_string(&path) else {
                continue;
            };
            let text = text.trim_end().to_string();
            if text.trim().is_empty() {
                continue;
            }
            found.insert(
                name.to_string(),
                CustomCommand {
                    name: name.to_string(),
                    text,
                },
            );
        }
    }
    found.into_values().collect()
}

/// The custom commands of `workspace`, with the person's home folder from the system.
pub fn load_custom_commands(workspace: &Path) -> Vec<CustomCommand> {
    let home = directories::BaseDirs::new().map(|b| b.home_dir().to_path_buf());
    custom_commands(workspace, home.as_deref())
}

/// A command name is letters, digits, `-` and `_`, starting with a letter or digit.
fn valid_command_name(name: &str) -> bool {
    name.chars()
        .next()
        .is_some_and(|c| c.is_ascii_alphanumeric())
        && name
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_')
}

/// A path with the home folder written as `~`.
pub fn shown_path(path: &Path) -> String {
    if let Some(home) = directories::BaseDirs::new()
        && let Ok(rest) = path.strip_prefix(home.home_dir())
    {
        return if rest.as_os_str().is_empty() {
            "~".into()
        } else {
            format!("~/{}", rest.display())
        };
    }
    path.display().to_string()
}

/// An id for an Imp that lives only in a folder, the same every time for the same folder and name.
fn folder_imp_id(root: &Path, name: &str) -> Uuid {
    let hash = Sha256::digest(format!("{}\n{name}", root.display()).as_bytes());
    let mut bytes = [0u8; 16];
    bytes.copy_from_slice(&hash[..16]);
    // A version 4 layout, so it reads as any other id.
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    Uuid::from_bytes(bytes)
}

/// Fills in `${NAME}` and `${NAME:-default}` from the environment, after the placeholders of [`expand`].
pub fn fill(value: &str, workspace: &Path, env: &impl Fn(&str) -> Option<String>) -> String {
    agents::fill_env(&expand(value, workspace), env)
}

/// How to reach a server of a config file, with every value filled in.
pub fn server_spec(
    name: &str,
    server: &SetupServer,
    workspace: &Path,
    env: &impl Fn(&str) -> Option<String>,
) -> McpServerSpec {
    let filled = |map: &BTreeMap<String, String>| -> Vec<(String, String)> {
        map.iter()
            .map(|(k, v)| (k.clone(), fill(v, workspace, env)))
            .collect()
    };
    let endpoint = if server.is_http() {
        McpEndpoint::Http {
            url: fill(&server.url, workspace, env),
            headers: filled(&server.headers)
                .into_iter()
                .filter(|(_, v)| !v.trim().is_empty())
                .collect::<Vec<_>>()
                .into(),
        }
    } else {
        McpEndpoint::Command {
            command: fill(&server.command, workspace, env),
            args: server
                .args
                .iter()
                .map(|a| fill(a, workspace, env))
                .collect(),
            env: filled(&server.env).into(),
        }
    };
    McpServerSpec {
        name: name.to_string(),
        endpoint,
    }
}

// Trust
/// The folders the person allowed, each with the digest of what they allowed.
#[derive(Debug, Clone, Default)]
pub struct TrustStore {
    path: Option<PathBuf>,
}

impl TrustStore {
    /// The store in the data folder. Without one, nothing is trusted and nothing can be.
    pub fn default_store() -> Self {
        Self {
            path: crate::session::data_dir()
                .ok()
                .map(|d| d.join("trusted_folders.json")),
        }
    }

    pub fn at(path: PathBuf) -> Self {
        Self { path: Some(path) }
    }

    fn read(&self) -> BTreeMap<String, String> {
        self.path
            .as_ref()
            .and_then(|p| std::fs::read_to_string(p).ok())
            .and_then(|t| serde_json::from_str(&t).ok())
            .unwrap_or_default()
    }

    fn key(root: &Path) -> String {
        root.canonicalize()
            .unwrap_or_else(|_| root.to_path_buf())
            .display()
            .to_string()
    }

    /// Whether the folder was allowed as it is now.
    pub fn allows(&self, root: &Path, digest: &str) -> bool {
        self.read().get(&Self::key(root)).map(String::as_str) == Some(digest)
    }

    /// Allows the folder as it is now (`Some`), or no longer (`None`).
    pub fn set(&self, root: &Path, digest: Option<&str>) -> Result<()> {
        let path = self.path.as_ref().ok_or_else(|| {
            CliError("There is no data folder to remember this in. Set IMP_DATA_DIR.".into())
        })?;
        let mut all = self.read();
        match digest {
            Some(d) => all.insert(Self::key(root), d.to_string()),
            None => all.remove(&Self::key(root)),
        };
        if let Some(dir) = path.parent() {
            std::fs::create_dir_all(dir)
                .map_err(|e| CliError(format!("Could not make {}: {e}", dir.display())))?;
        }
        let text = serde_json::to_string_pretty(&all).map_err(|e| CliError(e.to_string()))?;
        std::fs::write(path, text)
            .map_err(|e| CliError(format!("Could not write {}: {e}", path.display())))
    }
}

// The skill tool
/// Offers `use_skill`, which gives the model the whole text of a skill and the files beside it.
pub struct SkillHost {
    skills: Vec<Skill>,
}

impl SkillHost {
    /// The text the model gets for a skill.
    pub fn read(&self, name: &str) -> String {
        let Some(skill) = self.skills.iter().find(|s| s.spec.name == name) else {
            let names: Vec<&str> = self.skills.iter().map(|s| s.spec.name.as_str()).collect();
            return format!(
                "Error: there is no skill {name}. The skills are: {}.",
                names.join(", ")
            );
        };
        let text = match std::fs::read_to_string(&skill.path) {
            Ok(t) => t,
            Err(e) => return format!("Error: could not read {}: {e}", skill.path.display()),
        };
        let folder = skill.path.parent().unwrap_or(Path::new("."));
        agents::skill_text(
            name,
            &folder.display().to_string(),
            &text,
            &skill_files(folder),
        )
    }
}

/// The files in a skill's folder (not `SKILL.md`), a few levels down and no more than 50.
fn skill_files(folder: &Path) -> Vec<String> {
    let mut out = Vec::new();
    let mut stack = vec![folder.to_path_buf()];
    while let Some(dir) = stack.pop() {
        for path in sorted_entries(&dir) {
            if out.len() >= 50 {
                return out;
            }
            let hidden = path
                .file_name()
                .is_some_and(|n| n.to_string_lossy().starts_with('.'));
            if hidden {
                continue;
            }
            if path.is_dir() {
                if path
                    .strip_prefix(folder)
                    .map_or(0, |r| r.components().count())
                    < 3
                {
                    stack.push(path);
                }
            } else if let Ok(rel) = path.strip_prefix(folder)
                && rel != Path::new("SKILL.md")
            {
                out.push(rel.display().to_string());
            }
        }
    }
    out
}

impl ToolHost for SkillHost {
    fn tools(&self) -> Vec<HostTool> {
        let names: Vec<String> = self.skills.iter().map(|s| s.spec.name.clone()).collect();
        vec![HostTool {
            entry: Some(ToolEntry::own(SKILL_GROUP, SKILL_TOOL)),
            spec: agents::skill_tool(&names),
        }]
    }

    fn call<'a>(&'a self, name: &'a str, arguments: &'a str) -> BoxFuture<'a, Option<String>> {
        Box::pin(async move {
            if name != SKILL_TOOL {
                return None;
            }
            let args: Value = serde_json::from_str(arguments).unwrap_or(Value::Null);
            Some(match args.get("name").and_then(Value::as_str) {
                Some(skill) => self.read(skill),
                None => "Error: use_skill needs the `name` of a skill.".into(),
            })
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    struct Dir(PathBuf);

    impl Dir {
        fn new(tag: &str) -> Self {
            let path = std::env::temp_dir().join(format!(
                "imp-project-{tag}-{}-{}",
                std::process::id(),
                rand::random::<u32>()
            ));
            std::fs::create_dir_all(&path).unwrap();
            Self(path)
        }

        fn write(&self, rel: &str, text: &str) {
            let path = self.0.join(rel);
            std::fs::create_dir_all(path.parent().unwrap()).unwrap();
            std::fs::write(path, text).unwrap();
        }
    }

    impl Drop for Dir {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }

    fn no_trust() -> TrustStore {
        TrustStore::default()
    }

    #[test]
    fn a_project_gives_instructions_skills_agents_and_servers() {
        let home = Dir::new("home");
        home.write(".agents/AGENTS.md", "Mine: answer in English.");
        home.write(
            ".agents/skills/notes/SKILL.md",
            "---\nname: notes\ndescription: Mine\n---\nold",
        );
        let repo = Dir::new("repo");
        repo.write(".git/HEAD", "ref");
        repo.write("AGENTS.md", "Root rules.");
        repo.write(".agents/AGENTS.md", "Agents folder rules.");
        repo.write("app/AGENTS.md", "App rules.");
        repo.write(
            ".agents/skills/notes/SKILL.md",
            "---\nname: notes\ndescription: Write release notes\n---\nSteps here.",
        );
        repo.write(".agents/skills/notes/template.md", "x");
        repo.write(
            ".agents/skills/Bad_Name/SKILL.md",
            "---\ndescription: d\n---\n",
        );
        repo.write(
            ".agents/agents/pip.md",
            "---\nmodel: local/llama\ntools: read_file\n---\nA careful reviewer.\n",
        );
        repo.write(
            ".agents/mcp.json",
            r#"{"mcpServers": {"files": {"command": "npx", "args": ["-y", "server", "${workspaceFolder}"], "env": {"TOKEN": "${MY_TOKEN:-none}"}}}}"#,
        );
        std::fs::create_dir_all(repo.0.join("app/src")).unwrap();
        let workspace = repo.0.join("app/src");
        let project = Project::load(&workspace, Some(&home.0), &no_trust());
        assert_eq!(project.root, repo.0);
        let texts: Vec<&str> = project
            .instructions
            .iter()
            .map(|d| d.text.as_str())
            .collect();
        assert_eq!(
            texts,
            [
                "Mine: answer in English.",
                "Root rules.",
                "Agents folder rules.",
                "App rules."
            ]
        );
        assert_eq!(project.skills.len(), 1, "{:?}", project.skills);
        assert_eq!(project.skills[0].spec.description, "Write release notes");
        assert!(project.problems.iter().any(|p| p.contains("Bad_Name")));
        let prompt = project.prompt();
        assert!(prompt.contains("Root rules."));
        assert!(prompt.contains("- notes: Write release notes"));
        assert!(prompt.contains(SKILL_TOOL));
        let host = project.skill_host().unwrap();
        let read = host.read("notes");
        assert!(read.contains("Steps here."), "{read}");
        assert!(read.contains("template.md"), "{read}");
        assert!(!read.contains("description:"), "{read}");
        assert!(host.read("nope").starts_with("Error"));
        // The servers wait for trust.
        let file = project.project_mcp().unwrap();
        assert!(!file.trusted);
        assert!(project.trusted_servers().is_empty());
        assert!(project.notices()[0].contains("/project trust"));
        let spec = server_spec("files", &file.servers["files"], &workspace, &|_| None);
        let McpEndpoint::Command { args, env, .. } = spec.endpoint else {
            panic!("a command");
        };
        assert_eq!(args[2], workspace.display().to_string());
        assert_eq!(env.0, [("TOKEN".to_string(), "none".to_string())]);
        // Trusting the file as it is lets its servers start, and a change asks again.
        let store_dir = Dir::new("trust");
        let store = TrustStore::at(store_dir.0.join("t.json"));
        store
            .set(&project.root, project.trust_digest.as_deref())
            .unwrap();
        let trusted = Project::load(&workspace, Some(&home.0), &store);
        assert_eq!(trusted.trusted_servers().len(), 1);
        repo.write(".agents/mcp.json", r#"{"mcpServers": {}}"#);
        repo.write(
            ".agents/mcp.json",
            r#"{"mcpServers": {"files": {"command": "evil"}}}"#,
        );
        let changed = Project::load(&workspace, Some(&home.0), &store);
        assert!(changed.trusted_servers().is_empty());
    }

    #[test]
    fn an_agent_file_changes_its_imp_or_makes_one_for_the_folder() {
        let repo = Dir::new("agents");
        repo.write(
            ".agents/agents/pip.md",
            "---\nmodel: local/llama\nhue: 0.5\n---\nTerse.\n",
        );
        repo.write(
            ".agents/agents/reviewer.md",
            "---\ndescription: Reviews\ndisallowedTools: [mcp.files.delete]\n---\nReviews code.",
        );
        let project = Project::load(&repo.0, None, &no_trust());
        let mut config = Config::default();
        config.imps.insert(
            "pip".into(),
            ImpConfig {
                api_key_env: Some("PIP_KEY".into()),
                ..ImpConfig::new("Chatty".into(), "http://local/v1".into(), "big".into())
            },
        );
        project.apply(&mut config);
        project.apply(&mut config);
        let pip = &config.imps["pip"];
        assert_eq!(pip.model, "local/llama");
        assert_eq!(pip.personality, "Terse.");
        assert_eq!(pip.hue, Some(0.5));
        let reviewer = &config.imps["reviewer"];
        assert_eq!(reviewer.base_url, "http://local/v1");
        assert_eq!(reviewer.api_key_env.as_deref(), Some("PIP_KEY"));
        // What the file says about the Imp is what other Imps read about it.
        assert_eq!(reviewer.description.as_deref(), Some("Reviews"));
        assert_eq!(pip.description, None);
        assert_eq!(reviewer.personality, "Reviews code.");
        assert_eq!(reviewer.tools_off, ["mcp.files.delete"]);
        assert_eq!(reviewer.id, Some(folder_imp_id(&project.root, "reviewer")));
        assert_eq!(
            project.sets("pip", "model"),
            Some(project.agents["pip"].path.as_path())
        );
        assert_eq!(project.sets("pip", "base_url"), None);
    }

    #[test]
    fn a_servers_values_are_filled_and_its_name_checked() {
        let env = |n: &str| (n == "A").then(|| "1".to_string());
        let ws = Path::new("/w");
        assert_eq!(fill("${workspaceFolder}/a${A}", ws, &env), "/w/a1");
        let web = setup::parse_config_file(
            r#"{"servers":{"w":{"url":"https://x/mcp","headers":{"Authorization":"Bearer ${A}","Empty":"${NONE}"}}}}"#,
        )
        .unwrap();
        let spec = server_spec("w", &web[0], ws, &env);
        assert!(!format!("{spec:?}").contains("Bearer"));
        let McpEndpoint::Http { headers, .. } = spec.endpoint else {
            panic!("http");
        };
        assert_eq!(
            headers.0,
            [("Authorization".to_string(), "Bearer 1".to_string())]
        );
        let bad = setup::parse_config_file(r#"{"mcpServers":{"a b":{"command":"c"}}}"#).unwrap();
        assert!(checked_servers(bad).unwrap_err().contains("not allowed"));
    }

    #[test]
    fn custom_commands_come_from_the_folder_and_home_and_the_folder_wins() {
        let home = Dir::new("cmd-home");
        let folder = Dir::new("cmd-folder");
        folder.write(".git/HEAD", "ref");
        home.write(".agents/commands/review.md", "Home review $ARGUMENTS\n");
        home.write(".agents/commands/tidy.md", "Tidy up.\n");
        folder.write(
            ".agents/commands/review.md",
            "Review $ARGUMENTS for bugs and missing tests.\n",
        );
        folder.write(".agents/commands/notes.txt", "not a command");
        folder.write(".agents/commands/bad name.md", "spaces are not allowed");
        folder.write(".agents/commands/empty.md", "  \n");

        let found = custom_commands(&folder.0, Some(&home.0));
        let names: Vec<&str> = found.iter().map(|c| c.name.as_str()).collect();
        assert_eq!(names, ["review", "tidy"]);
        assert_eq!(
            found[0].text,
            "Review $ARGUMENTS for bugs and missing tests."
        );
        assert_eq!(found[1].text, "Tidy up.");
    }

    #[test]
    fn valid_command_names_are_plain_words() {
        assert!(valid_command_name("review"));
        assert!(valid_command_name("pr-check_2"));
        assert!(!valid_command_name(""));
        assert!(!valid_command_name("-x"));
        assert!(!valid_command_name("a b"));
        assert!(!valid_command_name("a.b"));
    }
}
