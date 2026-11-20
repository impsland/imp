//! `imp mcp`: the tool servers in `mcp` of `imp.json`, and which agents use them.

use super::{check_id, name_of, own_agent};
use crate::commands::reply::{Reply, cleared, pairs};
use crate::settings::Settings;
use crate::{CliError, Result};
use imp_engine::config::{Effect, McpServer, decide, effective_rules, set_mcp_server};
use serde_json::{Value, json};

fn target(server: &McpServer) -> (&'static str, String) {
    match server {
        McpServer::Local { command, .. } => ("local", command.join(" ")),
        McpServer::Remote { url, .. } => ("remote", url.clone()),
    }
}

pub fn list(settings: &Settings, agent: Option<&str>) -> Result<Reply> {
    let loaded = settings.load();
    let for_agent = match agent {
        Some(n) => Some(
            loaded
                .agents
                .get(&name_of(&loaded, n))
                .map(|a| a.value.clone())
                .ok_or_else(|| CliError(format!("There is no agent called {n}.")))?,
        ),
        None => None,
    };
    let mut rows = Vec::new();
    let mut json = Vec::new();
    for (name, server) in &loaded.config.mcp {
        let (kind, to) = target(server);
        let on = !server.disabled()
            && for_agent.as_ref().is_none_or(|a| {
                decide(
                    &effective_rules(&loaded.config, a),
                    "mcp",
                    &format!("{name}/*"),
                ) != Effect::Deny
            });
        let signed_in = loaded.auth.mcp.contains_key(name);
        rows.push(vec![
            name.clone(),
            kind.into(),
            to.clone(),
            if on { "on" } else { "off" }.into(),
        ]);
        json.push(
            json!({ "name": name, "type": kind, "target": to, "on": on, "signedIn": signed_in }),
        );
    }
    Ok(Reply::table(
        vec!["NAME", "TYPE", "TARGET", "STATE"],
        rows,
        Value::Array(json),
    ))
}

pub fn add(
    settings: &Settings,
    name: &str,
    command: Vec<String>,
    url: Option<String>,
    env: &[String],
    headers: &[String],
) -> Result<Reply> {
    check_id("tool server", name)?;
    let env = pairs(env, "--env")?;
    let headers = pairs(headers, "--header")?;
    let server = match (command.is_empty(), url) {
        (false, None) => {
            if !headers.is_empty() {
                return Err(CliError(
                    "--header is for a server at an address (--url).".into(),
                ));
            }
            McpServer::Local {
                command,
                cwd: None,
                environment: env.into_iter().collect(),
                disabled: false,
                timeout: None,
            }
        }
        (true, Some(url)) => {
            if !env.is_empty() {
                return Err(CliError("--env is for a program (--command).".into()));
            }
            if !url.starts_with("http://") && !url.starts_with("https://") {
                return Err(CliError(format!(
                    "{url:?} is not an address: it starts with http:// or https://."
                )));
            }
            McpServer::Remote {
                url,
                headers: headers.into_iter().collect(),
                oauth: None,
                disabled: false,
                timeout: None,
            }
        }
        _ => {
            return Err(CliError(
                "Give --command PROGRAM ARGS or --url ADDRESS.".into(),
            ));
        }
    };
    settings.store.update(|c| {
        if c.mcp.contains_key(name) {
            return Err(CliError(format!("There is already a tool server {name}.")));
        }
        c.mcp.insert(name.to_string(), server);
        Ok(())
    })??;
    Ok(Reply::done(
        format!("Added {name}."),
        json!({ "name": name }),
    ))
}

pub fn set(settings: &Settings, name: &str, key: &str, value: &str) -> Result<Reply> {
    let clear = cleared(value);
    settings.store.update(|c| {
        let server = c
            .mcp
            .get_mut(name)
            .ok_or_else(|| CliError(format!("There is no tool server {name}. `imp mcp list` shows them.")))?;
        match (key, server) {
            ("command", McpServer::Local { command, .. }) => {
                let words: Vec<String> = value.split_whitespace().map(str::to_string).collect();
                if clear || words.is_empty() {
                    return Err(CliError("A program needs its command.".into()));
                }
                *command = words;
            }
            ("cwd", McpServer::Local { cwd, .. }) => *cwd = (!clear).then(|| value.to_string()),
            ("url", McpServer::Remote { url, .. }) => {
                if clear {
                    return Err(CliError("A server at an address needs its url.".into()));
                }
                *url = value.to_string();
            }
            ("timeout", McpServer::Local { timeout, .. } | McpServer::Remote { timeout, .. }) => {
                *timeout = if clear {
                    None
                } else {
                    Some(value.parse().map_err(|_| {
                        CliError(format!("{value:?} is not a number of milliseconds."))
                    })?)
                }
            }
            (other, McpServer::Local { environment, .. }) if other.starts_with("env.") => {
                let var = &other[4..];
                if clear {
                    environment.remove(var);
                } else {
                    environment.insert(var.to_string(), value.to_string());
                }
            }
            (other, McpServer::Remote { headers, .. }) if other.starts_with("header.") => {
                let header = &other[7..];
                if clear {
                    headers.remove(header);
                } else {
                    headers.insert(header.to_string(), value.to_string());
                }
            }
            (other, _) => {
                return Err(CliError(format!(
                    "{other:?} is not a setting of this tool server. A program has command, cwd, timeout and env.NAME; a server at an address has url, timeout and header.NAME."
                )));
            }
        }
        Ok(())
    })??;
    Ok(Reply::done(
        format!("{name} {key} {}.", if clear { "cleared" } else { "set" }),
        json!({ "name": name, "key": key }),
    ))
}

pub fn remove(settings: &Settings, name: &str) -> Result<Reply> {
    settings.store.update(|c| {
        c.mcp
            .remove(name)
            .map(|_| ())
            .ok_or_else(|| CliError(format!("There is no tool server {name}.")))
    })??;
    settings.store.update_auth(|a| a.mcp.remove(name))?;
    Ok(Reply::done(
        format!("Removed {name}."),
        json!({ "name": name }),
    ))
}

pub fn enable(settings: &Settings, name: &str, agent: Option<&str>, on: bool) -> Result<Reply> {
    let loaded = settings.load();
    if !loaded.config.mcp.contains_key(name) {
        return Err(CliError(format!(
            "There is no tool server {name}. `imp mcp list` shows them."
        )));
    }
    let state = if on { "on" } else { "off" };
    match agent {
        Some(who) => {
            let mut a = own_agent(settings, &loaded, who)?;
            set_mcp_server(&loaded.config, &mut a, name, on);
            settings.store.write_agent(&a)?;
            Ok(Reply::done(
                format!("{name} is {state} for {}.", a.name),
                json!({ "name": name, "agent": a.name, "on": on }),
            ))
        }
        None => {
            settings.store.update(|c| {
                if let Some(s) = c.mcp.get_mut(name) {
                    s.set_disabled(!on);
                }
            })?;
            Ok(Reply::done(
                format!("{name} is {state}."),
                json!({ "name": name, "on": on }),
            ))
        }
    }
}
