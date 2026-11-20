//! `imp agent` and the agent files behind it.

use super::{name_of, own_agent};
use crate::commands::reply::{Reply, cleared};
use crate::settings::Settings;
use crate::{CliError, Result};
use imp_engine::config::{Agent, ImpExtras, Mode, ModelRef, Scope, valid_agent_name};
use serde_json::{Value, json};
use std::path::Path;

fn mode_name(mode: Mode) -> &'static str {
    match mode {
        Mode::Primary => "primary",
        Mode::Subagent => "subagent",
        Mode::All => "all",
    }
}

fn parse_mode(text: &str) -> Result<Mode> {
    match text {
        "primary" => Ok(Mode::Primary),
        "subagent" => Ok(Mode::Subagent),
        "all" => Ok(Mode::All),
        other => Err(CliError(format!(
            "{other:?} is not a mode. Use primary (an Imp you talk to), subagent or all."
        ))),
    }
}

fn parse_model(text: &str) -> Result<String> {
    Ok(text
        .parse::<ModelRef>()
        .map_err(|e| CliError(e.to_string()))?
        .to_string())
}

fn check_color(color: &str) -> Result<()> {
    if imp_engine::config::doc::valid_color(color) {
        Ok(())
    } else {
        Err(CliError(format!(
            "{color:?} is not a colour: write it as #rrggbb."
        )))
    }
}

pub fn list(settings: &Settings, all: bool) -> Result<Reply> {
    let loaded = settings.load();
    let shown: Vec<_> = loaded
        .agents
        .values()
        .filter(|a| all || !a.value.hidden)
        .collect();
    let json: Vec<Value> = shown
        .iter()
        .map(|a| {
            json!({
                "name": a.value.name,
                "mode": mode_name(a.value.mode()),
                "description": a.value.description,
                "model": a.value.model.clone().or_else(|| loaded.config.model.clone()),
                "color": a.value.color,
                "hidden": a.value.hidden,
                "disabled": a.value.disabled,
                "scope": if a.scope == Scope::Project { "project" } else { "global" },
                "path": a.path,
            })
        })
        .collect();
    let rows = shown
        .iter()
        .map(|a| {
            vec![
                a.value.name.clone(),
                mode_name(a.value.mode()).into(),
                a.value
                    .model
                    .clone()
                    .or_else(|| loaded.config.model.clone())
                    .unwrap_or_else(|| "-".into()),
                a.value.description.clone().unwrap_or_default(),
            ]
        })
        .collect();
    Ok(Reply::table(
        vec!["NAME", "MODE", "MODEL", "DESCRIPTION"],
        rows,
        Value::Array(json),
    ))
}

pub fn show(settings: &Settings, name: &str) -> Result<Reply> {
    let loaded = settings.load();
    let key = name_of(&loaded, name);
    let found = loaded.agents.get(&key).ok_or_else(|| {
        CliError(format!(
            "There is no agent called {name}. `imp agent list` shows them."
        ))
    })?;
    let a = &found.value;
    let model = a.model.clone().or_else(|| loaded.config.model.clone());
    let json = json!({
        "name": a.name,
        "mode": mode_name(a.mode()),
        "description": a.description,
        "model": a.model,
        "variant": a.variant,
        "color": a.color,
        "steps": a.steps,
        "hidden": a.hidden,
        "disabled": a.disabled,
        "permissions": a.permissions,
        "request": a.request,
        "prompt": a.prompt(),
        "scope": if found.scope == Scope::Project { "project" } else { "global" },
        "path": found.path,
        "id": loaded.config.imps.get(&a.name).map(|e| e.id),
    });
    let mut fields = vec![
        ("name", a.name.clone()),
        ("mode", mode_name(a.mode()).into()),
        ("model", model.unwrap_or_else(|| "(none)".into())),
    ];
    if let Some(v) = &a.variant {
        fields.push(("variant", v.clone()));
    }
    for (label, value) in [("description", &a.description), ("color", &a.color)] {
        if let Some(v) = value {
            fields.push((label, v.clone()));
        }
    }
    if let Some(steps) = a.steps {
        fields.push(("steps", steps.to_string()));
    }
    fields.push(("rules", a.permissions.len().to_string()));
    fields.push(("file", found.path.display().to_string()));
    let mut reply = Reply::fields(fields, json);
    if !a.prompt().trim().is_empty() {
        let head = reply.render(false);
        reply.view = crate::commands::reply::View::Text(format!("{head}\n\n{}", a.prompt().trim()));
    }
    Ok(reply)
}

pub fn new(
    settings: &Settings,
    name: &str,
    description: Option<String>,
    model: Option<String>,
    mode: &str,
    color: Option<String>,
) -> Result<Reply> {
    if !valid_agent_name(name) {
        return Err(CliError(format!(
            "{name:?} is not a name for an agent: use 1 to 32 letters, digits, - and _."
        )));
    }
    let loaded = settings.load();
    if loaded.agents.keys().any(|n| n.eq_ignore_ascii_case(name))
        || settings.store.agent_path(name).exists()
    {
        return Err(CliError(format!(
            "There is already an agent called {name}."
        )));
    }
    if let Some(color) = &color {
        check_color(color)?;
    }
    let agent = Agent {
        name: name.into(),
        description,
        mode: Some(parse_mode(mode)?),
        model: model.as_deref().map(parse_model).transpose()?,
        color,
        ..Agent::default()
    };
    settings.store.write_agent(&agent)?;
    settings.store.update(|c| {
        c.imps
            .entry(name.to_string())
            .or_insert_with(ImpExtras::new);
    })?;
    let path = settings.store.agent_path(name);
    Ok(Reply::done(
        format!(
            "Made {name}. Its file is {}.",
            crate::project::shown_path(&path)
        ),
        json!({ "name": name, "path": path }),
    ))
}

/// The program that edits files: `$VISUAL`, `$EDITOR`, else `vi`, as a program and its arguments.
pub fn edit_command(env: &imp_engine::config::Env) -> Vec<String> {
    let text = ["VISUAL", "EDITOR"]
        .iter()
        .filter_map(|v| env.get(v))
        .find(|v| !v.trim().is_empty())
        .unwrap_or("vi");
    text.split_whitespace().map(str::to_string).collect()
}

/// Opens a file in the editor and waits for it to close.
pub fn edit_file(settings: &Settings, path: &Path) -> Result<()> {
    let command = edit_command(&settings.env);
    let (program, args) = command
        .split_first()
        .ok_or_else(|| CliError("No editor.".into()))?;
    let status = std::process::Command::new(program)
        .args(args)
        .arg(path)
        .status()
        .map_err(|e| CliError(format!("Could not start the editor {program}: {e}")))?;
    if status.success() {
        Ok(())
    } else {
        Err(CliError(format!(
            "The editor {program} stopped with {status}."
        )))
    }
}

pub fn edit(settings: &Settings, name: &str) -> Result<Reply> {
    let loaded = settings.load();
    let key = name_of(&loaded, name);
    let path = match loaded.agents.get(&key) {
        Some(found) => found.path.clone(),
        None => {
            return Err(CliError(format!(
                "There is no agent called {name}. `imp agent list` shows them."
            )));
        }
    };
    edit_file(settings, &path)?;
    let text = std::fs::read_to_string(&path)?;
    let problems = match Agent::parse(&key, &text) {
        Ok(agent) => agent.problems(),
        Err(e) => vec![e],
    };
    if problems.is_empty() {
        Ok(Reply::done(format!("Saved {key}."), json!({ "name": key })))
    } else {
        Err(CliError(format!(
            "{key} was saved but has problems: {}",
            problems.join(" ")
        )))
    }
}

pub fn set(settings: &Settings, name: &str, key: &str, value: &str) -> Result<Reply> {
    let loaded = settings.load();
    let mut agent = own_agent(settings, &loaded, name)?;
    let clear = cleared(value);
    let some = |v: &str| (!clear).then(|| v.to_string());
    match key {
        "description" => agent.description = some(value),
        "mode" => {
            agent.mode = if clear {
                None
            } else {
                Some(parse_mode(value)?)
            }
        }
        "model" => {
            agent.model = if clear {
                None
            } else {
                Some(parse_model(value)?)
            }
        }
        "variant" => agent.variant = some(value),
        "color" => {
            if !clear {
                check_color(value)?;
            }
            agent.color = some(value);
        }
        "steps" => {
            agent.steps = if clear {
                None
            } else {
                Some(
                    value
                        .parse::<u32>()
                        .ok()
                        .filter(|n| *n > 0)
                        .ok_or_else(|| {
                            CliError(format!("{value:?} is not a number of steps (1 or more)."))
                        })?,
                )
            }
        }
        "hidden" => agent.hidden = parse_bool(value, clear)?,
        "disabled" => agent.disabled = parse_bool(value, clear)?,
        "prompt" => {
            agent.body = if clear {
                String::new()
            } else {
                value.to_string()
            }
        }
        other => {
            return Err(CliError(format!(
                "{other:?} is not a setting of an agent. Use description, mode, model, variant, color, steps, hidden, disabled or prompt."
            )));
        }
    }
    settings.store.write_agent(&agent)?;
    let what = if clear { "cleared" } else { "set" };
    Ok(Reply::done(
        format!("{} {key} {what}.", agent.name),
        json!({ "name": agent.name, "key": key }),
    ))
}

fn parse_bool(value: &str, clear: bool) -> Result<bool> {
    if clear {
        return Ok(false);
    }
    match value {
        "true" | "yes" | "on" => Ok(true),
        "false" | "no" | "off" => Ok(false),
        other => Err(CliError(format!("{other:?} is not true or false."))),
    }
}

pub fn remove(settings: &Settings, name: &str) -> Result<Reply> {
    let loaded = settings.load();
    let agent = own_agent(settings, &loaded, name)?;
    settings.store.remove_agent(&agent.name)?;
    Ok(Reply::done(
        format!("Removed {}.", agent.name),
        json!({ "name": agent.name }),
    ))
}

pub fn rename(settings: &Settings, old: &str, new: &str) -> Result<Reply> {
    let loaded = settings.load();
    let agent = own_agent(settings, &loaded, old)?;
    settings.store.rename_agent(&agent.name, new)?;
    // The file keeps the name it had in its text only as the file name, so nothing else changes.
    Ok(Reply::done(
        format!("{} is now called {new}.", agent.name),
        json!({ "old": agent.name, "new": new }),
    ))
}
