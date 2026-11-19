//! The settings file (TOML). It never holds an API key, only the name of the environment
//! variable that does.

use crate::{CliError, Result};
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use uuid::Uuid;

pub const DEFAULT_KEY_ENV: &str = "IMP_API_KEY";
pub const DEFAULT_URL: &str = "https://openrouter.ai/api/v1";
pub const DEFAULT_PERSONALITY: &str =
    "Friendly, curious and a little mischievous. Keeps answers short.";

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ImpConfig {
    /// The Imp's id on the link, the same on every device it visits. Made the first time it is needed.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub id: Option<Uuid>,
    /// Its colour on other devices' screens, from 0 to 1 around the colour wheel. Taken from the name if left out.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub hue: Option<f64>,
    pub personality: String,
    /// What the Imp says about itself to other Imps (a sentence or two), so they can tell whom to ask. Other
    /// Imps read it as information, never as instructions.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub description: Option<String>,
    /// The base address of an OpenAI-compatible service.
    pub base_url: String,
    pub model: String,
    /// The environment variable that holds this Imp's key, if not the global one.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub api_key_env: Option<String>,
    /// MCP servers this Imp may use, by name.
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub mcp_servers: BTreeMap<String, McpServerConfig>,
    /// Ids of tools that are switched off for this Imp, such as `mcp.files.delete`
    /// or `own.personality.imp_message`.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub tools_off: Vec<String>,
}

/// How to reach an MCP server: a `command` to start, or a `url` to post to. Environment variables
/// and HTTP headers are listed by NAME only. Their values are read when the server is reached
/// and are never stored here.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct McpServerConfig {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub command: Option<String>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub args: Vec<String>,
    /// Names of environment variables to pass on to a server started by a command.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub env: Vec<String>,
    /// The address of a server reached over HTTP.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub url: Option<String>,
    /// Names of headers to send to a server reached over HTTP, such as `Authorization`.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub headers: Vec<String>,
}

impl McpServerConfig {
    /// Whether the server is one the settings file can hold, as a sentence when not.
    pub fn check(&self, name: &str) -> Result<()> {
        let bad = |why: &str| Err(CliError(format!("The MCP server {name}: {why}")));
        match (&self.command, &self.url) {
            (Some(_), Some(_)) | (None, None) => {
                bad("give either a command or a url, not both and not neither.")
            }
            (Some(_), None) if !self.headers.is_empty() => {
                bad("headers belong to a url, not to a command.")
            }
            (None, Some(_)) if !self.env.is_empty() || !self.args.is_empty() => {
                bad("env and args belong to a command, not to a url.")
            }
            (None, Some(url)) if !(url.starts_with("http://") || url.starts_with("https://")) => {
                bad("the url must start with http:// or https://.")
            }
            _ if self.headers.iter().any(|h| !valid_header_name(h)) => bad(
                "a header name has characters that are not allowed. Only the NAME is listed, not the value.",
            ),
            _ => Ok(()),
        }
    }
}

/// Whether `name` is a header name: letters, digits and `-`.
pub fn valid_header_name(name: &str) -> bool {
    !name.is_empty() && name.chars().all(|c| c.is_ascii_alphanumeric() || c == '-')
}

impl ImpConfig {
    /// Its colour: the one set, or one that stays the same for the same name.
    pub fn hue_for(&self, name: &str) -> f64 {
        self.hue
            .map_or_else(|| name_hue(name), |h| h.clamp(0.0, 1.0))
    }

    /// Changes one of its settings by name: model, base_url, personality, description, api_key_env or hue.
    /// Errors never repeat the value, in case it was a key by mistake.
    pub fn set(&mut self, key: &str, value: &str) -> Result<()> {
        let value = value.trim();
        match key {
            "model" if !value.is_empty() => self.model = value.to_string(),
            "model" => return Err(CliError("The model needs a name.".into())),
            "base_url" | "url" => {
                if !(value.starts_with("http://") || value.starts_with("https://")) {
                    return Err(CliError(
                        "The service address must start with http:// or https://.".into(),
                    ));
                }
                self.base_url = value.trim_end_matches('/').to_string();
            }
            "personality" if !value.is_empty() => self.personality = value.to_string(),
            "personality" => return Err(CliError("Say in a sentence how it behaves.".into())),
            "description" if value.is_empty() || value == "-" => self.description = None,
            "description" => self.description = Some(value.to_string()),
            "api_key_env" if value.is_empty() || value == "-" => self.api_key_env = None,
            "api_key_env" if valid_env_name(value) => self.api_key_env = Some(value.to_string()),
            "api_key_env" => {
                return Err(CliError(
                    "api_key_env is the NAME of an environment variable, such as OPENROUTER_API_KEY, not the key itself.".into(),
                ));
            }
            "hue" => {
                self.hue = Some(
                    value
                        .parse::<f64>()
                        .ok()
                        .filter(|h| (0.0..=1.0).contains(h))
                        .ok_or_else(|| CliError("hue is a number from 0 to 1.".into()))?,
                );
            }
            _ => {
                return Err(CliError(format!(
                    "Unknown setting {key}. An Imp has model, base_url, personality, description, api_key_env and hue."
                )));
            }
        }
        Ok(())
    }

    /// An Imp with no MCP servers and every tool on.
    pub fn new(personality: String, base_url: String, model: String) -> Self {
        Self {
            id: Some(crate::link::new_device_id()),
            hue: None,
            personality,
            description: None,
            base_url,
            model,
            api_key_env: None,
            mcp_servers: BTreeMap::new(),
            tools_off: Vec::new(),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Config {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub default_imp: Option<String>,
    /// The environment variable that holds the API key.
    #[serde(default = "default_key_env")]
    pub api_key_env: String,
    /// How many times a failed request is tried again.
    #[serde(default = "default_retries")]
    pub retries: u32,
    #[serde(default)]
    pub imps: BTreeMap<String, ImpConfig>,
    /// The most model requests in one answer, when tools keep being called.
    #[serde(default = "default_max_steps")]
    pub max_steps: usize,
    /// How many of the chat's latest exchanges are sent with each message. 0 (the default): all
    /// that are kept, up to the core's limit. Fewer costs less but forgets sooner.
    #[serde(default, skip_serializing_if = "is_zero")]
    pub memory_exchanges: usize,
    /// The chat says it has grown long, and suggests `/compact`, when what is sent reaches this many
    /// tokens. 0 turns it off.
    #[serde(default = "default_long_chat_tokens")]
    pub long_chat_tokens: usize,
    /// Minutes after which a conversation between two Imps counts as over.
    #[serde(default = "default_window")]
    pub talk_window_minutes: u32,
    /// Who decides whether a message to another Imp goes on in the last conversation.
    #[serde(default)]
    pub talk_threading: imp_engine::Threading,
    /// Whether a message to another Imp waits for the answer: `wait`, `dont_wait` or `decides` (the sending Imp
    /// says). An answer that does not wait comes later as a new message.
    #[serde(default)]
    pub talk_waiting: imp_engine::troupe::TalkWaiting,
}

fn is_zero(n: &usize) -> bool {
    *n == 0
}

fn default_long_chat_tokens() -> usize {
    imp_engine::memory::NOTICE_DEFAULT_TOKENS
}

fn default_max_steps() -> usize {
    10
}

fn default_window() -> u32 {
    60
}

fn default_key_env() -> String {
    DEFAULT_KEY_ENV.to_string()
}

fn default_retries() -> u32 {
    imp_engine::RequestLimits::default().retries as u32
}

impl Default for Config {
    fn default() -> Self {
        Self {
            default_imp: None,
            api_key_env: default_key_env(),
            retries: default_retries(),
            imps: BTreeMap::new(),
            max_steps: default_max_steps(),
            memory_exchanges: 0,
            long_chat_tokens: default_long_chat_tokens(),
            talk_window_minutes: default_window(),
            talk_threading: imp_engine::Threading::default(),
            talk_waiting: imp_engine::troupe::TalkWaiting::default(),
        }
    }
}

/// A colour from a name, the same every time: FNV-1a folded onto the colour wheel.
fn name_hue(name: &str) -> f64 {
    let hash = name.bytes().fold(0xcbf2_9ce4_8422_2325_u64, |h, b| {
        (h ^ u64::from(b)).wrapping_mul(0x0100_0000_01b3)
    });
    (hash % 1000) as f64 / 1000.0
}

/// Whether `name` can be used as an Imp name: 1 to 32 letters, digits, `-` or `_`.
pub fn valid_imp_name(name: &str) -> bool {
    (1..=32).contains(&name.len())
        && name
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_')
}

/// Whether `name` can be an environment variable name. This also keeps a pasted key out of the file.
/// The rule is the core's, shared with the folder's agent files.
pub fn valid_env_name(name: &str) -> bool {
    imp_engine::agents::valid_env_name(name)
}

impl Config {
    /// The usual place of the settings file, such as `~/.config/imp/config.toml` (see `folders`).
    pub fn default_path() -> Result<PathBuf> {
        crate::folders::config_dir()
            .map(|d| d.join("config.toml"))
            .ok_or_else(|| {
                CliError(
                    "Could not find a settings folder. Use --config to say where the file is."
                        .into(),
                )
            })
    }

    /// Reads the file. A missing file gives the default settings.
    pub fn load(path: &Path) -> Result<Self> {
        match std::fs::read_to_string(path) {
            Ok(text) => Self::parse(&text)
                .map_err(|e| CliError(format!("{} is not valid: {}", path.display(), e.0))),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(Self::default()),
            Err(e) => Err(CliError(format!("Could not read {}: {e}", path.display()))),
        }
    }

    pub fn parse(text: &str) -> Result<Self> {
        let config: Self = toml::from_str(text).map_err(|e| CliError(e.message().to_string()))?;
        for imp in config.imps.values() {
            for (name, server) in &imp.mcp_servers {
                server.check(name)?;
            }
        }
        Ok(config)
    }

    pub fn to_toml(&self) -> Result<String> {
        toml::to_string_pretty(self).map_err(|e| CliError(e.to_string()))
    }

    /// Writes the file, making its folder if needed.
    pub fn save(&self, path: &Path) -> Result<()> {
        if let Some(dir) = path.parent().filter(|d| !d.as_os_str().is_empty()) {
            std::fs::create_dir_all(dir)
                .map_err(|e| CliError(format!("Could not make {}: {e}", dir.display())))?;
        }
        std::fs::write(path, self.to_toml()?)
            .map_err(|e| CliError(format!("Could not write {}: {e}", path.display())))
    }

    /// Gives every Imp an id it keeps. True if one was missing, so the file should be saved.
    pub fn ensure_ids(&mut self) -> bool {
        let mut changed = false;
        for imp in self.imps.values_mut() {
            if imp.id.is_none() {
                imp.id = Some(crate::link::new_device_id());
                changed = true;
            }
        }
        changed
    }

    /// Reads the file and gives every Imp an id, saving the file if one was missing.
    pub fn load_with_ids(path: &Path) -> Result<Self> {
        let mut config = Self::load(path)?;
        if config.ensure_ids() {
            config.save(path)?;
        }
        Ok(config)
    }

    /// The Imp with this link id.
    pub fn imp_by_id(&self, id: Uuid) -> Option<(&str, &ImpConfig)> {
        self.imps
            .iter()
            .find(|(_, imp)| imp.id == Some(id))
            .map(|(name, imp)| (name.as_str(), imp))
    }

    /// The Imp called `name`, in any letter case: an exact name first, else the one that matches
    /// without regard to case. Names are kept unique without regard to case, so there is at most one.
    /// Returns the name as it is stored.
    pub fn find_imp(&self, name: &str) -> Option<(&String, &ImpConfig)> {
        if let Some(found) = self.imps.get_key_value(name) {
            return Some(found);
        }
        let lower = name.to_lowercase();
        self.imps
            .iter()
            .find(|(stored, _)| stored.to_lowercase() == lower)
    }

    /// The Imp named `name`, or the default one, or the only one there is.
    pub fn pick_imp<'a>(&'a self, name: Option<&str>) -> Result<(&'a str, &'a ImpConfig)> {
        let found = match name {
            Some(n) => self.find_imp(n).ok_or_else(|| {
                CliError(format!("There is no Imp called {n}. Try `imp imp list`."))
            })?,
            None => match &self.default_imp {
                Some(n) => self.find_imp(n.as_str()).ok_or_else(|| {
                    CliError(format!(
                        "The default Imp {n} does not exist. Try `imp imp list`."
                    ))
                })?,
                None if self.imps.len() == 1 => self.imps.iter().next().expect("one Imp"),
                None if self.imps.is_empty() => {
                    return Err(CliError(
                        "You have no Imps yet. Make one with `imp imp new NAME --model MODEL`."
                            .into(),
                    ));
                }
                None => {
                    return Err(CliError(
                        "Which Imp? Use --imp NAME, `imp config set default_imp NAME`, or `default: true` in a folder's .agents/agents/NAME.md.".into(),
                    ));
                }
            },
        };
        Ok((found.0.as_str(), found.1))
    }

    /// Changes a setting by name. Errors never repeat the value, in case it was a key by mistake.
    pub fn set(&mut self, key: &str, value: &str) -> Result<()> {
        match key {
            "default_imp" => {
                let Some((stored, _)) = self.find_imp(value) else {
                    return Err(CliError(
                        "That Imp does not exist. Try `imp imp list`.".into(),
                    ));
                };
                self.default_imp = Some(stored.clone());
            }
            "api_key_env" => {
                if !valid_env_name(value) {
                    return Err(CliError(
                        "api_key_env is the NAME of an environment variable, such as IMP_API_KEY, not the key itself.".into(),
                    ));
                }
                self.api_key_env = value.to_string();
            }
            "retries" => {
                self.retries = value
                    .parse()
                    .ok()
                    .filter(|n| *n <= 10)
                    .ok_or_else(|| CliError("retries must be a number from 0 to 10.".into()))?;
            }
            "max_steps" => {
                self.max_steps = value
                    .parse()
                    .ok()
                    .filter(|n| (1..=50).contains(n))
                    .ok_or_else(|| CliError("max_steps must be a number from 1 to 50.".into()))?;
            }
            "memory_exchanges" => {
                let most = imp_engine::memory::STORED_EXCHANGES;
                self.memory_exchanges = value
                    .parse()
                    .ok()
                    .filter(|n| *n <= most)
                    .ok_or_else(|| {
                        CliError(format!(
                            "memory_exchanges is how many exchanges are sent, from 1 to {most}, or 0 for all."
                        ))
                    })?;
            }
            "long_chat_tokens" => {
                self.long_chat_tokens = value.parse().ok().ok_or_else(|| {
                    CliError(
                        "long_chat_tokens is a number of tokens, such as 250000, or 0 for never."
                            .into(),
                    )
                })?;
            }
            _ => {
                return Err(CliError(format!(
                    "Unknown setting {key}. The settings are default_imp, api_key_env, retries, max_steps, memory_exchanges and long_chat_tokens."
                )));
            }
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sample() -> Config {
        let mut c = Config {
            default_imp: Some("pip".into()),
            retries: 5,
            ..Config::default()
        };
        c.imps.insert(
            "pip".into(),
            ImpConfig {
                personality: "Quick \"and\" curious\nwith two lines".into(),
                base_url: "http://localhost:11434/v1".into(),
                model: "llama".into(),
                api_key_env: None,
                ..ImpConfig::new(String::new(), String::new(), String::new())
            },
        );
        c.imps.insert(
            "zed".into(),
            ImpConfig {
                personality: DEFAULT_PERSONALITY.into(),
                base_url: DEFAULT_URL.into(),
                model: "openai/gpt-6-luna".into(),
                api_key_env: Some("ZED_KEY".into()),
                ..ImpConfig::new(String::new(), String::new(), String::new())
            },
        );
        c
    }

    #[test]
    fn toml_round_trip() {
        let c = sample();
        let text = c.to_toml().unwrap();
        assert_eq!(Config::parse(&text).unwrap(), c);
    }

    #[test]
    fn file_round_trip_and_missing_file() {
        let dir = std::env::temp_dir().join(format!("imp-chat-config-{}", std::process::id()));
        let path = dir.join("nested").join("config.toml");
        assert_eq!(Config::load(&path).unwrap(), Config::default());
        let c = sample();
        c.save(&path).unwrap();
        assert_eq!(Config::load(&path).unwrap(), c);
        std::fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn partial_files_get_defaults_and_unknown_keys_are_refused() {
        let c = Config::parse("default_imp = \"a\"\n").unwrap();
        assert_eq!(c.api_key_env, DEFAULT_KEY_ENV);
        assert_eq!(c.retries, 3);
        assert!(Config::parse("api_key = \"sk-nope\"\n").is_err());
    }

    #[test]
    fn imp_names_ignore_letter_case() {
        let c = sample();
        assert_eq!(c.find_imp("PIP").map(|(n, _)| n.as_str()), Some("pip"));
        assert_eq!(c.find_imp("Zed").map(|(n, _)| n.as_str()), Some("zed"));
        assert_eq!(c.pick_imp(Some("ZED")).unwrap().0, "zed");
        assert!(c.find_imp("nobody").is_none());
    }

    #[test]
    fn picking_an_imp() {
        let c = sample();
        assert_eq!(c.pick_imp(None).unwrap().0, "pip");
        assert_eq!(c.pick_imp(Some("zed")).unwrap().0, "zed");
        assert!(c.pick_imp(Some("nobody")).is_err());
        let mut none_default = sample();
        none_default.default_imp = None;
        assert!(none_default.pick_imp(None).is_err());
        assert!(Config::default().pick_imp(None).is_err());
        none_default.imps.remove("zed");
        assert_eq!(none_default.pick_imp(None).unwrap().0, "pip");
    }

    #[test]
    fn setting_values() {
        let mut c = sample();
        c.set("retries", "0").unwrap();
        assert_eq!(c.retries, 0);
        assert!(c.set("retries", "99").is_err());
        c.set("default_imp", "zed").unwrap();
        assert!(c.set("default_imp", "ghost").is_err());
        c.set("api_key_env", "MY_KEY").unwrap();
        let err = c.set("api_key_env", "sk-abc123").unwrap_err();
        assert!(!err.0.contains("sk-abc123"));
        assert!(c.set("colour", "red").is_err());
    }

    #[test]
    fn names() {
        assert!(valid_imp_name("pip-2_x"));
        assert!(!valid_imp_name(""));
        assert!(!valid_imp_name("a b"));
        assert!(!valid_imp_name(&"x".repeat(33)));
        assert!(valid_env_name("IMP_API_KEY"));
        assert!(!valid_env_name("1ABC"));
    }
}

#[cfg(test)]
mod mcp_tests {
    use super::*;
    use imp_engine::McpEndpoint;

    #[test]
    fn mcp_servers_tools_off_and_talk_settings_round_trip() {
        let text = r#"
talk_window_minutes = 30
talk_threading = "recent"
talk_waiting = "dont_wait"
max_steps = 4

[imps.pip]
personality = "p"
description = "Keeps the files tidy."
base_url = "http://localhost:1/v1"
model = "m"
tools_off = ["mcp.files.delete"]

[imps.pip.mcp_servers.files]
command = "mcp-files"
args = ["--root", "/tmp"]
env = ["FILES_TOKEN"]
"#;
        let config = Config::parse(text).unwrap();
        assert_eq!(config.talk_window_minutes, 30);
        assert_eq!(config.talk_threading, imp_engine::Threading::Recent);
        assert_eq!(
            config.talk_waiting,
            imp_engine::troupe::TalkWaiting::DontWait
        );
        assert_eq!(config.max_steps, 4);
        let imp = &config.imps["pip"];
        assert_eq!(imp.description.as_deref(), Some("Keeps the files tidy."));
        assert_eq!(imp.tools_off, ["mcp.files.delete"]);
        assert_eq!(imp.mcp_servers["files"].env, ["FILES_TOKEN"]);
        assert_eq!(
            imp.mcp_servers["files"].command.as_deref(),
            Some("mcp-files")
        );
        assert_eq!(Config::parse(&config.to_toml().unwrap()).unwrap(), config);
        let defaults = Config::default();
        assert_eq!(defaults.talk_window_minutes, 60);
        assert_eq!(defaults.talk_threading, imp_engine::Threading::Decides);
        assert_eq!(
            defaults.talk_waiting,
            imp_engine::troupe::TalkWaiting::Decides
        );
        assert_eq!(defaults.imps.len(), 0);
    }

    #[test]
    fn only_variable_names_are_listed_and_values_come_from_the_environment() {
        let config = Config::parse(
            "[imps.a]\npersonality=\"p\"\nbase_url=\"u\"\nmodel=\"m\"\n[imps.a.mcp_servers.s]\ncommand=\"c\"\nenv=[\"GOOD\",\"bad name\",\"UNSET\"]\n",
        )
        .unwrap();
        let specs = crate::commands::mcp_specs(
            &config.imps["a"],
            |n| (n == "GOOD").then(|| "secret".to_string()),
            |_| None,
        );
        let McpEndpoint::Command { env, .. } = &specs[0].endpoint else {
            panic!("a command");
        };
        assert_eq!(env.0, [("GOOD".to_string(), "secret".to_string())]);
        assert!(!config.to_toml().unwrap().contains("secret"));
    }

    #[test]
    fn header_values_come_from_the_environment_then_the_keychain() {
        let config = Config::parse(
            "[imps.a]\npersonality=\"p\"\nbase_url=\"u\"\nmodel=\"m\"\n[imps.a.mcp_servers.web]\nurl=\"https://x/mcp\"\nheaders=[\"Authorization\",\"X-Key\",\"X-None\"]\n",
        )
        .unwrap();
        let specs = crate::commands::mcp_specs(
            &config.imps["a"],
            |n| (n == "IMP_MCP_WEB_AUTHORIZATION").then(|| "env-value".to_string()),
            |n| (n == "mcp.web.X-Key").then(|| "chain-value".to_string()),
        );
        let McpEndpoint::Http { headers, .. } = &specs[0].endpoint else {
            panic!("a url");
        };
        assert_eq!(
            headers.0,
            [
                ("Authorization".to_string(), "env-value".to_string()),
                ("X-Key".to_string(), "chain-value".to_string())
            ]
        );
        assert!(!format!("{specs:?}").contains("-value"));
        assert!(!config.to_toml().unwrap().contains("-value"));
    }

    #[test]
    fn a_server_has_a_command_or_a_url_with_header_names() {
        let head =
            "[imps.a]\npersonality=\"p\"\nbase_url=\"u\"\nmodel=\"m\"\n[imps.a.mcp_servers.web]\n";
        let config = Config::parse(&format!(
            "{head}url=\"https://x.example/mcp\"\nheaders=[\"Authorization\"]\n"
        ))
        .unwrap();
        let web = &config.imps["a"].mcp_servers["web"];
        assert_eq!(web.url.as_deref(), Some("https://x.example/mcp"));
        assert_eq!(web.headers, ["Authorization"]);
        assert_eq!(Config::parse(&config.to_toml().unwrap()).unwrap(), config);
        for bad in [
            "command=\"c\"\nurl=\"https://x\"\n",
            "",
            "command=\"c\"\nheaders=[\"A\"]\n",
            "url=\"https://x\"\nenv=[\"A\"]\n",
            "url=\"ftp://x\"\n",
            "url=\"https://x\"\nheaders=[\"Bearer abc\"]\n",
        ] {
            assert!(Config::parse(&format!("{head}{bad}")).is_err(), "{bad}");
        }
    }
}
