//! `imp auth`: keys saved in `auth.json`. Nothing here ever returns a key.

use crate::commands::reply::Reply;
use crate::settings::Settings;
use crate::{CliError, Result};
use imp_engine::config::ProviderAuth;
use serde_json::json;

pub fn set(settings: &Settings, provider: &str, key: &str) -> Result<Reply> {
    let key = key.trim();
    if key.is_empty() {
        return Err(CliError("The key is empty. Nothing was saved.".into()));
    }
    if !settings
        .store
        .read_config()?
        .providers
        .contains_key(provider)
    {
        return Err(CliError(format!(
            "There is no provider {provider}. Add it with `imp provider add {provider} --url URL`."
        )));
    }
    settings.store.update_auth(|a| {
        a.providers.insert(
            provider.to_string(),
            ProviderAuth {
                key: key.to_string(),
            },
        );
    })?;
    Ok(Reply::done(
        format!("Saved the key for {provider}."),
        json!({ "provider": provider }),
    ))
}

pub fn clear(settings: &Settings, provider: &str) -> Result<Reply> {
    let had = settings
        .store
        .update_auth(|a| a.providers.remove(provider).is_some())?;
    if !had {
        return Err(CliError(format!("There is no saved key for {provider}.")));
    }
    Ok(Reply::done(
        format!("Forgot the key of {provider}."),
        json!({ "provider": provider }),
    ))
}

pub fn list(settings: &Settings) -> Result<Reply> {
    let config = settings.store.read_config()?;
    let auth = settings.store.read_auth()?;
    let mut rows = Vec::new();
    let mut json = Vec::new();
    for (id, p) in &config.providers {
        let source = super::provider::key_source(p, &auth, id);
        rows.push(vec!["provider".to_string(), id.clone(), source.clone()]);
        json.push(json!({ "kind": "provider", "name": id, "key": source }));
    }
    for name in auth.mcp.keys() {
        rows.push(vec!["mcp".to_string(), name.clone(), "signed in".into()]);
        json.push(json!({ "kind": "mcp", "name": name, "key": "signed in" }));
    }
    Ok(Reply::table(
        vec!["KIND", "NAME", "KEY"],
        rows,
        serde_json::Value::Array(json),
    ))
}
