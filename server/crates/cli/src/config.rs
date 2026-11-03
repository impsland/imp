//! The settings file (TOML). It never holds an API key, only the name of the environment
//! variable that does.

use crate::{CliError, Result};
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

pub const DEFAULT_KEY_ENV: &str = "IMP_API_KEY";
pub const DEFAULT_URL: &str = "https://api.openai.com/v1";
pub const DEFAULT_PERSONALITY: &str =
    "Friendly, curious and a little mischievous. Keeps answers short.";

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ImpConfig {
    pub personality: String,
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
    /// or `own.troupe.imp_message`.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub tools_off: Vec<String>,
}

/// How to start an MCP server. Environment variables are listed by NAME only. Their values are
/// read from the environment when the server starts and are never stored.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct McpServerConfig {
    pub command: String,
    #[serde(default)]
    pub args: Vec<String>,
    /// Names of environment variables to pass on to the server.
    #[serde(default)]
    pub env: Vec<String>,
}

impl ImpConfig {
    /// An Imp with no MCP servers and every tool on.
    pub fn new(personality: String, base_url: String, model: String) -> Self {
        Self {
            personality,
            base_url,
            model,
            api_key_env: None,
            mcp_servers: BTreeMap::new(),
            tools_off: Vec::new(),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
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
    /// Minutes after which a conversation between two Imps counts as over.
    #[serde(default = "default_window")]
    pub talk_window_minutes: u32,
    /// Who decides whether a message to another Imp goes on in the last conversation.
    #[serde(default)]
    pub talk_threading: imp_core::Threading,
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
    3
}

impl Default for Config {
    fn default() -> Self {
        Self {
            default_imp: None,
            api_key_env: default_key_env(),
            retries: default_retries(),
            imps: BTreeMap::new(),
            max_steps: default_max_steps(),
            talk_window_minutes: default_window(),
            talk_threading: imp_core::Threading::default(),
        }
    }
}

/// Whether `name` can be used as an Imp name: 1 to 32 letters, digits, `-` or `_`.
pub fn valid_imp_name(name: &str) -> bool {
    (1..=32).contains(&name.len())
        && name
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_')
}

/// Whether `name` can be an environment variable name. This also keeps a pasted key out of the file.
pub fn valid_env_name(name: &str) -> bool {
    let mut chars = name.chars();
    chars
        .next()
        .is_some_and(|c| c.is_ascii_alphabetic() || c == '_')
        && chars.all(|c| c.is_ascii_alphanumeric() || c == '_')
}

impl Config {
    /// The usual place of the settings file, such as `~/.config/imp/config.toml`.
    pub fn default_path() -> Result<PathBuf> {
        directories::ProjectDirs::from("", "", "imp")
            .map(|d| d.config_dir().join("config.toml"))
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
        toml::from_str(text).map_err(|e| CliError(e.message().to_string()))
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

    /// The Imp named `name`, or the default one, or the only one there is.
    pub fn pick_imp<'a>(&'a self, name: Option<&str>) -> Result<(&'a str, &'a ImpConfig)> {
        let found = match name {
            Some(n) => self.imps.get_key_value(n).ok_or_else(|| {
                CliError(format!("There is no Imp called {n}. Try `imp imp list`."))
            })?,
            None => match &self.default_imp {
                Some(n) => self.imps.get_key_value(n.as_str()).ok_or_else(|| {
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
                        "Which Imp? Use --imp NAME, or `imp config set default_imp NAME`.".into(),
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
                if !self.imps.contains_key(value) {
                    return Err(CliError(
                        "That Imp does not exist. Try `imp imp list`.".into(),
                    ));
                }
                self.default_imp = Some(value.to_string());
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
            _ => {
                return Err(CliError(format!(
                    "Unknown setting {key}. The settings are default_imp, api_key_env and retries."
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
                model: "gpt-5".into(),
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
        let dir = std::env::temp_dir().join(format!("imp-cli-config-{}", std::process::id()));
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

    #[test]
    fn mcp_servers_tools_off_and_talk_settings_round_trip() {
        let text = r#"
talk_window_minutes = 30
talk_threading = "recent"
max_steps = 4

[imps.pip]
personality = "p"
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
        assert_eq!(config.talk_threading, imp_core::Threading::Recent);
        assert_eq!(config.max_steps, 4);
        let imp = &config.imps["pip"];
        assert_eq!(imp.tools_off, ["mcp.files.delete"]);
        assert_eq!(imp.mcp_servers["files"].env, ["FILES_TOKEN"]);
        assert_eq!(Config::parse(&config.to_toml().unwrap()).unwrap(), config);
        let defaults = Config::default();
        assert_eq!(defaults.talk_window_minutes, 60);
        assert_eq!(defaults.talk_threading, imp_core::Threading::Decides);
    }

    #[test]
    fn only_variable_names_are_listed_and_values_come_from_the_environment() {
        let config = Config::parse(
            "[imps.a]\npersonality=\"p\"\nbase_url=\"u\"\nmodel=\"m\"\n[imps.a.mcp_servers.s]\ncommand=\"c\"\nenv=[\"GOOD\",\"bad name\",\"UNSET\"]\n",
        )
        .unwrap();
        let specs = crate::commands::mcp_specs(&config.imps["a"], |n| {
            (n == "GOOD").then(|| "secret".to_string())
        });
        assert_eq!(specs[0].env, [("GOOD".to_string(), "secret".to_string())]);
        assert!(!config.to_toml().unwrap().contains("secret"));
    }
}
