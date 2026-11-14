//! `imp mcp`: an Imp's MCP servers in the settings file. The chat has the same as `/mcp`.

use super::Io;
use crate::cli::McpAction;
use crate::config::{Config, valid_imp_name};
use crate::session::describe_server;
use crate::slash::server_from;
use crate::{CliError, Result};
use std::path::Path;

pub fn run(path: &Path, action: McpAction, io: &mut Io<'_>) -> Result<()> {
    let mut config = Config::load_with_ids(path)?;
    match action {
        McpAction::List { imp } => {
            let (name, imp) = config.pick_imp(imp.as_deref())?;
            if imp.mcp_servers.is_empty() {
                writeln!(io.out, "{name} has no MCP servers.")?;
                writeln!(
                    io.out,
                    "Add one with `imp mcp add NAME -- COMMAND [ARGS...]`, such as\n  imp mcp add files -- npx -y @modelcontextprotocol/server-filesystem ."
                )?;
                return Ok(());
            }
            let width = imp.mcp_servers.keys().map(String::len).max().unwrap_or(0);
            for (server, settings) in &imp.mcp_servers {
                writeln!(io.out, "{server:width$}  {}", describe_server(settings))?;
            }
        }
        McpAction::Add {
            name,
            imp,
            env,
            headers,
            target,
        } => {
            if !valid_imp_name(&name) {
                return Err(CliError(
                    "A server's name can have 1 to 32 letters, digits, dashes and underscores."
                        .into(),
                ));
            }
            let (first, rest) = target
                .split_first()
                .ok_or_else(|| CliError("Give a command or an address.".into()))?;
            let mut words = rest.to_vec();
            for var in env {
                words.extend(["--env".to_string(), var]);
            }
            for header in headers {
                words.extend(["--header".to_string(), header]);
            }
            let server = server_from(first, &words)?;
            let imp_name = config.pick_imp(imp.as_deref())?.0.to_string();
            let settings = config.imps.get_mut(&imp_name).expect("picked above");
            let replaced = settings.mcp_servers.insert(name.clone(), server.clone());
            config.save(path)?;
            writeln!(
                io.out,
                "{} the MCP server {name} for {imp_name}: {}",
                if replaced.is_some() {
                    "Replaced"
                } else {
                    "Added"
                },
                describe_server(&server)
            )?;
            writeln!(
                io.out,
                "It starts with the next chat. `.` and ${{workspaceFolder}} are the folder you chat in."
            )?;
        }
        McpAction::Remove { name, imp } => {
            let imp_name = config.pick_imp(imp.as_deref())?.0.to_string();
            let settings = config.imps.get_mut(&imp_name).expect("picked above");
            if settings.mcp_servers.remove(&name).is_none() {
                return Err(CliError(format!(
                    "{imp_name} has no MCP server called {name}."
                )));
            }
            config.save(path)?;
            writeln!(io.out, "Removed the MCP server {name} from {imp_name}.")?;
        }
    }
    Ok(())
}
