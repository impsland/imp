//! The management commands: what `imp agent`, `imp provider`, `imp mcp`... do. One function per action, each
//! taking the parsed arguments and the [`Settings`] and answering with a [`Reply`] (a value for `--json`
//! and the same thing for people). The terminal prints the reply, and a chat shows it. Nothing here prints.

mod agent;
mod auth;
mod config;
mod library;
mod mcp;
mod model;
mod permission;
mod project;
mod provider;

pub use agent::{edit_command, edit_file};

use super::reply::Reply;
use crate::cli::{
    AgentAction, AuthAction, ConfigAction, Manage, McpAction, PermissionAction, ProjectAction,
    ProviderAction, ReadAction,
};
use crate::settings::Settings;
use crate::{CliError, Result};
use imp_engine::config::{Agent, Loaded, Scope};

/// Where a secret typed by the person comes from, when a command needs one (`imp auth set`).
pub type Secret<'a> = &'a mut dyn FnMut(&str) -> Result<String>;

/// Runs one management command.
pub fn run(settings: &Settings, command: Manage, secret: Secret<'_>) -> Result<Reply> {
    match command {
        Manage::Agent { action } => match action {
            AgentAction::List { all } => agent::list(settings, all),
            AgentAction::Show { name } => agent::show(settings, &name),
            AgentAction::New {
                name,
                description,
                model,
                mode,
                color,
            } => agent::new(settings, &name, description, model, &mode, color),
            AgentAction::Edit { name } => agent::edit(settings, &name),
            AgentAction::Set { name, key, value } => agent::set(settings, &name, &key, &value),
            AgentAction::Remove { name } => agent::remove(settings, &name),
            AgentAction::Rename { old, new } => agent::rename(settings, &old, &new),
        },
        Manage::Provider { action } => match action {
            ProviderAction::List => provider::list(settings),
            ProviderAction::Add {
                id,
                url,
                name,
                headers,
                key_env,
            } => provider::add(settings, &id, &url, name, &headers, key_env),
            ProviderAction::Set { id, key, value } => provider::set(settings, &id, &key, &value),
            ProviderAction::Remove { id } => provider::remove(settings, &id),
        },
        Manage::Auth { action } => match action {
            AuthAction::Set { provider } => {
                let key = secret(&format!("Key for {provider}"))?;
                auth::set(settings, &provider, &key)
            }
            AuthAction::Clear { provider } => auth::clear(settings, &provider),
            AuthAction::List => auth::list(settings),
        },
        Manage::Model { model, agent } => model::run(settings, model.as_deref(), agent.as_deref()),
        Manage::Mcp { action } => match action {
            McpAction::List { agent } => mcp::list(settings, agent.as_deref()),
            McpAction::Add {
                name,
                command,
                url,
                env,
                headers,
            } => mcp::add(settings, &name, command, url, &env, &headers),
            McpAction::Set { name, key, value } => mcp::set(settings, &name, &key, &value),
            McpAction::Remove { name } => mcp::remove(settings, &name),
            McpAction::Enable { name, agent } => {
                mcp::enable(settings, &name, agent.as_deref(), true)
            }
            McpAction::Disable { name, agent } => {
                mcp::enable(settings, &name, agent.as_deref(), false)
            }
        },
        Manage::Permission { action } => match action {
            PermissionAction::List { agent } => permission::list(settings, agent.as_deref()),
            PermissionAction::Add {
                action,
                resource,
                effect,
                agent,
            } => permission::add(settings, &action, &resource, &effect, agent.as_deref()),
            PermissionAction::Remove { index, agent } => {
                permission::remove(settings, index, agent.as_deref())
            }
        },
        Manage::Skill { action } => match action {
            ReadAction::List => library::skills(settings),
            ReadAction::Show { name } => library::skill(settings, &name),
        },
        Manage::Cmd { action } => match action {
            ReadAction::List => library::commands(settings),
            ReadAction::Show { name } => library::command(settings, &name),
        },
        Manage::Project { action } => match action.unwrap_or(ProjectAction::Show) {
            ProjectAction::Show => project::show(settings),
            ProjectAction::Trust => project::trust(settings, true),
            ProjectAction::Untrust => project::trust(settings, false),
        },
        Manage::Config { action } => match action.unwrap_or(ConfigAction::Get { key: None }) {
            ConfigAction::Path => config::path(settings),
            ConfigAction::Get { key } => config::get(settings, key.as_deref()),
            ConfigAction::Set { key, value } => config::set(settings, &key, &value),
            ConfigAction::Unset { key } => config::unset(settings, &key),
        },
    }
}

/// The name an agent really has: `pip` finds `Pip`.
fn name_of(loaded: &Loaded, name: &str) -> String {
    loaded
        .agents
        .keys()
        .find(|n| n.eq_ignore_ascii_case(name))
        .cloned()
        .unwrap_or_else(|| name.to_string())
}

/// An agent of the person's own agents folder as its file has it, to change and write back.
fn own_agent(settings: &Settings, loaded: &Loaded, name: &str) -> Result<Agent> {
    let name = name_of(loaded, name);
    if let Some(found) = loaded.agents.get(&name)
        && found.scope == Scope::Project
    {
        return Err(CliError(format!(
            "{name} belongs to the folder: change its file {} instead.",
            found.path.display()
        )));
    }
    if !settings.store.agent_path(&name).is_file() {
        return Err(CliError(format!(
            "There is no agent called {name}. `imp agent list` shows them."
        )));
    }
    Ok(settings.store.read_agent(&name)?)
}

/// `NAME` for a provider or server written in the settings: something a model name can hold.
fn valid_id(id: &str) -> bool {
    !id.is_empty()
        && id.len() <= 64
        && !id.contains(['/', '#', '.'])
        && !id.chars().any(char::is_whitespace)
}

fn check_id(kind: &str, id: &str) -> Result<()> {
    if valid_id(id) {
        Ok(())
    } else {
        Err(CliError(format!(
            "{id:?} is not a good name for a {kind}: use letters, digits, - and _."
        )))
    }
}
