//! The configuration the terminal app runs on: the one the Mac app shares (`docs/architecture/configuration.md`).
//! `imp_engine::config` owns the format. This is the terminal's handle on it: where the folders are, how
//! to load everything for the folder a chat started in, and what an Imp is for the rest of the app.

use crate::{CliError, Result};
use imp_engine::config::{
    Agent, Env, ImpExtras, Loaded, Sourced, Store, TrustStore, load::project_dirs,
};
use imp_engine::link::{LinkImp, LinkTraits};
use imp_engine::troupe::{TalkWaiting, ability_tags, about_line};
use imp_engine::{RetryPolicy, Threading};
use std::collections::hash_map::DefaultHasher;
use std::hash::{Hash, Hasher};
use std::path::{Path, PathBuf};
use uuid::Uuid;

/// The most model requests in one answer when the agent says nothing (`steps`).
pub const DEFAULT_STEPS: usize = 10;
/// Minutes after which a conversation between two Imps counts as over.
pub const DEFAULT_TALK_WINDOW: u32 = 60;
pub const DEFAULT_PERSONALITY: &str =
    "Friendly, curious and a little mischievous. Keeps answers short.";

/// Where the configuration is and which folder the chat works in. Cheap to clone.
#[derive(Debug, Clone)]
pub struct Settings {
    pub env: Env,
    pub store: Store,
    pub trust: TrustStore,
    pub workspace: PathBuf,
    /// Where chats, talks between Imps and the trust list are kept. None: there is no such folder.
    pub data_dir: Option<PathBuf>,
}

impl Settings {
    /// The real environment, the current folder and the data folder's trust list.
    pub fn here() -> Result<Self> {
        Self::new(
            Env::process(),
            std::env::current_dir()?,
            crate::session::data_dir().ok(),
        )
    }

    /// Settings in a made-up environment, for tests and for callers that know better.
    pub fn new(env: Env, workspace: PathBuf, data_dir: Option<PathBuf>) -> Result<Self> {
        Ok(Self {
            store: Store::from_env(&env)?,
            trust: data_dir.as_ref().map_or_else(TrustStore::none, |d| {
                TrustStore::at(d.join("trusted_folders.json"))
            }),
            env,
            workspace,
            data_dir,
        })
    }

    /// The folder for the conversations between Imps.
    pub fn talks_dir(&self) -> Result<PathBuf> {
        self.data_dir
            .as_ref()
            .map(|d| d.join("talks"))
            .ok_or_else(|| CliError("Could not find a folder for data. Set IMP_DATA_DIR.".into()))
    }

    /// Everything, read fresh, for the chat's folder. An Imp that has no settings yet in `imp.json` gets
    /// its id there, so other apps and devices know it by the same one.
    pub fn load(&self) -> Loaded {
        let mut loaded = imp_engine::config::load(&self.env, Some(&self.workspace), &self.trust);
        let missing: Vec<String> = loaded
            .imps()
            .map(|a| a.value.name.clone())
            .filter(|n| !loaded.config.imps.contains_key(n))
            .collect();
        if !missing.is_empty() {
            let added = self.store.update(|c| {
                for name in &missing {
                    c.imps.entry(name.clone()).or_insert_with(ImpExtras::new);
                }
                c.imps.clone()
            });
            match added {
                Ok(imps) => loaded.config.imps = imps,
                Err(e) => loaded
                    .diagnostics
                    .push(imp_engine::config::Diagnostic::new(None, e.to_string())),
            }
        }
        loaded
    }

    /// A number that changes when `imp.json`, `auth.json`, the trust list or a file of the agents folders changes. The chat
    /// compares it before each turn, so what another app wrote is taken at once without a watcher.
    pub fn stamp(&self) -> u64 {
        let mut hasher = DefaultHasher::new();
        let mut paths = vec![self.store.config_path(), self.store.auth_path()];
        // Trusting a folder changes what it adds, with no file of the folder changed.
        paths.extend(self.data_dir.iter().map(|d| d.join("trusted_folders.json")));
        let mut roots: Vec<PathBuf> = self.env.agents_dir().into_iter().collect();
        let folders = project_dirs(&self.workspace, self.env.home_dir());
        paths.extend(folders.iter().map(|d| d.join("AGENTS.md")));
        roots.extend(folders.into_iter().map(|d| d.join(".agents")));
        for root in roots {
            paths.push(root.join("imp.json"));
            paths.push(root.join("AGENTS.md"));
            for folder in ["agents", "skills", "commands"] {
                collect(&root.join(folder), 3, &mut paths);
            }
        }
        for path in paths {
            if let Ok(meta) = std::fs::metadata(&path) {
                path.hash(&mut hasher);
                meta.len().hash(&mut hasher);
                meta.modified().ok().hash(&mut hasher);
            }
        }
        hasher.finish()
    }
}

fn collect(dir: &Path, depth: usize, out: &mut Vec<PathBuf>) {
    let Ok(entries) = std::fs::read_dir(dir) else {
        return;
    };
    let mut entries: Vec<PathBuf> = entries.filter_map(|e| e.ok().map(|e| e.path())).collect();
    entries.sort();
    for path in entries {
        if path.is_dir() && depth > 0 {
            collect(&path, depth - 1, out);
        }
        out.push(path);
    }
}

/// The Imp called `name`, or the only one there is when no name is given.
pub fn find_imp<'a>(loaded: &'a Loaded, name: Option<&str>) -> Result<&'a Sourced<Agent>> {
    match name {
        Some(n) => loaded
            .imps()
            .find(|a| a.value.name.eq_ignore_ascii_case(n))
            .ok_or_else(|| CliError(format!("There is no Imp called {n}. Try `imp agent list`."))),
        None => {
            let mut all = loaded.imps();
            match (all.next(), all.next()) {
                (Some(one), None) => Ok(one),
                (None, _) => Err(CliError(
                    "You have no Imps yet. Make one with `imp agent new NAME --model provider/model`."
                        .into(),
                )),
                _ => Err(CliError(
                    "Which Imp? Use --imp NAME. `imp agent list` shows them.".into(),
                )),
            }
        }
    }
}

pub fn imp_id(loaded: &Loaded, name: &str) -> Uuid {
    loaded
        .config
        .imps
        .get(name)
        .map_or_else(Uuid::nil, |e| e.id)
}

/// The Imp with this id (its settings in `imp.json` say which).
pub fn imp_by_id(loaded: &Loaded, id: Uuid) -> Option<&Sourced<Agent>> {
    let name = loaded
        .config
        .imps
        .iter()
        .find(|(_, e)| e.id == id)
        .map(|(n, _)| n)?;
    loaded.imps().find(|a| &a.value.name == name)
}

/// The Imp's colour as a hue from 0 to 1: the hue of its `color`, else one that stays the same for the name.
pub fn hue_of(agent: &Agent) -> f64 {
    agent
        .color
        .as_deref()
        .and_then(hue_of_color)
        .unwrap_or_else(|| name_hue(&agent.name))
}

fn hue_of_color(color: &str) -> Option<f64> {
    let hex = color.strip_prefix('#')?;
    let channel = |i: usize| {
        u8::from_str_radix(hex.get(i..i + 2)?, 16)
            .ok()
            .map(|v| f64::from(v) / 255.0)
    };
    let (r, g, b) = (channel(0)?, channel(2)?, channel(4)?);
    let (max, min) = (r.max(g).max(b), r.min(g).min(b));
    let d = max - min;
    if d == 0.0 {
        return Some(0.0);
    }
    let h = if max == r {
        ((g - b) / d).rem_euclid(6.0)
    } else if max == g {
        (b - r) / d + 2.0
    } else {
        (r - g) / d + 4.0
    };
    Some(h / 6.0)
}

fn name_hue(name: &str) -> f64 {
    let hash = name.bytes().fold(0xcbf2_9ce4_8422_2325_u64, |h, b| {
        (h ^ u64::from(b)).wrapping_mul(0x0100_0000_01b3)
    });
    (hash % 1000) as f64 / 1000.0
}

/// How other devices see an Imp of this computer. `servers` are the MCP servers it can use.
pub fn look_of(loaded: &Loaded, agent: &Agent, servers: &[String]) -> LinkImp {
    let extras = loaded.config.imps.get(&agent.name);
    LinkImp {
        id: imp_id(loaded, &agent.name),
        name: agent.name.clone(),
        hue: hue_of(agent),
        scale: extras.and_then(|e| e.size).unwrap_or(1.0),
        traits: LinkTraits::default(),
        about: agent.description.as_deref().and_then(about_line),
        abilities: ability_tags(servers),
    }
}

/// The names of the MCP servers an Imp may use: the configured ones its rules do not turn off.
pub fn servers_of(loaded: &Loaded, agent: &Agent) -> Vec<String> {
    let rules = imp_engine::config::effective_rules(&loaded.config, agent);
    loaded
        .config
        .mcp
        .iter()
        .filter(|(name, s)| {
            !s.disabled()
                && imp_engine::config::decide(&rules, "mcp", &format!("{name}/*"))
                    != imp_engine::config::Effect::Deny
        })
        .map(|(n, _)| n.clone())
        .collect()
}

pub fn steps_of(agent: &Agent) -> usize {
    agent.steps.map_or(DEFAULT_STEPS, |s| s as usize)
}

/// How many of the latest exchanges go with each message (0: all that are kept).
pub fn memory_exchanges(loaded: &Loaded, name: &str) -> usize {
    loaded
        .config
        .imps
        .get(name)
        .and_then(|e| e.memory.as_ref())
        .and_then(|m| m.exchanges)
        .map_or(0, |n| n as usize)
}

/// The chat says it has grown long at this many tokens (0: never).
pub fn long_chat_tokens(loaded: &Loaded, name: &str) -> usize {
    loaded
        .config
        .imps
        .get(name)
        .and_then(|e| e.memory.as_ref())
        .and_then(|m| m.new_chat_at_tokens)
        .map_or(imp_engine::memory::NOTICE_DEFAULT_TOKENS, |n| n as usize)
}

pub fn retry_policy(loaded: &Loaded) -> RetryPolicy {
    loaded
        .config
        .requests
        .as_ref()
        .map(imp_engine::config::Requests::limits)
        .unwrap_or_default()
        .policy()
}

/// Messaging between Imps: `talk` in `imp.json` (`threading`, `windowMinutes`, `waiting`).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Talk {
    pub threading: Threading,
    pub window_minutes: u32,
    pub waiting: TalkWaiting,
}

pub fn talk_of(loaded: &Loaded) -> Talk {
    let talk = loaded.config.talk.as_ref();
    let text = |k: &str| talk.and_then(|t| t.get(k)).and_then(|v| v.as_str());
    Talk {
        threading: text("threading").map_or_else(Threading::default, Threading::from_name),
        window_minutes: talk
            .and_then(|t| t.get("windowMinutes"))
            .and_then(serde_json::Value::as_u64)
            .map_or(DEFAULT_TALK_WINDOW, |n| n.min(u64::from(u32::MAX)) as u32),
        waiting: text("waiting").map_or_else(TalkWaiting::default, TalkWaiting::from_name),
    }
}

/// What the model is told it is: the agent's prompt, or a plain description.
pub fn system_prompt(agent: &Agent, extras: Option<&ImpExtras>) -> String {
    let mut prompt = format!(
        "You are {}, an Imp: a small character that lives on the person's computer and chats with them.",
        agent.name
    );
    let body = agent.prompt().trim();
    prompt.push(' ');
    prompt.push_str(if body.is_empty() {
        DEFAULT_PERSONALITY
    } else {
        body
    });
    if let Some(more) = extras.and_then(|e| e.instructions.as_deref()) {
        prompt.push_str("\n\n");
        prompt.push_str(more);
    }
    prompt
}
