//! `imp.json` and `auth.json` as typed values.

use crate::config::subst::{Sources, substitute_value};
use crate::config::{Diagnostic, Rule};
use crate::mcp::auth::McpAuth;
use serde::de::DeserializeOwned;
use serde::{Deserialize, Serialize};
use serde_json::{Map, Value};
use std::collections::BTreeMap;
use std::fmt;
use std::path::Path;
use uuid::Uuid;

fn is_false(b: &bool) -> bool {
    !*b
}

/// `imp.json`. What a version of the core does not know is kept in `extra` and written back.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ImpConfig {
    /// The default model, `provider/model#variant`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub model: Option<String>,
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub providers: BTreeMap<String, Provider>,
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub mcp: BTreeMap<String, McpServer>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub permissions: Vec<Rule>,
    /// What an Imp has that an agent file has no field for, by the agent's name.
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub imps: BTreeMap<String, ImpExtras>,
    /// Each one event and a list of steps, as the apps define them.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub triggers: Vec<Value>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub animations: Vec<Value>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub requests: Option<Requests>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub talk: Option<Value>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub link: Option<Link>,
    #[serde(flatten)]
    pub extra: BTreeMap<String, Value>,
}

#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
pub struct Provider {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub name: Option<String>,
    #[serde(default, skip_serializing_if = "ProviderOptions::is_empty")]
    pub options: ProviderOptions,
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub models: BTreeMap<String, ModelDef>,
    #[serde(flatten)]
    pub extra: BTreeMap<String, Value>,
}

#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
pub struct ProviderOptions {
    #[serde(default, rename = "baseURL", skip_serializing_if = "Option::is_none")]
    pub base_url: Option<String>,
    #[serde(default, rename = "apiKey", skip_serializing_if = "Option::is_none")]
    pub api_key: Option<String>,
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub headers: BTreeMap<String, String>,
    #[serde(flatten)]
    pub extra: BTreeMap<String, Value>,
}

impl ProviderOptions {
    fn is_empty(&self) -> bool {
        self == &Self::default()
    }
}

#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
pub struct ModelDef {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub name: Option<String>,
    /// A variant's object is merged into the request body.
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub variants: BTreeMap<String, Value>,
    #[serde(flatten)]
    pub extra: BTreeMap<String, Value>,
}

/// An MCP server: a program this computer starts, or an address.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "lowercase")]
pub enum McpServer {
    Local {
        /// The program and its arguments.
        command: Vec<String>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        cwd: Option<String>,
        #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
        environment: BTreeMap<String, String>,
        #[serde(default, skip_serializing_if = "is_false")]
        disabled: bool,
        /// Milliseconds to wait for the server to list its tools.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        timeout: Option<u64>,
    },
    Remote {
        url: String,
        #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
        headers: BTreeMap<String, String>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        oauth: Option<McpOAuth>,
        #[serde(default, skip_serializing_if = "is_false")]
        disabled: bool,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        timeout: Option<u64>,
    },
}

impl McpServer {
    pub fn disabled(&self) -> bool {
        match self {
            Self::Local { disabled, .. } | Self::Remote { disabled, .. } => *disabled,
        }
    }

    pub fn set_disabled(&mut self, value: bool) {
        match self {
            Self::Local { disabled, .. } | Self::Remote { disabled, .. } => *disabled = value,
        }
    }
}

/// `false` turns sign-in off, an object holds the client the server expects.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(untagged)]
pub enum McpOAuth {
    Off(bool),
    Client {
        #[serde(default, rename = "clientId", skip_serializing_if = "Option::is_none")]
        client_id: Option<String>,
        #[serde(
            default,
            rename = "clientSecret",
            skip_serializing_if = "Option::is_none"
        )]
        client_secret: Option<String>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        scope: Option<String>,
    },
}

/// An Imp's settings that are not in its agent file.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ImpExtras {
    /// Never changes, even when the agent is renamed.
    pub id: Uuid,
    /// How it looks: traits, favourite colour.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub character: Option<Value>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub size: Option<f64>,
    /// The rest of the system prompt after the agent's own (how replies are shown).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub instructions: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub memory: Option<Memory>,
    /// Its own animations.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub animations: Vec<Value>,
    #[serde(flatten)]
    pub extra: BTreeMap<String, Value>,
}

impl ImpExtras {
    /// An entry with a new random id.
    pub fn new() -> Self {
        Self::with_id(new_id())
    }

    pub fn with_id(id: Uuid) -> Self {
        Self {
            id,
            character: None,
            size: None,
            instructions: None,
            memory: None,
            animations: Vec::new(),
            extra: BTreeMap::new(),
        }
    }
}

impl Default for ImpExtras {
    fn default() -> Self {
        Self::new()
    }
}

/// A random (version 4) id.
pub fn new_id() -> Uuid {
    uuid::Builder::from_random_bytes(rand::random()).into_uuid()
}

#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Memory {
    /// How many recent exchanges are sent.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub exchanges: Option<u32>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub sends_tool_calls: Option<bool>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub new_chat_at_tokens: Option<u32>,
    #[serde(flatten)]
    pub extra: BTreeMap<String, Value>,
}

/// How long a model request may take and how it is retried (see `RequestLimits`).
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Requests {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub timeout_seconds: Option<f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub retries: Option<i64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub retry_delay_seconds: Option<f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub backoff: Option<f64>,
}

impl Requests {
    /// The limits, with the defaults for what is not set.
    pub fn limits(&self) -> crate::RequestLimits {
        let d = crate::RequestLimits::default();
        crate::RequestLimits {
            timeout_seconds: self.timeout_seconds.unwrap_or(d.timeout_seconds),
            retries: self.retries.unwrap_or(d.retries),
            retry_delay_seconds: self.retry_delay_seconds.unwrap_or(d.retry_delay_seconds),
            backoff: self.backoff.unwrap_or(d.backoff),
        }
    }
}

#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Link {
    /// The Hop server, `host:port`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub hop: Option<String>,
    /// What a device lets the others do to it.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub device_tools: Option<Value>,
    #[serde(flatten)]
    pub extra: BTreeMap<String, Value>,
}

// auth.json

/// A key saved for a provider. It holds a secret: the debug text leaves it out.
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ProviderAuth {
    pub key: String,
}

impl fmt::Debug for ProviderAuth {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("ProviderAuth").finish_non_exhaustive()
    }
}

/// `auth.json`: keys typed into either app and MCP sign-ins. Readable by the person only.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
pub struct Auth {
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub providers: BTreeMap<String, ProviderAuth>,
    /// The tokens of the servers the person signed in to, by server name.
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub mcp: BTreeMap<String, McpAuth>,
    #[serde(flatten)]
    pub extra: BTreeMap<String, Value>,
}

impl Auth {
    /// The key of a provider: `options.apiKey` when it is set and not empty, else the saved one.
    pub fn key_for(&self, name: &str, provider: Option<&Provider>) -> Option<String> {
        provider
            .and_then(|p| p.options.api_key.clone())
            .filter(|k| !k.is_empty())
            .or_else(|| self.providers.get(name).map(|a| a.key.clone()))
            .filter(|k| !k.is_empty())
    }
}

// Reading

/// Reads `imp.json` text without stopping at what is wrong in it: a section or an entry that does not
/// fit is left out and told in the diagnostics, the rest is kept. With `sources`, `{env:}` and
/// `{file:}` are filled in first (relative to `file`'s folder). Text that is not a JSON object gives
/// the empty configuration.
pub fn parse_config(
    text: &str,
    file: Option<&Path>,
    sources: Option<&dyn Sources>,
) -> (ImpConfig, Vec<Diagnostic>) {
    let mut diags = Vec::new();
    let at = file.map(Path::to_path_buf);
    let note = |diags: &mut Vec<Diagnostic>, m: String| diags.push(Diagnostic::new(at.clone(), m));
    let mut value: Value = match serde_json::from_str(text) {
        Ok(v) => v,
        Err(e) => {
            note(&mut diags, format!("is not valid JSON: {e}"));
            return (ImpConfig::default(), diags);
        }
    };
    let Value::Object(_) = value else {
        note(&mut diags, "must be a JSON object".into());
        return (ImpConfig::default(), diags);
    };
    if let Some(sources) = sources {
        let base = file.and_then(Path::parent).unwrap_or(Path::new("."));
        let mut problems = Vec::new();
        substitute_value(&mut value, base, sources, &mut problems);
        for p in problems {
            note(&mut diags, p);
        }
    }
    let Value::Object(mut map) = value else {
        return (ImpConfig::default(), diags);
    };
    let mut config = ImpConfig::default();
    let mut errors = Vec::new();
    config.model = take(&mut map, "model", &mut errors);
    config.providers = entries(&mut map, "providers", &mut errors);
    config.mcp = entries(&mut map, "mcp", &mut errors);
    config.imps = entries(&mut map, "imps", &mut errors);
    config.permissions = items(&mut map, "permissions", &mut errors);
    config.triggers = take(&mut map, "triggers", &mut errors).unwrap_or_default();
    config.animations = take(&mut map, "animations", &mut errors).unwrap_or_default();
    config.requests = take(&mut map, "requests", &mut errors);
    config.talk = take(&mut map, "talk", &mut errors);
    config.link = take(&mut map, "link", &mut errors);
    config.extra = map.into_iter().collect();
    for e in errors {
        note(&mut diags, e);
    }
    (config, diags)
}

fn take<T: DeserializeOwned>(
    map: &mut Map<String, Value>,
    key: &str,
    errors: &mut Vec<String>,
) -> Option<T> {
    let value = map.remove(key)?;
    match serde_json::from_value(value) {
        Ok(v) => Some(v),
        Err(e) => {
            errors.push(format!("{key}: {e}"));
            None
        }
    }
}

fn entries<T: DeserializeOwned>(
    map: &mut Map<String, Value>,
    key: &str,
    errors: &mut Vec<String>,
) -> BTreeMap<String, T> {
    let mut out = BTreeMap::new();
    match map.remove(key) {
        None => {}
        Some(Value::Object(entries)) => {
            for (name, value) in entries {
                match serde_json::from_value(value) {
                    Ok(v) => {
                        out.insert(name, v);
                    }
                    Err(e) => errors.push(format!("{key}.{name}: {e}")),
                }
            }
        }
        Some(_) => errors.push(format!("{key}: must be an object")),
    }
    out
}

fn items<T: DeserializeOwned>(
    map: &mut Map<String, Value>,
    key: &str,
    errors: &mut Vec<String>,
) -> Vec<T> {
    let mut out = Vec::new();
    match map.remove(key) {
        None => {}
        Some(Value::Array(list)) => {
            for (i, value) in list.into_iter().enumerate() {
                match serde_json::from_value(value) {
                    Ok(v) => out.push(v),
                    Err(e) => errors.push(format!("{key}[{i}]: {e}")),
                }
            }
        }
        Some(_) => errors.push(format!("{key}: must be a list")),
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::config::Env;
    use serde_json::json;

    const SAMPLE: &str = r#"{
      "model": "openrouter/openai/gpt-6-luna",
      "providers": {
        "openrouter": {"name": "OpenRouter", "options": {"baseURL": "https://openrouter.ai/api/v1"}},
        "ollama": {"options": {"baseURL": "https://o/v1", "apiKey": "{env:OLLAMA_API_KEY}", "headers": {"X-T": "e"}},
                   "models": {"qwen3.8": {"variants": {"high": {"reasoning_effort": "high"}}}}}
      },
      "mcp": {
        "files": {"type": "local", "command": ["npx", "-y", "srv", "~"], "environment": {"A": "1"}},
        "den": {"type": "remote", "url": "https://den.imp.land/mcp", "oauth": false, "timeout": 5000}
      },
      "permissions": [{"action": "shell", "resource": "rm -rf *", "effect": "deny"}],
      "imps": {"Pip": {"id": "7c0e0000-0000-4000-8000-000000000001", "size": 1.0, "memory": {"exchanges": 20}}},
      "requests": {"timeoutSeconds": 90, "retries": 2},
      "link": {"hop": "hop.example.com:4677"},
      "future": {"x": 1}
    }"#;

    #[test]
    fn reads_the_whole_shape() {
        let (c, diags) = parse_config(SAMPLE, None, None);
        assert!(diags.is_empty(), "{diags:?}");
        assert_eq!(c.model.as_deref(), Some("openrouter/openai/gpt-6-luna"));
        assert_eq!(
            c.providers["openrouter"].name.as_deref(),
            Some("OpenRouter")
        );
        let ollama = &c.providers["ollama"];
        assert_eq!(ollama.options.headers["X-T"], "e");
        assert_eq!(
            ollama.models["qwen3.8"].variants["high"],
            json!({"reasoning_effort": "high"})
        );
        assert!(matches!(&c.mcp["files"], McpServer::Local { command, .. } if command.len() == 4));
        assert!(matches!(
            &c.mcp["den"],
            McpServer::Remote {
                oauth: Some(McpOAuth::Off(false)),
                timeout: Some(5000),
                ..
            }
        ));
        assert_eq!(c.imps["Pip"].memory.as_ref().unwrap().exchanges, Some(20));
        assert_eq!(c.requests.as_ref().unwrap().limits().retries, 2);
        assert_eq!(c.link.unwrap().hop.as_deref(), Some("hop.example.com:4677"));
        assert_eq!(c.extra["future"], json!({"x": 1}));
    }

    #[test]
    fn strict_and_lenient_reads_agree_on_good_text() {
        let (lenient, _) = parse_config(SAMPLE, None, None);
        let strict: ImpConfig = serde_json::from_str(SAMPLE).unwrap();
        assert_eq!(lenient, strict);
    }

    #[test]
    fn a_broken_entry_is_a_diagnostic() {
        let text = r#"{
          "model": 5,
          "providers": {"ok": {}, "bad": {"options": 3}},
          "mcp": {"x": {"type": "carrier-pigeon"}, "y": {"type": "remote", "url": "u"}},
          "permissions": [{"action": "a", "effect": "deny"}, {"effect": "deny"}, {"action": "a", "effect": "no"}],
          "imps": {"Pip": {"size": 2}},
          "triggers": "nope"
        }"#;
        let (c, diags) = parse_config(text, Some(Path::new("/c/imp.json")), None);
        assert!(c.model.is_none());
        assert_eq!(c.providers.keys().collect::<Vec<_>>(), ["ok"]);
        assert_eq!(c.mcp.keys().collect::<Vec<_>>(), ["y"]);
        assert_eq!(c.permissions.len(), 1);
        assert!(c.imps.is_empty() && c.triggers.is_empty());
        let said: Vec<String> = diags.iter().map(|d| d.message.clone()).collect();
        for part in [
            "model:",
            "providers.bad:",
            "mcp.x:",
            "permissions[1]:",
            "permissions[2]:",
            "imps.Pip:",
            "triggers:",
        ] {
            assert!(
                said.iter().any(|m| m.starts_with(part)),
                "{part} in {said:?}"
            );
        }
        assert!(
            diags
                .iter()
                .all(|d| d.file.as_deref() == Some(Path::new("/c/imp.json")))
        );
    }

    #[test]
    fn invalid_json_is_one_diagnostic() {
        for text in ["{", "[]", "3"] {
            let (c, diags) = parse_config(text, None, None);
            assert_eq!(c, ImpConfig::default());
            assert_eq!(diags.len(), 1);
        }
    }

    #[test]
    fn substitution_runs_before_reading() {
        let env = Env::new(&[("OLLAMA_API_KEY", "sk-1")], None);
        let (c, diags) = parse_config(SAMPLE, None, Some(&env));
        assert!(diags.is_empty());
        assert_eq!(
            c.providers["ollama"].options.api_key.as_deref(),
            Some("sk-1")
        );
        let (c, diags) = parse_config(
            SAMPLE,
            Some(Path::new("/c/imp.json")),
            Some(&Env::new(&[], None)),
        );
        assert_eq!(c.providers["ollama"].options.api_key.as_deref(), Some(""));
        assert!(diags[0].message.contains("OLLAMA_API_KEY"));
    }

    #[test]
    fn keys_come_from_options_or_auth() {
        let mut auth = Auth::default();
        auth.providers.insert(
            "p".into(),
            ProviderAuth {
                key: "saved".into(),
            },
        );
        let mut provider = Provider::default();
        assert_eq!(auth.key_for("p", Some(&provider)).as_deref(), Some("saved"));
        provider.options.api_key = Some("typed".into());
        assert_eq!(auth.key_for("p", Some(&provider)).as_deref(), Some("typed"));
        provider.options.api_key = Some(String::new());
        assert_eq!(auth.key_for("p", Some(&provider)).as_deref(), Some("saved"));
        assert_eq!(auth.key_for("q", None), None);
        assert!(!format!("{:?}", auth).contains("saved"));
    }

    #[test]
    fn ids_are_random_version_4() {
        let (a, b) = (new_id(), new_id());
        assert_ne!(a, b);
        assert_eq!(a.get_version_num(), 4);
    }
}
