//! `imp skill` and `imp command`: what the agents folders hold for reading.

use crate::commands::reply::Reply;
use crate::settings::Settings;
use crate::{CliError, Result};
use imp_engine::config::Scope;
use serde_json::{Value, json};

fn scope(scope: Scope) -> &'static str {
    if scope == Scope::Project {
        "project"
    } else {
        "global"
    }
}

pub fn skills(settings: &Settings) -> Result<Reply> {
    let loaded = settings.load();
    let rows = loaded
        .skills
        .values()
        .map(|s| {
            vec![
                s.value.name.clone(),
                scope(s.scope).into(),
                s.value.description.clone(),
            ]
        })
        .collect();
    let json = loaded
        .skills
        .values()
        .map(|s| json!({ "name": s.value.name, "description": s.value.description, "scope": scope(s.scope), "path": s.path }))
        .collect();
    Ok(Reply::table(
        vec!["NAME", "FROM", "DESCRIPTION"],
        rows,
        Value::Array(json),
    ))
}

pub fn skill(settings: &Settings, name: &str) -> Result<Reply> {
    let loaded = settings.load();
    let found = loaded.skills.get(name).ok_or_else(|| {
        CliError(format!(
            "There is no skill {name}. `imp skill list` shows them."
        ))
    })?;
    Ok(Reply::text(
        format!(
            "{}\n{}\n{}\n\n{}",
            found.value.name,
            found.value.description,
            crate::project::shown_path(&found.path),
            found.value.body.trim()
        ),
        json!({ "name": found.value.name, "description": found.value.description, "scope": scope(found.scope), "path": found.path, "body": found.value.body }),
    ))
}

pub fn commands(settings: &Settings) -> Result<Reply> {
    let loaded = settings.load();
    let rows = loaded
        .commands
        .values()
        .map(|c| {
            vec![
                format!("/{}", c.value.name),
                scope(c.scope).into(),
                c.value.description.clone().unwrap_or_default(),
            ]
        })
        .collect();
    let json = loaded
        .commands
        .values()
        .map(|c| json!({ "name": c.value.name, "description": c.value.description, "scope": scope(c.scope), "path": c.path }))
        .collect();
    Ok(Reply::table(
        vec!["COMMAND", "FROM", "DESCRIPTION"],
        rows,
        Value::Array(json),
    ))
}

pub fn command(settings: &Settings, name: &str) -> Result<Reply> {
    let loaded = settings.load();
    let name = name.trim_start_matches('/');
    let found = loaded.commands.get(name).ok_or_else(|| {
        CliError(format!(
            "There is no command {name}. `imp command list` shows them."
        ))
    })?;
    Ok(Reply::text(
        format!(
            "/{}\n{}\n\n{}",
            found.value.name,
            crate::project::shown_path(&found.path),
            found.value.template.trim()
        ),
        json!({ "name": found.value.name, "description": found.value.description, "agent": found.value.agent, "model": found.value.model, "scope": scope(found.scope), "path": found.path, "template": found.value.template }),
    ))
}
