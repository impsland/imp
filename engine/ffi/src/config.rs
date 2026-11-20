//! The shared configuration for the Mac app (`docs/architecture/configuration.md`): `imp.json`,
//! `auth.json` and the agent files in `~/.agents`, found, read and written by `imp_engine::config`.
//!
//! Documents cross as JSON text (an `imp.json` has open-ended parts: the app reads the parts it knows
//! and writes a *merge patch* of the parts it owns, so what it does not know, and what the terminal
//! app changed meanwhile, is kept). A patch follows RFC 7396: an object merges into the existing one,
//! `null` removes a key, anything else (a list included) replaces. Every write re-reads the file under
//! the lock first. The folders are passed in, so tests never touch the person's own.

use imp_engine::config::{
    self, Agent, Auth, Effect, Env, ImpConfig, ModelRef, ProviderAuth, Rule, Store, TrustStore,
};
use serde_json::{Map, Value};
use std::path::{Path, PathBuf};

#[derive(Debug, uniffi::Error)]
pub enum ConfigFailure {
    /// What went wrong, as a sentence.
    Failed { message: String },
}

impl std::fmt::Display for ConfigFailure {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        let Self::Failed { message } = self;
        f.write_str(message)
    }
}

fn failed(e: impl std::fmt::Display) -> ConfigFailure {
    ConfigFailure::Failed {
        message: e.to_string(),
    }
}

/// Where the files are: the config folder and the person's home folder (`~/.agents` is in it).
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct ConfigPaths {
    pub config_dir: String,
    pub home_dir: String,
}

/// The folders this process uses: `$IMP_CONFIG_HOME`, else `$XDG_CONFIG_HOME/imp`, else
/// `~/.config/imp`, and the home folder. `None` when there is no home folder.
#[uniffi::export]
pub fn config_default_paths() -> Option<ConfigPaths> {
    let env = Env::process();
    Some(ConfigPaths {
        config_dir: env.config_dir()?.to_string_lossy().into_owned(),
        home_dir: env.home_dir()?.to_string_lossy().into_owned(),
    })
}

fn store(paths: &ConfigPaths) -> Store {
    Store::new(
        PathBuf::from(&paths.config_dir),
        Path::new(&paths.home_dir).join(".agents"),
    )
}

/// One agent file as it is on disk: its front matter keys and `body` (the prompt) as a JSON object.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct ConfigAgent {
    pub name: String,
    pub json: String,
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct ConfigSnapshot {
    /// `imp.json` as it is on disk, with nothing filled in, as JSON.
    pub config_json: String,
    /// Every agent file of `~/.agents/agents` that can be read, by name.
    pub agents: Vec<ConfigAgent>,
    /// The providers that have a key now: `options.apiKey` filled in, else the one saved in `auth.json`.
    pub keyed_providers: Vec<String>,
    /// Files that could not be used, in plain words. The rest loaded.
    pub diagnostics: Vec<String>,
    /// Changes when a file does (see `config_stamp`).
    pub stamp: String,
}

fn agent_json(agent: &Agent) -> String {
    let mut value = serde_json::to_value(agent).unwrap_or(Value::Null);
    if let Value::Object(map) = &mut value {
        map.insert("body".into(), Value::String(agent.body.clone()));
    }
    value.to_string()
}

fn agent_names(store: &Store) -> Vec<String> {
    let dir = store.agent_path("x");
    let Some(dir) = dir.parent() else {
        return Vec::new();
    };
    let mut names: Vec<String> = std::fs::read_dir(dir)
        .map(|rd| {
            rd.filter_map(|e| e.ok())
                .filter_map(|e| {
                    let path = e.path();
                    (path.extension().is_some_and(|x| x == "md"))
                        .then(|| path.file_stem().map(|s| s.to_string_lossy().into_owned()))
                        .flatten()
                })
                .filter(|n| config::valid_agent_name(n))
                .collect()
        })
        .unwrap_or_default();
    names.sort();
    names
}

fn env_for(paths: &ConfigPaths) -> Env {
    let vars: Vec<(String, String)> = std::env::vars().collect();
    let mut refs: Vec<(&str, &str)> = vars
        .iter()
        .filter(|(k, _)| k != "IMP_CONFIG_HOME")
        .map(|(k, v)| (k.as_str(), v.as_str()))
        .collect();
    refs.push(("IMP_CONFIG_HOME", &paths.config_dir));
    Env::new(&refs, Some(Path::new(&paths.home_dir)))
}

/// Reads everything. A file that is broken is a diagnostic and the rest still loads.
#[uniffi::export]
pub fn config_load(paths: ConfigPaths) -> ConfigSnapshot {
    let store = store(&paths);
    let loaded = config::load(&env_for(&paths), None, &TrustStore::default());
    let mut diagnostics: Vec<String> = loaded.diagnostics.iter().map(|d| d.to_string()).collect();
    let config = store.read_config().unwrap_or_else(|e| {
        diagnostics.push(e.to_string());
        ImpConfig::default()
    });
    let mut agents = Vec::new();
    for name in agent_names(&store) {
        match store.read_agent(&name) {
            Ok(agent) => agents.push(ConfigAgent {
                json: agent_json(&agent),
                name,
            }),
            Err(e) => diagnostics.push(e.to_string()),
        }
    }
    let keyed_providers = loaded
        .config
        .providers
        .iter()
        .filter(|(name, p)| loaded.auth.key_for(name, Some(p)).is_some())
        .map(|(name, _)| name.clone())
        .chain(
            loaded
                .auth
                .providers
                .keys()
                .filter(|n| !loaded.config.providers.contains_key(*n))
                .cloned(),
        )
        .collect();
    ConfigSnapshot {
        config_json: serde_json::to_string(&config).unwrap_or_else(|_| "{}".into()),
        agents,
        keyed_providers,
        diagnostics,
        stamp: config_stamp(paths),
    }
}

/// A skill of `~/.agents/skills`: what it is for, and the file it is in.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct ConfigSkill {
    pub name: String,
    pub description: String,
    pub path: String,
}

/// A command of `~/.agents/commands`, run as `/name`.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct ConfigCommand {
    pub name: String,
    pub description: String,
    pub path: String,
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct ConfigLibrary {
    pub skills: Vec<ConfigSkill>,
    pub commands: Vec<ConfigCommand>,
}

/// The skills and commands the person has in `~/.agents` (the app lists them; it does not edit them).
#[uniffi::export]
pub fn config_library(paths: ConfigPaths) -> ConfigLibrary {
    let loaded = config::load(&env_for(&paths), None, &TrustStore::default());
    ConfigLibrary {
        skills: loaded
            .skills
            .iter()
            .map(|(name, s)| ConfigSkill {
                name: name.clone(),
                description: s.value.description.clone(),
                path: s.path.display().to_string(),
            })
            .collect(),
        commands: loaded
            .commands
            .iter()
            .map(|(name, c)| ConfigCommand {
                name: name.clone(),
                description: c.value.description.clone().unwrap_or_default(),
                path: c.path.display().to_string(),
            })
            .collect(),
    }
}

/// A cheap value that changes when `imp.json`, `auth.json` or an agent file does (names, sizes and
/// modification times: no file is read). For a timer to compare.
#[uniffi::export]
pub fn config_stamp(paths: ConfigPaths) -> String {
    use std::fmt::Write;
    let store = store(&paths);
    let mut out = String::new();
    let mut files = vec![store.config_path(), store.auth_path()];
    files.extend(agent_names(&store).iter().map(|n| store.agent_path(n)));
    for file in files {
        let stat = std::fs::metadata(&file).ok().map(|m| {
            let nanos = m
                .modified()
                .ok()
                .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
                .map_or(0, |d| d.as_nanos());
            (m.len(), nanos)
        });
        let _ = match stat {
            Some((len, nanos)) => writeln!(out, "{}:{len}:{nanos}", file.display()),
            None => writeln!(out, "{}:-", file.display()),
        };
    }
    out
}

/// RFC 7396: objects merge, `null` removes, anything else replaces.
fn merge_patch(target: &mut Value, patch: Value) {
    match patch {
        Value::Object(patch) => {
            if !target.is_object() {
                *target = Value::Object(Map::new());
            }
            let Value::Object(map) = target else { return };
            for (key, value) in patch {
                if value.is_null() {
                    map.remove(&key);
                } else {
                    merge_patch(map.entry(key).or_insert(Value::Null), value);
                }
            }
        }
        other => *target = other,
    }
}

fn parse_patch(text: &str) -> Result<Value, ConfigFailure> {
    match serde_json::from_str(text).map_err(failed)? {
        v @ Value::Object(_) => Ok(v),
        _ => Err(failed("a patch must be a JSON object")),
    }
}

/// Merges `patch_json` into `imp.json`, re-reading the file under the lock. Nothing is written when
/// the result is the same.
#[uniffi::export]
pub fn config_update(paths: ConfigPaths, patch_json: String) -> Result<(), ConfigFailure> {
    let patch = parse_patch(&patch_json)?;
    store(&paths)
        .update(|config| -> Result<(), ConfigFailure> {
            let mut value = serde_json::to_value(&*config).map_err(failed)?;
            merge_patch(&mut value, patch);
            *config = serde_json::from_value(value).map_err(failed)?;
            Ok(())
        })
        .map_err(failed)?
}

/// Merges `patch_json` into the agent's front matter, and its `body` key (if the patch has one) into
/// the prompt. A file that is not there is made.
#[uniffi::export]
pub fn config_update_agent(
    paths: ConfigPaths,
    name: String,
    patch_json: String,
) -> Result<(), ConfigFailure> {
    let mut patch = parse_patch(&patch_json)?;
    let body = match patch.as_object_mut().and_then(|m| m.remove("body")) {
        Some(Value::String(text)) => Some(text),
        Some(_) => return Err(failed("body must be text")),
        None => None,
    };
    store(&paths)
        .update_agent(&name, |agent| -> Result<(), ConfigFailure> {
            let mut value = serde_json::to_value(&*agent).map_err(failed)?;
            merge_patch(&mut value, patch);
            let mut next: Agent = serde_json::from_value(value).map_err(failed)?;
            next.name = std::mem::take(&mut agent.name);
            next.body = body.unwrap_or_else(|| std::mem::take(&mut agent.body));
            *agent = next;
            Ok(())
        })
        .map_err(failed)?
}

#[uniffi::export]
pub fn config_rename_agent(
    paths: ConfigPaths,
    old: String,
    new: String,
) -> Result<(), ConfigFailure> {
    store(&paths).rename_agent(&old, &new).map_err(failed)
}

#[uniffi::export]
pub fn config_remove_agent(paths: ConfigPaths, name: String) -> Result<(), ConfigFailure> {
    store(&paths).remove_agent(&name).map_err(failed)
}

// auth.json

/// Saves the key typed for a provider, readable by the person only. An empty key removes it.
#[uniffi::export]
pub fn auth_set_key(
    paths: ConfigPaths,
    provider: String,
    key: String,
) -> Result<(), ConfigFailure> {
    store(&paths)
        .update_auth(|auth| {
            if key.is_empty() {
                auth.providers.remove(&provider);
            } else {
                auth.providers.insert(provider, ProviderAuth { key });
            }
        })
        .map_err(failed)
}

/// The key a provider is used with: `options.apiKey` (filled in) when set, else the saved one.
#[uniffi::export]
pub fn auth_key(paths: ConfigPaths, provider: String) -> Option<String> {
    let loaded = config::load(&env_for(&paths), None, &TrustStore::default());
    loaded
        .auth
        .key_for(&provider, loaded.config.providers.get(&provider))
}

/// A sign-in saved for an MCP server, by the server's name.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct AuthMcpEntry {
    pub server: String,
    pub auth: crate::McpAuth,
}

#[uniffi::export]
pub fn auth_mcp_all(paths: ConfigPaths) -> Result<Vec<AuthMcpEntry>, ConfigFailure> {
    let auth: Auth = store(&paths).read_auth().map_err(failed)?;
    Ok(auth
        .mcp
        .into_iter()
        .map(|(server, a)| AuthMcpEntry {
            server,
            auth: a.into(),
        })
        .collect())
}

/// Saves (`Some`) or forgets (`None`) the sign-in of an MCP server.
#[uniffi::export]
pub fn auth_mcp_set(
    paths: ConfigPaths,
    server: String,
    auth: Option<crate::McpAuth>,
) -> Result<(), ConfigFailure> {
    store(&paths)
        .update_auth(|a| match auth {
            Some(v) => {
                a.mcp.insert(server, v.into());
            }
            None => {
                a.mcp.remove(&server);
            }
        })
        .map_err(failed)
}

// Permissions

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum PermissionEffect {
    Allow,
    Ask,
    Deny,
}

impl From<Effect> for PermissionEffect {
    fn from(e: Effect) -> Self {
        match e {
            Effect::Allow => Self::Allow,
            Effect::Ask => Self::Ask,
            Effect::Deny => Self::Deny,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct PermissionRule {
    pub action: String,
    pub resource: String,
    pub effect: PermissionEffect,
}

impl From<PermissionRule> for Rule {
    fn from(r: PermissionRule) -> Self {
        Rule::new(
            &r.action,
            &r.resource,
            match r.effect {
                PermissionEffect::Allow => Effect::Allow,
                PermissionEffect::Ask => Effect::Ask,
                PermissionEffect::Deny => Effect::Deny,
            },
        )
    }
}

impl From<Rule> for PermissionRule {
    fn from(r: Rule) -> Self {
        Self {
            action: r.action,
            resource: r.resource,
            effect: r.effect.into(),
        }
    }
}

fn setup(global: Vec<PermissionRule>, own: Vec<PermissionRule>) -> (ImpConfig, Agent) {
    let config = ImpConfig {
        permissions: global.into_iter().map(Rule::from).collect(),
        ..ImpConfig::default()
    };
    let agent = Agent {
        permissions: own.into_iter().map(Rule::from).collect(),
        ..Agent::default()
    };
    (config, agent)
}

/// What the rules say about `action` on `resource` for an agent with the rules `own`, under the
/// built-in defaults and the settings' rules `global`: the last one that matches decides.
#[uniffi::export]
pub fn permission_decide(
    global: Vec<PermissionRule>,
    own: Vec<PermissionRule>,
    action: String,
    resource: String,
) -> PermissionEffect {
    let (config, agent) = setup(global, own);
    config::decide(
        &config::effective_rules(&config, &agent),
        &action,
        &resource,
    )
    .into()
}

/// The agent's rules after making `action` on `resource` allowed (`on`) or denied, with as few rules
/// as it takes (a switched-off group is `{group, *, deny}`; an MCP server is a rule on `mcp` with the resource `<server>/` and a star).
#[uniffi::export]
pub fn permission_set(
    global: Vec<PermissionRule>,
    own: Vec<PermissionRule>,
    action: String,
    resource: String,
    on: bool,
) -> Vec<PermissionRule> {
    let (config, mut agent) = setup(global, own);
    config::set_rule(&config, &mut agent, &action, &resource, on);
    agent.permissions.into_iter().map(Into::into).collect()
}

/// What a tool call is for the rules (`imp_engine::config::classify`).
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct PermissionCall {
    pub action: String,
    pub resource: String,
}

/// The action and resource of a tool call: the one classification the terminal app uses too. `tool_id`
/// is the tool's registry id when it has one (`own.look.imp_set_traits`, `mcp.files.read_file`),
/// `servers` the names of the MCP servers.
#[uniffi::export]
pub fn permission_classify(
    tool_id: Option<String>,
    tool_name: String,
    arguments_json: String,
    servers: Vec<String>,
) -> PermissionCall {
    let p = config::classify(tool_id.as_deref(), &tool_name, &arguments_json, &servers);
    PermissionCall {
        action: p.action,
        resource: p.resource,
    }
}

/// What the rules say about one tool call, and what it is.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct GateVerdict {
    pub effect: PermissionEffect,
    pub action: String,
    pub resource: String,
}

/// The verdict on a tool call of `agent`, by the rules as they are on disk now: the defaults, `imp.json`'s
/// and the agent's own. A file that can't be read is a `deny` (nothing is let through on a guess).
#[uniffi::export]
pub fn config_gate(
    paths: ConfigPaths,
    agent: String,
    tool_id: Option<String>,
    tool_name: String,
    arguments_json: String,
) -> GateVerdict {
    let store = store(&paths);
    let call = |effect: PermissionEffect, servers: &[String]| {
        let p = config::classify(tool_id.as_deref(), &tool_name, &arguments_json, servers);
        GateVerdict {
            effect,
            action: p.action,
            resource: p.resource,
        }
    };
    let loaded = store.read_config().and_then(|config| {
        let agent = if store.agent_path(&agent).exists() {
            store.read_agent(&agent)?
        } else {
            Agent {
                name: agent.clone(),
                ..Agent::default()
            }
        };
        Ok((config, agent))
    });
    let Ok((config, agent)) = loaded else {
        return call(PermissionEffect::Deny, &[]);
    };
    let servers: Vec<String> = config.mcp.keys().cloned().collect();
    let (effect, p) = config::judge(
        &config::effective_rules(&config, &agent),
        Some(&paths.home_dir),
        tool_id.as_deref(),
        &tool_name,
        &arguments_json,
        &servers,
    );
    GateVerdict {
        effect: effect.into(),
        action: p.action,
        resource: p.resource,
    }
}

/// Adds `allow` for `action` on `resource` to the agent's own rules (the person chose Always). It is the
/// last rule, so it wins over what came before; one already there is not repeated.
#[uniffi::export]
pub fn config_allow_always(
    paths: ConfigPaths,
    agent: String,
    action: String,
    resource: String,
) -> Result<(), ConfigFailure> {
    let rule = Rule::new(&action, &resource, Effect::Allow);
    store(&paths)
        .update_agent(&agent, |a| {
            if a.permissions.last() != Some(&rule) {
                a.permissions.push(rule);
            }
        })
        .map_err(failed)
}

// Models

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct ModelParts {
    pub provider: String,
    pub model: String,
    pub variant: Option<String>,
}

/// Reads `provider/model#variant`.
#[uniffi::export]
pub fn model_ref_parse(text: String) -> Result<ModelParts, ConfigFailure> {
    let r = ModelRef::parse(&text).map_err(failed)?;
    Ok(ModelParts {
        provider: r.provider,
        model: r.model,
        variant: r.variant,
    })
}

#[uniffi::export]
pub fn model_ref_format(parts: ModelParts) -> String {
    ModelRef {
        provider: parts.provider,
        model: parts.model,
        variant: parts.variant,
    }
    .to_string()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn paths(dir: &Path) -> ConfigPaths {
        ConfigPaths {
            config_dir: dir.join("cfg").to_string_lossy().into_owned(),
            home_dir: dir.join("home").to_string_lossy().into_owned(),
        }
    }

    #[test]
    fn a_patch_keeps_what_it_does_not_name_and_removes_nulls() {
        let dir = tempfile::tempdir().unwrap();
        let p = paths(dir.path());
        let first =
            r#"{"model":"a/b","future":{"x":1},"providers":{"a":{"options":{"baseURL":"u"}}}}"#;
        config_update(p.clone(), first.into()).unwrap();
        let patch = r#"{"model":null,"providers":{"b":{"name":"B"}},"requests":{"retries":2}}"#;
        config_update(p.clone(), patch.into()).unwrap();
        let snap = config_load(p.clone());
        let v: Value = serde_json::from_str(&snap.config_json).unwrap();
        assert!(v.get("model").is_none());
        assert_eq!(v["future"]["x"], 1);
        assert_eq!(v["providers"]["a"]["options"]["baseURL"], "u");
        assert_eq!(v["providers"]["b"]["name"], "B");
        assert_eq!(v["requests"]["retries"], 2);
        assert!(config_update(p, "[1]".into()).is_err());
    }

    #[test]
    fn agents_are_patched_listed_and_stamped() {
        let dir = tempfile::tempdir().unwrap();
        let p = paths(dir.path());
        let before = config_stamp(p.clone());
        let patch = r##"{"mode":"primary","color":"#e0533d","body":"Be Pip."}"##;
        config_update_agent(p.clone(), "pip".into(), patch.into()).unwrap();
        config_update_agent(p.clone(), "pip".into(), r#"{"description":"Small"}"#.into()).unwrap();
        let snap = config_load(p.clone());
        assert_ne!(before, snap.stamp);
        let v: Value = serde_json::from_str(&snap.agents[0].json).unwrap();
        assert_eq!(snap.agents[0].name, "pip");
        assert_eq!(
            (v["body"].as_str(), v["description"].as_str()),
            (Some("Be Pip."), Some("Small"))
        );
        assert_eq!(v["mode"], "primary");
        config_rename_agent(p.clone(), "pip".into(), "pop".into()).unwrap();
        assert_eq!(config_load(p.clone()).agents[0].name, "pop");
        config_remove_agent(p.clone(), "pop".into()).unwrap();
        assert!(config_load(p).agents.is_empty());
    }

    #[test]
    fn keys_are_saved_and_found() {
        let dir = tempfile::tempdir().unwrap();
        let p = paths(dir.path());
        auth_set_key(p.clone(), "ollama".into(), "sk-1".into()).unwrap();
        assert_eq!(
            auth_key(p.clone(), "ollama".into()).as_deref(),
            Some("sk-1")
        );
        assert_eq!(config_load(p.clone()).keyed_providers, ["ollama"]);
        auth_set_key(p.clone(), "ollama".into(), String::new()).unwrap();
        assert_eq!(auth_key(p, "ollama".into()), None);
    }

    #[test]
    fn the_gate_reads_the_rules_on_disk_and_always_adds_an_allow() {
        let dir = tempfile::tempdir().unwrap();
        let p = paths(dir.path());
        config_update(
            p.clone(),
            r#"{"permissions":[{"action":"shell","resource":"rm -rf *","effect":"deny"}]}"#.into(),
        )
        .unwrap();
        config_update_agent(
            p.clone(),
            "pip".into(),
            r#"{"permissions":[{"action":"mcp","resource":"files/*","effect":"ask"}]}"#.into(),
        )
        .unwrap();
        let gate = |id: Option<&str>, tool: &str, args: &str| {
            config_gate(
                p.clone(),
                "pip".into(),
                id.map(Into::into),
                tool.into(),
                args.into(),
            )
        };
        let denied = gate(None, "shell", r#"{"command":"rm -rf /"}"#);
        assert_eq!(denied.effect, PermissionEffect::Deny);
        assert_eq!(
            (denied.action.as_str(), denied.resource.as_str()),
            ("shell", "rm -rf /")
        );
        assert_eq!(
            gate(None, "shell", r#"{"command":"ls"}"#).effect,
            PermissionEffect::Allow
        );
        // The agent has no file of its own for `mo`: the defaults and imp.json's rules apply.
        let other = config_gate(
            p.clone(),
            "mo".into(),
            None,
            "computer_act".into(),
            "{}".into(),
        );
        assert_eq!(other.effect, PermissionEffect::Deny);
        let id = Some("mcp.files.write_file");
        let asked = gate(id, "files_write_file", "{}");
        assert_eq!(asked.effect, PermissionEffect::Ask);
        assert_eq!(asked.resource, "files/write_file");
        config_allow_always(p.clone(), "pip".into(), asked.action, asked.resource).unwrap();
        assert_eq!(
            gate(id, "files_write_file", "{}").effect,
            PermissionEffect::Allow
        );
        assert_eq!(
            gate(Some("mcp.files.read_file"), "files_read_file", "{}").effect,
            PermissionEffect::Ask
        );
    }

    #[test]
    fn switches_become_the_fewest_rules() {
        let off = permission_set(vec![], vec![], "look".into(), "*".into(), false);
        assert_eq!(off.len(), 1);
        let d = |own: &[PermissionRule]| {
            permission_decide(vec![], own.to_vec(), "look".into(), "x".into())
        };
        assert_eq!(d(&off), PermissionEffect::Deny);
        let on = permission_set(vec![], off, "look".into(), "*".into(), true);
        assert!(on.is_empty());
        let computer = permission_set(vec![], vec![], "computer".into(), "*".into(), true);
        assert_eq!(computer.len(), 1);
    }

    #[test]
    fn model_refs_round_trip() {
        let m = model_ref_parse("openrouter/openai/gpt-6#high".into()).unwrap();
        assert_eq!(m.model, "openai/gpt-6");
        assert_eq!(model_ref_format(m), "openrouter/openai/gpt-6#high");
        assert!(model_ref_parse("nope".into()).is_err());
    }
}
