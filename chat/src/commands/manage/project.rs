//! `imp project`: what the folder adds, and whether its settings are trusted.

use crate::commands::reply::Reply;
use crate::project::shown_path;
use crate::settings::Settings;
use crate::{CliError, Result};
use imp_engine::config::Scope;
use serde_json::json;

pub fn show(settings: &Settings) -> Result<Reply> {
    let loaded = settings.load();
    let project = loaded.project.as_ref();
    let names = |it: Vec<String>| {
        if it.is_empty() {
            "-".to_string()
        } else {
            it.join(", ")
        }
    };
    let agents: Vec<String> = loaded
        .agents
        .values()
        .filter(|a| a.scope == Scope::Project)
        .map(|a| a.value.name.clone())
        .collect();
    let skills: Vec<String> = loaded
        .skills
        .values()
        .filter(|a| a.scope == Scope::Project)
        .map(|a| a.value.name.clone())
        .collect();
    let commands: Vec<String> = loaded
        .commands
        .values()
        .filter(|a| a.scope == Scope::Project)
        .map(|a| a.value.name.clone())
        .collect();
    let notes: Vec<String> = loaded
        .instructions
        .iter()
        .map(|i| i.label.clone())
        .collect();
    let state = match project {
        Some(p) if p.digest.is_some() && p.trusted => "trusted",
        Some(p) if p.digest.is_some() => "waiting for trust",
        _ => "nothing to trust",
    };
    let json = json!({
        "folder": settings.workspace,
        "root": project.map(|p| &p.root),
        "settingsFiles": project.map(|p| &p.config_files),
        "trusted": project.is_some_and(|p| p.trusted),
        "hasSettings": project.is_some_and(|p| p.digest.is_some()),
        "agents": agents, "skills": skills, "commands": commands, "notes": notes,
    });
    let files = project.map_or_else(Vec::new, |p| {
        p.config_files.iter().map(|f| shown_path(f)).collect()
    });
    Ok(Reply::fields(
        vec![
            ("folder", shown_path(&settings.workspace)),
            ("settings", names(files)),
            ("state", state.into()),
            ("agents", names(agents)),
            ("skills", names(skills)),
            ("commands", names(commands)),
            ("notes", names(notes)),
        ],
        json,
    ))
}

pub fn trust(settings: &Settings, on: bool) -> Result<Reply> {
    let loaded = settings.load();
    let project = loaded
        .project
        .as_ref()
        .filter(|p| p.digest.is_some())
        .ok_or_else(|| CliError("This folder has no .agents/imp.json to trust.".into()))?;
    let digest = project.digest.as_deref().filter(|_| on);
    settings.trust.set(&project.root, digest)?;
    let what = if on {
        "Trusting the settings of"
    } else {
        "No longer using the settings of"
    };
    Ok(Reply::done(
        format!("{what} {}.", shown_path(&project.root)),
        json!({ "root": project.root, "trusted": on }),
    ))
}
