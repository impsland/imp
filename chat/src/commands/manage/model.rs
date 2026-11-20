//! `imp model`: the default model, or an agent's own.

use super::{name_of, own_agent};
use crate::commands::reply::{Reply, cleared};
use crate::settings::Settings;
use crate::{CliError, Result};
use imp_engine::config::{ModelRef, resolve};
use serde_json::json;

pub fn run(settings: &Settings, model: Option<&str>, agent: Option<&str>) -> Result<Reply> {
    let loaded = settings.load();
    let Some(text) = model else {
        return show(settings, agent);
    };
    match agent {
        Some(name) => {
            let mut a = own_agent(settings, &loaded, name)?;
            if cleared(text) {
                a.model = None;
                a.variant = None;
            } else {
                let wanted = check(&loaded.config.providers, text)?;
                a.model = Some(wanted.to_string());
                a.variant = None;
            }
            settings.store.write_agent(&a)?;
            Ok(Reply::done(
                match &a.model {
                    Some(m) => format!("{} uses {m}.", a.name),
                    None => format!("{} uses the default model again.", a.name),
                },
                json!({ "agent": a.name, "model": a.model }),
            ))
        }
        None => {
            let wanted = check(&loaded.config.providers, text)?.to_string();
            settings.store.update(|c| c.model = Some(wanted.clone()))?;
            Ok(Reply::done(
                format!("The default model is {wanted}."),
                json!({ "model": wanted }),
            ))
        }
    }
}

fn check(
    providers: &std::collections::BTreeMap<String, imp_engine::config::Provider>,
    text: &str,
) -> Result<ModelRef> {
    let wanted: ModelRef = text
        .parse()
        .map_err(|e: imp_engine::config::ModelRefError| CliError(e.to_string()))?;
    if !providers.contains_key(&wanted.provider) {
        return Err(CliError(format!(
            "There is no provider {0}. Add it with `imp provider add {0} --url URL`.",
            wanted.provider
        )));
    }
    Ok(wanted)
}

fn show(settings: &Settings, agent: Option<&str>) -> Result<Reply> {
    let loaded = settings.load();
    let names: Vec<String> = match agent {
        Some(n) => vec![name_of(&loaded, n)],
        None => loaded.imps().map(|a| a.value.name.clone()).collect(),
    };
    let mut rows = Vec::new();
    let mut json = Vec::new();
    for name in &names {
        let found = loaded
            .agents
            .get(name)
            .ok_or_else(|| CliError(format!("There is no agent called {name}.")))?;
        let (model, status) = match resolve(&loaded.config, &loaded.auth, &found.value, None) {
            Ok(r) => (Some(r.reference()), "ready".to_string()),
            Err(why) => (
                found
                    .value
                    .model
                    .clone()
                    .or_else(|| loaded.config.model.clone()),
                why,
            ),
        };
        rows.push(vec![
            name.clone(),
            model.clone().unwrap_or_else(|| "-".into()),
            status.clone(),
        ]);
        json.push(json!({ "agent": name, "model": model, "status": status }));
    }
    let mut reply = Reply::table(
        vec!["AGENT", "MODEL", "STATUS"],
        rows,
        json!({ "default": loaded.config.model, "agents": json }),
    );
    if agent.is_none() {
        let head = format!(
            "Default model: {}\n\n",
            loaded.config.model.as_deref().unwrap_or("(none)")
        );
        reply.view = crate::commands::reply::View::Text(format!("{head}{}", reply.render(false)));
    }
    Ok(reply)
}
