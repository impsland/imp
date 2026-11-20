//! `imp permission`: rules that say what Imps may do. In `imp.json` for everyone, or in an agent's file.

use super::{name_of, own_agent};
use crate::commands::reply::Reply;
use crate::settings::Settings;
use crate::{CliError, Result};
use imp_engine::config::{Effect, Rule, default_rules};
use serde_json::{Value, json};

/// What a rule can be about: the groups of an Imp's own tools, and the rest.
pub const ACTIONS: [&str; 6] = ["shell", "mcp", "skill", "read", "edit", "message"];

fn valid_action(action: &str) -> bool {
    ACTIONS.contains(&action) || imp_engine::tools::GROUPS.iter().any(|(g, _)| *g == action)
}

fn effect_name(effect: Effect) -> &'static str {
    match effect {
        Effect::Allow => "allow",
        Effect::Ask => "ask",
        Effect::Deny => "deny",
    }
}

pub fn list(settings: &Settings, agent: Option<&str>) -> Result<Reply> {
    let loaded = settings.load();
    let mut shown: Vec<(Option<usize>, &str, Rule)> = default_rules()
        .into_iter()
        .map(|r| (None, "default", r))
        .collect();
    let numbered =
        |rules: &[Rule], source: &'static str| -> Vec<(Option<usize>, &'static str, Rule)> {
            rules
                .iter()
                .enumerate()
                .map(|(i, r)| (Some(i + 1), source, r.clone()))
                .collect()
        };
    match agent {
        None => shown.extend(numbered(&loaded.config.permissions, "imp.json")),
        Some(name) => {
            let key = name_of(&loaded, name);
            let found = loaded
                .agents
                .get(&key)
                .ok_or_else(|| CliError(format!("There is no agent called {name}.")))?;
            shown.extend(
                loaded
                    .config
                    .permissions
                    .iter()
                    .map(|r| (None, "imp.json", r.clone())),
            );
            shown.extend(numbered(&found.value.permissions, "agent"));
        }
    }
    let rows = shown
        .iter()
        .map(|(i, source, r)| {
            vec![
                i.map_or("-".into(), |i| i.to_string()),
                r.action.clone(),
                r.resource.clone(),
                effect_name(r.effect).into(),
                (*source).into(),
            ]
        })
        .collect();
    let json = shown
        .iter()
        .map(|(i, source, r)| {
            json!({ "index": i, "action": r.action, "resource": r.resource, "effect": r.effect, "source": source })
        })
        .collect();
    Ok(Reply::table(
        vec!["#", "ACTION", "RESOURCE", "EFFECT", "FROM"],
        rows,
        Value::Array(json),
    ))
}

fn parse_effect(text: &str) -> Result<Effect> {
    match text {
        "allow" => Ok(Effect::Allow),
        "ask" => Ok(Effect::Ask),
        "deny" => Ok(Effect::Deny),
        other => Err(CliError(format!("{other:?} is not allow, ask or deny."))),
    }
}

pub fn add(
    settings: &Settings,
    action: &str,
    resource: &str,
    effect: &str,
    agent: Option<&str>,
) -> Result<Reply> {
    if !valid_action(action) {
        let mut all: Vec<&str> = imp_engine::tools::GROUPS.iter().map(|(g, _)| *g).collect();
        all.extend(ACTIONS);
        return Err(CliError(format!(
            "{action:?} is not something rules cover. Use {}.",
            all.join(", ")
        )));
    }
    let rule = Rule::new(action, resource, parse_effect(effect)?);
    let message = format!("{} {} {}.", effect, action, resource);
    match agent {
        Some(name) => {
            let loaded = settings.load();
            let mut a = own_agent(settings, &loaded, name)?;
            a.permissions.push(rule.clone());
            settings.store.write_agent(&a)?;
        }
        None => settings
            .store
            .update(|c| c.permissions.push(rule.clone()))?,
    }
    Ok(Reply::done(
        format!("Added: {message}"),
        json!({ "rule": rule }),
    ))
}

pub fn remove(settings: &Settings, index: usize, agent: Option<&str>) -> Result<Reply> {
    let take = |rules: &mut Vec<Rule>| {
        if index == 0 || index > rules.len() {
            Err(CliError(format!(
                "There is no rule {index}. `imp permission list` numbers them from 1."
            )))
        } else {
            Ok(rules.remove(index - 1))
        }
    };
    let rule = match agent {
        Some(name) => {
            let loaded = settings.load();
            let mut a = own_agent(settings, &loaded, name)?;
            let rule = take(&mut a.permissions)?;
            settings.store.write_agent(&a)?;
            rule
        }
        None => settings.store.update(|c| take(&mut c.permissions))??,
    };
    Ok(Reply::done(
        format!(
            "Removed: {} {} {}.",
            effect_name(rule.effect),
            rule.action,
            rule.resource
        ),
        json!({ "rule": rule }),
    ))
}
