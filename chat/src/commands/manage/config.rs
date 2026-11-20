//! `imp config`: any setting of `imp.json` by its dotted key, such as `requests.retries`.

use crate::commands::reply::Reply;
use crate::settings::Settings;
use crate::{CliError, Result};
use imp_engine::config::ImpConfig;
use serde_json::{Value, json};

/// `a.b\.c` is the keys `a` and `b.c`.
fn parts(key: &str) -> Result<Vec<String>> {
    let mut out = vec![String::new()];
    let mut chars = key.chars().peekable();
    while let Some(c) = chars.next() {
        match c {
            '\\' if chars.peek() == Some(&'.') => {
                chars.next();
                if let Some(part) = out.last_mut() {
                    part.push('.');
                }
            }
            '.' => out.push(String::new()),
            c => {
                if let Some(part) = out.last_mut() {
                    part.push(c);
                }
            }
        }
    }
    if out.iter().any(String::is_empty) {
        return Err(CliError(format!(
            "{key:?} is not a key: write it like requests.retries."
        )));
    }
    Ok(out)
}

fn as_value(config: &ImpConfig) -> Result<Value> {
    serde_json::to_value(config).map_err(|e| CliError(e.to_string()))
}

pub fn path(settings: &Settings) -> Result<Reply> {
    let path = settings.store.config_path();
    Ok(Reply::text(
        path.display().to_string(),
        json!({ "config": path, "auth": settings.store.auth_path(), "agents": settings.env.agents_dir() }),
    ))
}

pub fn get(settings: &Settings, key: Option<&str>) -> Result<Reply> {
    let mut value = as_value(&settings.store.read_config()?)?;
    if let Some(key) = key {
        for part in parts(key)? {
            value = match value {
                Value::Object(mut map) => map.remove(&part),
                Value::Array(mut items) => part
                    .parse::<usize>()
                    .ok()
                    .filter(|i| *i < items.len())
                    .map(|i| items.swap_remove(i)),
                _ => None,
            }
            .ok_or_else(|| CliError(format!("{key} is not set.")))?;
        }
    }
    let text = match &value {
        Value::String(s) => s.clone(),
        other => serde_json::to_string_pretty(other).unwrap_or_default(),
    };
    Ok(Reply::text(text, json!({ "key": key, "value": value })))
}

/// Changes a value inside the settings, then reads the whole back as settings: a change that makes
/// them not fit is refused and nothing is written.
fn change(
    settings: &Settings,
    key: &str,
    edit: impl FnOnce(&mut Value, &str) -> Result<()>,
) -> Result<()> {
    let parts = parts(key)?;
    settings.store.update(|config| {
        let mut value = as_value(config)?;
        let mut at = &mut value;
        let (last, parents) = parts
            .split_last()
            .ok_or_else(|| CliError("No key.".into()))?;
        for part in parents {
            if !at.is_object() {
                *at = Value::Object(Default::default());
            }
            at = at
                .as_object_mut()
                .map(|m| {
                    m.entry(part.clone())
                        .or_insert_with(|| Value::Object(Default::default()))
                })
                .ok_or_else(|| {
                    CliError(format!("{key} is inside something that is not a group."))
                })?;
        }
        edit(at, last)?;
        *config = serde_json::from_value(value)
            .map_err(|e| CliError(format!("{key} does not fit: {e}")))?;
        Ok(())
    })?
}

pub fn set(settings: &Settings, key: &str, value: &str) -> Result<Reply> {
    let parsed =
        serde_json::from_str::<Value>(value).unwrap_or_else(|_| Value::String(value.to_string()));
    change(settings, key, |at, last| {
        at.as_object_mut()
            .ok_or_else(|| CliError(format!("{key} is inside something that is not a group.")))?
            .insert(last.to_string(), parsed.clone());
        Ok(())
    })?;
    Ok(Reply::done(
        format!("{key} is set."),
        json!({ "key": key, "value": parsed }),
    ))
}

pub fn unset(settings: &Settings, key: &str) -> Result<Reply> {
    change(settings, key, |at, last| {
        at.as_object_mut()
            .and_then(|m| m.remove(last))
            .map(|_| ())
            .ok_or_else(|| CliError(format!("{key} is not set.")))
    })?;
    Ok(Reply::done(
        format!("{key} is removed."),
        json!({ "key": key }),
    ))
}
