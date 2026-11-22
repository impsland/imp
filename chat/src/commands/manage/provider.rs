//! `imp provider`: where models live, as `providers` in `imp.json`. These read the file as written, so
//! `{env:VAR}` in a key stays what the person typed and no key is ever shown.

use super::check_id;
use crate::commands::reply::{Reply, cleared, pairs};
use crate::settings::Settings;
use crate::{CliError, Result};
use imp_engine::config::{Auth, Provider};
use serde_json::{Value, json};

/// Where a provider's key is: `env VAR`, `imp.json` (a literal or a file), `saved` (auth.json) or `none`.
pub fn key_source(provider: &Provider, auth: &Auth, id: &str) -> String {
    match provider
        .options
        .api_key
        .as_deref()
        .filter(|k| !k.is_empty())
    {
        Some(key) => match key.strip_prefix("{env:").and_then(|k| k.strip_suffix('}')) {
            Some(var) => format!("env {var}"),
            None => "imp.json".into(),
        },
        None if auth.providers.get(id).is_some_and(|a| !a.key.is_empty()) => "saved".into(),
        None => "none".into(),
    }
}

pub fn list(settings: &Settings) -> Result<Reply> {
    let config = settings.store.read_config()?;
    let auth = settings.store.read_auth()?;
    let mut rows = Vec::new();
    let mut json = Vec::new();
    for (id, p) in &config.providers {
        let key = key_source(p, &auth, id);
        rows.push(vec![
            id.clone(),
            p.name.clone().unwrap_or_default(),
            p.options.base_url.clone().unwrap_or_default(),
            key.clone(),
        ]);
        json.push(json!({
            "id": id,
            "name": p.name,
            "url": p.options.base_url,
            "key": key,
            "headers": p.options.headers.keys().collect::<Vec<_>>(),
            "models": p.models.keys().collect::<Vec<_>>(),
        }));
    }
    Ok(Reply::table(
        vec!["ID", "NAME", "URL", "KEY"],
        rows,
        Value::Array(json),
    ))
}

/// Whether `url` is an address a provider can have: it starts with `http://` or `https://`.
pub(crate) fn is_url(url: &str) -> bool {
    url.starts_with("http://") || url.starts_with("https://")
}

fn check_url(url: &str) -> Result<()> {
    if is_url(url) {
        Ok(())
    } else {
        Err(CliError(format!(
            "{url:?} is not an address: it starts with http:// or https://."
        )))
    }
}

fn check_var(var: &str) -> Result<()> {
    if !var.is_empty() && var.chars().all(|c| c.is_ascii_alphanumeric() || c == '_') {
        Ok(())
    } else {
        // What was typed is not repeated: it may be a key that was pasted by mistake.
        Err(CliError(
            "That is not the name of an environment variable (letters, digits and _). A key is saved with `imp auth set PROVIDER`.".into(),
        ))
    }
}

pub fn add(
    settings: &Settings,
    id: &str,
    url: &str,
    name: Option<String>,
    headers: &[String],
    key_env: Option<String>,
) -> Result<Reply> {
    check_id("provider", id)?;
    check_url(url)?;
    let headers = pairs(headers, "--header")?;
    if let Some(var) = &key_env {
        check_var(var)?;
    }
    settings.store.update(|c| {
        if c.providers.contains_key(id) {
            return Err(CliError(format!(
                "There is already a provider {id}. Change it with `imp provider set {id} KEY VALUE`."
            )));
        }
        let mut provider = Provider {
            name,
            ..Provider::default()
        };
        provider.options.base_url = Some(url.to_string());
        provider.options.api_key = key_env.map(|v| format!("{{env:{v}}}"));
        provider.options.headers = headers.into_iter().collect();
        c.providers.insert(id.to_string(), provider);
        Ok(())
    })??;
    Ok(Reply::done(
        format!("Added {id}. Save a key with `imp auth set {id}` if it needs one."),
        json!({ "id": id, "url": url }),
    ))
}

pub fn set(settings: &Settings, id: &str, key: &str, value: &str) -> Result<Reply> {
    let clear = cleared(value);
    let text = (!clear).then(|| value.to_string());
    settings.store.update(|c| {
        let p = c
            .providers
            .get_mut(id)
            .ok_or_else(|| CliError(format!("There is no provider {id}. `imp provider list` shows them.")))?;
        match key {
            "name" => p.name = text,
            "url" => {
                let url = text.ok_or_else(|| CliError("A provider needs its url.".into()))?;
                check_url(&url)?;
                p.options.base_url = Some(url);
            }
            "key-env" => {
                p.options.api_key = match text {
                    Some(var) => {
                        check_var(&var)?;
                        Some(format!("{{env:{var}}}"))
                    }
                    None => None,
                }
            }
            other => match other.strip_prefix("header.") {
                Some(name) if !name.is_empty() => match text {
                    Some(v) => {
                        p.options.headers.insert(name.to_string(), v);
                    }
                    None => {
                        p.options.headers.remove(name);
                    }
                },
                _ => {
                    return Err(CliError(format!(
                        "{other:?} is not a setting of a provider. Use name, url, key-env or header.NAME."
                    )));
                }
            },
        }
        Ok(())
    })??;
    Ok(Reply::done(
        format!("{id} {key} {}.", if clear { "cleared" } else { "set" }),
        json!({ "id": id, "key": key }),
    ))
}

pub fn remove(settings: &Settings, id: &str) -> Result<Reply> {
    settings.store.update(|c| {
        c.providers
            .remove(id)
            .map(|_| ())
            .ok_or_else(|| CliError(format!("There is no provider {id}.")))
    })??;
    settings.store.update_auth(|a| a.providers.remove(id))?;
    Ok(Reply::done(
        format!("Removed {id} and its saved key."),
        json!({ "id": id }),
    ))
}
