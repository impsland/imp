//! `imp config`: the settings file and where the secrets are kept.

use super::Io;
use crate::cli::ConfigAction;
use crate::config::Config;
use crate::keys;
use crate::{CliError, Result};
use std::path::Path;

pub fn run(path: &Path, action: ConfigAction, io: &mut Io<'_>) -> Result<()> {
    match action {
        ConfigAction::Path => writeln!(io.out, "{}", path.display())?,
        ConfigAction::Show => show(path, io)?,
        ConfigAction::Set { key, value } => {
            let mut config = Config::load(path)?;
            config.set(&key, &value)?;
            config.save(path)?;
            writeln!(io.out, "Saved {key}.")?;
        }
        ConfigAction::SetKey { imp } => set_key(path, imp.as_deref(), io)?,
        ConfigAction::SetHeader { server, header } => set_header(path, &server, &header, io)?,
        ConfigAction::ClearKey { imp } => {
            let config = Config::load(path)?;
            let (name, _) = config.pick_imp(imp.as_deref())?;
            keys::remove_from_keychain(name)?;
            writeln!(
                io.out,
                "Removed the key for {name} from the system keychain."
            )?;
        }
    }
    Ok(())
}

/// Reads one secret from the input, asking first. Nothing is echoed back.
fn read_secret(io: &mut Io<'_>, ask: &str, missing: &str) -> Result<String> {
    writeln!(
        io.err,
        "{ask} It goes to the system keychain and is not shown again."
    )?;
    io.line()?
        .map(|k| k.trim().to_string())
        .filter(|k| !k.is_empty())
        .ok_or_else(|| CliError(missing.into()))
}

fn set_key(path: &Path, imp: Option<&str>, io: &mut Io<'_>) -> Result<()> {
    let config = Config::load(path)?;
    let (name, _) = config.pick_imp(imp)?;
    let key = read_secret(io, "Paste the key and press enter.", "No key was given.")?;
    keys::save_to_keychain(name, &key)?;
    writeln!(io.out, "Saved the key for {name} in the system keychain.")?;
    Ok(())
}

fn set_header(path: &Path, server: &str, header: &str, io: &mut Io<'_>) -> Result<()> {
    let config = Config::load(path)?;
    let listed = config
        .imps
        .values()
        .filter_map(|i| i.mcp_servers.get(server))
        .any(|s| s.url.is_some() && s.headers.iter().any(|h| h == header));
    if !listed {
        return Err(CliError(format!(
            "No MCP server called {server} lists the header {header}. Add it under headers in the settings file first."
        )));
    }
    let value = read_secret(
        io,
        "Paste the value and press enter.",
        "No value was given.",
    )?;
    keys::save_to_keychain(&keys::header_account(server, header), &value)?;
    writeln!(
        io.out,
        "Saved the header {header} for {server} in the system keychain."
    )?;
    Ok(())
}

fn show(path: &Path, io: &mut Io<'_>) -> Result<()> {
    let config = Config::load(path)?;
    let made = if path.exists() { "" } else { " (not made yet)" };
    writeln!(io.out, "Settings file: {}{made}", path.display())?;
    writeln!(
        io.out,
        "default_imp:   {}",
        config.default_imp.as_deref().unwrap_or("(none)")
    )?;
    writeln!(io.out, "api_key_env:   {}", config.api_key_env)?;
    writeln!(io.out, "retries:       {}", config.retries)?;
    if config.imps.is_empty() {
        writeln!(
            io.out,
            "\nNo Imps yet. Make one with `imp imp new NAME --model MODEL`."
        )?;
        return Ok(());
    }
    writeln!(io.out, "\nAPI keys (the keys themselves are never shown):")?;
    for (name, imp) in &config.imps {
        let var = keys::env_name(&config, imp);
        let status = if keys::real_env(var).is_some_and(|v| !v.trim().is_empty()) {
            format!("found in the environment variable {var}")
        } else {
            format!("{var} is not set, so the system keychain is tried when you chat")
        };
        writeln!(io.out, "  {name}: {status}")?;
    }
    Ok(())
}
