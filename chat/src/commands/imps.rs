//! `imp imp`: list, make and remove Imps in the settings file.

use super::Io;
use crate::cli::ImpAction;
use crate::config::{
    Config, DEFAULT_PERSONALITY, DEFAULT_URL, ImpConfig, valid_env_name, valid_imp_name,
};
use crate::keys;
use crate::{CliError, Result};
use std::path::Path;

const NO_IMPS: &str = "No Imps yet. Make one with `imp imp new NAME --model MODEL`.";

/// What `imp imp new` was given. Anything left out is asked for.
struct NewImp {
    name: Option<String>,
    personality: Option<String>,
    url: Option<String>,
    model: Option<String>,
    api_key_env: Option<String>,
    default: bool,
}

pub fn run(path: &Path, action: ImpAction, io: &mut Io<'_>) -> Result<()> {
    let mut config = Config::load(path)?;
    match action {
        ImpAction::List => list(&config, io),
        ImpAction::New {
            name,
            personality,
            url,
            model,
            api_key_env,
            default,
        } => {
            let given = NewImp {
                name,
                personality,
                url,
                model,
                api_key_env,
                default,
            };
            make(&mut config, path, given, io)
        }
        ImpAction::Remove { name } => remove(&mut config, path, &name, io),
        ImpAction::Set { name, key, value } => {
            let stored = config
                .find_imp(&name)
                .map(|(stored, _)| stored.clone())
                .ok_or_else(|| CliError(format!("There is no Imp called {name}.")))?;
            let imp = config.imps.get_mut(&stored).expect("found above");
            imp.set(&key, &value)?;
            config.save(path)?;
            writeln!(io.out, "Saved {key} for {stored}.")?;
            Ok(())
        }
    }
}

fn list(config: &Config, io: &mut Io<'_>) -> Result<()> {
    if config.imps.is_empty() {
        writeln!(io.out, "{NO_IMPS}")?;
        return Ok(());
    }
    let width = config
        .imps
        .keys()
        .map(String::len)
        .max()
        .unwrap_or(4)
        .max(4);
    let model_width = config
        .imps
        .values()
        .map(|i| i.model.len())
        .max()
        .unwrap_or(5)
        .max(5);
    writeln!(
        io.out,
        "  {:width$}  {:model_width$}  BRAIN",
        "NAME", "MODEL"
    )?;
    for (name, imp) in &config.imps {
        let mark = if config.default_imp.as_deref() == Some(name) {
            '*'
        } else {
            ' '
        };
        writeln!(
            io.out,
            "{mark} {name:width$}  {:model_width$}  {}",
            imp.model, imp.base_url
        )?;
    }
    Ok(())
}

fn make(config: &mut Config, path: &Path, given: NewImp, io: &mut Io<'_>) -> Result<()> {
    let name = match given.name {
        Some(n) => n,
        None => io
            .ask("Name", None)?
            .ok_or_else(|| CliError("A name is needed. Use imp imp new NAME.".into()))?,
    };
    if !valid_imp_name(&name) {
        return Err(CliError(
            "An Imp's name can have 1 to 32 letters, digits, dashes and underscores.".into(),
        ));
    }
    if let Some((stored, _)) = config.find_imp(&name) {
        return Err(CliError(format!(
            "There is already an Imp called {stored}."
        )));
    }
    let personality = match given.personality {
        Some(p) => p,
        None => io
            .ask("Personality", Some(DEFAULT_PERSONALITY))?
            .unwrap_or_default(),
    };
    let base_url = match given.url {
        Some(u) => u,
        None => io
            .ask(
                "Brain address (an OpenAI-compatible service)",
                Some(DEFAULT_URL),
            )?
            .unwrap_or_default(),
    };
    if !(base_url.starts_with("http://") || base_url.starts_with("https://")) {
        return Err(CliError(
            "The service address must start with http:// or https://.".into(),
        ));
    }
    let model = match given.model {
        Some(m) => m,
        None => io
            .ask("Model", None)?
            .ok_or_else(|| CliError("A model is needed. Use --model NAME.".into()))?,
    };
    if let Some(var) = &given.api_key_env
        && !valid_env_name(var)
    {
        return Err(CliError(
            "--api-key-env is the NAME of an environment variable, not the key itself.".into(),
        ));
    }
    let first = config.imps.is_empty();
    let imp = ImpConfig {
        api_key_env: given.api_key_env,
        ..ImpConfig::new(personality, base_url, model)
    };
    let var = keys::env_name(config, &imp).to_string();
    config.imps.insert(name.clone(), imp);
    if given.default || first {
        config.default_imp = Some(name.clone());
    }
    config.save(path)?;
    writeln!(io.out, "Made {name}.")?;
    writeln!(
        io.out,
        "Give it a key by setting {var} or running `imp config set-key --imp {name}`, unless its brain needs none.\nThen chat with `imp chat --imp {name}`."
    )?;
    Ok(())
}

fn remove(config: &mut Config, path: &Path, name: &str, io: &mut Io<'_>) -> Result<()> {
    let Some(stored) = config.find_imp(name).map(|(stored, _)| stored.clone()) else {
        return Err(CliError(format!("There is no Imp called {name}.")));
    };
    config.imps.remove(&stored);
    let name = stored.as_str();
    if config.default_imp.as_deref() == Some(name) {
        config.default_imp = None;
    }
    config.save(path)?;
    writeln!(io.out, "Removed {name}.")?;
    Ok(())
}
