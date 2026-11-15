//! Setting up an MCP server from what its page tells you to copy, and from MCP config files. No I/O.
//!
//! - [`parse_setup`] is forgiving, for text a person pastes: a JSON config (`{"mcpServers": {...}}`,
//!   `"servers"`, a bare `"name": {...}` pair, one server object), a web address, or a command line.
//!   It names each server, from the config or from the package or host.
//! - [`parse_config_file`] is strict, for a file such as `.agents/mcp.json`: it says what is wrong.
//! - [`split_words`] and [`join_words`] read and write a command line as a shell does, with quotes and
//!   backslashes.
//!
//! The Mac app and the command line both use these. The vectors are `spec/fixtures/mcp-setup.json`.

use serde_json::{Map, Value};
use std::collections::BTreeMap;

/// One server found in setup text: a command to start (`command`, `args`, `env`) or an address
/// (`url`, `headers`). `name` is empty when nothing suggested one (the app shows its own word then).
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct SetupServer {
    pub name: String,
    pub command: String,
    pub args: Vec<String>,
    pub env: BTreeMap<String, String>,
    pub url: String,
    pub headers: BTreeMap<String, String>,
}

impl SetupServer {
    /// Reached over HTTP rather than started.
    pub fn is_http(&self) -> bool {
        !self.url.is_empty()
    }

    /// The server in a few words: its address, or its command line. Values are never shown.
    pub fn describe(&self) -> String {
        if self.is_http() {
            self.url.clone()
        } else {
            join_words(&self.command, &self.args)
        }
    }
}

/// The words of a command line, and whether a quote or a backslash was left open at its end.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Words {
    pub words: Vec<String>,
    pub unclosed: bool,
}

/// Splits a command line into words as a shell does: whitespace separates them, `'...'` and `"..."`
/// keep spaces, a backslash takes the next character as it is (not inside single quotes).
pub fn split_words(line: &str) -> Words {
    let mut words = Vec::new();
    let mut word = String::new();
    let mut quote: Option<char> = None;
    let mut escaped = false;
    let mut in_word = false;
    for ch in line.chars() {
        if escaped {
            word.push(ch);
            escaped = false;
            in_word = true;
            continue;
        }
        match ch {
            '\\' if quote != Some('\'') => escaped = true,
            '\'' | '"' => match quote {
                None => {
                    quote = Some(ch);
                    in_word = true;
                }
                Some(q) if q == ch => quote = None,
                Some(_) => word.push(ch),
            },
            c if c.is_whitespace() && quote.is_none() => {
                if in_word {
                    words.push(std::mem::take(&mut word));
                    in_word = false;
                }
            }
            c => {
                word.push(c);
                in_word = true;
            }
        }
    }
    if in_word {
        words.push(word);
    }
    Words {
        words,
        unclosed: quote.is_some() || escaped,
    }
}

/// A word as a command line writes it: as it is, or in single quotes when it is empty or has a
/// space, a quote or a backslash.
pub fn quote_word(word: &str) -> String {
    let plain = !word.is_empty()
        && !word
            .chars()
            .any(|c| c.is_whitespace() || matches!(c, '\'' | '"' | '\\'));
    if plain {
        word.to_string()
    } else {
        format!("'{}'", word.replace('\'', r"'\''"))
    }
}

/// A command and its arguments as one line that [`split_words`] reads back the same. Empty when all are.
pub fn join_words(command: &str, args: &[String]) -> String {
    let all: Vec<&str> = std::iter::once(command)
        .chain(args.iter().map(String::as_str))
        .collect();
    if all.iter().all(|w| w.is_empty()) {
        return String::new();
    }
    all.iter()
        .map(|w| quote_word(w))
        .collect::<Vec<_>>()
        .join(" ")
}

/// The servers in what a person pasted. Empty when it is none of the forms in the module notes.
pub fn parse_setup(text: &str) -> Vec<SetupServer> {
    let trimmed = text.trim();
    if trimmed.is_empty() {
        return Vec::new();
    }
    if trimmed.starts_with('{') || trimmed.starts_with('"') {
        // Snippets are often a bare `"name": {...}` pair or end in a stray comma.
        let mut json = trimmed.trim_end_matches(',').to_string();
        if json.starts_with('"') {
            json = format!("{{{json}}}");
        }
        return match serde_json::from_str::<Value>(&json) {
            Ok(Value::Object(object)) => servers_in(&object),
            _ => Vec::new(),
        };
    }
    let line = trimmed.strip_prefix("$ ").unwrap_or(trimmed);
    if http_host(line).is_some() {
        return vec![SetupServer {
            name: suggested_name_for_url(line),
            url: line.to_string(),
            ..SetupServer::default()
        }];
    }
    let words = split_words(line).words;
    let Some((command, args)) = words.split_first() else {
        return Vec::new();
    };
    if command.is_empty() {
        return Vec::new();
    }
    let mut server = SetupServer {
        command: command.clone(),
        args: args.to_vec(),
        ..SetupServer::default()
    };
    server.name = command_name(&server);
    vec![server]
}

/// The servers of an MCP config file: `{"mcpServers": {"NAME": {...}}}` (or `servers`). A server with
/// `"disabled": true` is left out. The error is a short sentence about the file, such as
/// `it has no "mcpServers" object.`
pub fn parse_config_file(text: &str) -> Result<Vec<SetupServer>, String> {
    let value: Value = serde_json::from_str(text).map_err(|e| format!("it is not JSON ({e})."))?;
    let servers = value
        .get("mcpServers")
        .or_else(|| value.get("servers"))
        .and_then(Value::as_object)
        .ok_or_else(|| "it has no \"mcpServers\" object.".to_string())?;
    let mut out = Vec::new();
    for (name, server) in servers {
        let Value::Object(object) = server else {
            return Err(format!("{name} is not an object."));
        };
        if object.get("disabled").and_then(Value::as_bool) == Some(true) {
            continue;
        }
        let Some(found) = server_from(object, Some(name)) else {
            return Err(format!("{name} needs either a \"command\" or a \"url\"."));
        };
        if found.is_http() && http_host(&found.url).is_none() {
            return Err(format!(
                "the url of {name} must start with http:// or https://."
            ));
        }
        out.push(found);
    }
    Ok(out)
}

fn servers_in(object: &Map<String, Value>) -> Vec<SetupServer> {
    for key in ["mcpServers", "servers", "mcp"] {
        if let Some(Value::Object(map)) = object.get(key) {
            return servers_in(map);
        }
    }
    if let Some(one) = server_from(object, None) {
        return vec![one];
    }
    // serde_json keeps keys sorted, so the order is the same everywhere.
    object
        .iter()
        .filter_map(|(name, value)| match value {
            Value::Object(o) => server_from(o, Some(name)),
            _ => None,
        })
        .collect()
}

/// Text from a JSON value: a string as it is, a number as it is written.
fn text(value: &Value) -> Option<String> {
    match value {
        Value::String(s) => Some(s.clone()),
        Value::Number(n) => Some(n.to_string()),
        _ => None,
    }
}

fn strings(object: &Map<String, Value>, key: &str) -> BTreeMap<String, String> {
    object
        .get(key)
        .and_then(Value::as_object)
        .map(|o| {
            o.iter()
                .filter_map(|(k, v)| Some((k.clone(), text(v)?)))
                .collect()
        })
        .unwrap_or_default()
}

fn server_from(object: &Map<String, Value>, name: Option<&String>) -> Option<SetupServer> {
    let url = object
        .get("url")
        .or_else(|| object.get("serverUrl"))
        .and_then(Value::as_str)
        .filter(|u| !u.is_empty());
    if let Some(url) = url {
        return Some(SetupServer {
            name: name.cloned().unwrap_or_else(|| suggested_name_for_url(url)),
            url: url.to_string(),
            headers: strings(object, "headers"),
            ..SetupServer::default()
        });
    }
    let command = object
        .get("command")
        .and_then(Value::as_str)
        .filter(|c| !c.is_empty())?;
    let args: Vec<String> = object
        .get("args")
        .and_then(Value::as_array)
        .map(|a| a.iter().filter_map(text).collect())
        .unwrap_or_default();
    let mut server = SetupServer {
        name: name.cloned().unwrap_or_default(),
        env: strings(object, "env"),
        ..SetupServer::default()
    };
    // Some snippets put the whole command line in `command`.
    if args.is_empty() && command.contains(' ') {
        let mut words = split_words(command).words.into_iter();
        server.command = words.next().unwrap_or_default();
        server.args = words.collect();
    } else {
        server.command = command.to_string();
        server.args = args;
    }
    if server.name.is_empty() {
        server.name = command_name(&server);
    }
    Some(server)
}

fn command_name(server: &SetupServer) -> String {
    let mut words = server.args.clone();
    words.push(server.command.clone());
    suggested_name_for_command(&words)
}

/// The host of an `http://` or `https://` address with no spaces in it.
fn http_host(line: &str) -> Option<&str> {
    let lower = line.to_ascii_lowercase();
    let rest = if lower.starts_with("https://") {
        &line[8..]
    } else if lower.starts_with("http://") {
        &line[7..]
    } else {
        return None;
    };
    if line.contains(char::is_whitespace) {
        return None;
    }
    let authority = rest.split(['/', '?', '#']).next().unwrap_or("");
    let host_port = authority.rsplit('@').next().unwrap_or("");
    let host = if host_port.starts_with('[') {
        host_port.split(']').next().map(|h| &h[1..]).unwrap_or("")
    } else {
        host_port.split(':').next().unwrap_or("")
    };
    (!host.is_empty()).then_some(host)
}

fn capitalized(word: &str) -> String {
    let mut chars = word.chars();
    match chars.next() {
        Some(first) => first.to_uppercase().chain(chars).collect(),
        None => String::new(),
    }
}

/// A name from a command's words (its arguments, then the command): `Memory` for
/// `npx -y @modelcontextprotocol/server-memory`, `Fetch` for `uvx mcp-server-fetch`. Empty if none.
pub fn suggested_name_for_command(words: &[String]) -> String {
    const RUNNERS: &[&str] = &[
        "npx", "uvx", "bunx", "pnpx", "node", "python", "python3", "uv", "docker", "deno", "run",
        "-y", "--yes",
    ];
    let word = words
        .iter()
        .find(|w| {
            !w.starts_with('-')
                && !RUNNERS.contains(&w.as_str())
                && !w.starts_with('/')
                && !w.starts_with('~')
        })
        .or(words.last())
        .map_or("", String::as_str);
    let mut base = word.split('/').rfind(|p| !p.is_empty()).unwrap_or("");
    // A version after the package (`pkg@1.2`), but not the `@` of a scope.
    if let Some(at) = base.find('@').filter(|at| *at > 0) {
        base = &base[..at];
    }
    for affix in ["mcp-server-", "server-", "mcp-"] {
        if let Some(rest) = base.strip_prefix(affix) {
            base = rest;
            break;
        }
    }
    for affix in ["-mcp-server", "-mcp", "-server"] {
        if let Some(rest) = base.strip_suffix(affix) {
            base = rest;
            break;
        }
    }
    base.split(['-', '_'])
        .filter(|p| !p.is_empty())
        .map(capitalized)
        .collect::<Vec<_>>()
        .join(" ")
}

/// A name from an address: `Example` for `https://mcp.example.com/mcp`. Empty without a host.
pub fn suggested_name_for_url(url: &str) -> String {
    let Some(host) = http_host(url) else {
        return String::new();
    };
    let host = host.to_lowercase();
    let parts: Vec<&str> = host
        .split('.')
        .filter(|p| !p.is_empty() && !["mcp", "api", "www"].contains(p))
        .collect();
    let core = if parts.len() >= 2 {
        parts[parts.len() - 2]
    } else {
        parts.first().copied().unwrap_or(&host)
    };
    capitalized(core)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn fixture() -> Value {
        let text = include_str!("../../../spec/fixtures/mcp-setup.json");
        serde_json::from_str(text).unwrap()
    }

    fn server_json(s: &SetupServer) -> Value {
        serde_json::json!({
            "name": s.name, "command": s.command, "args": s.args, "env": s.env,
            "url": s.url, "headers": s.headers,
        })
    }

    /// A server as the fixture writes it: fields left out are empty.
    fn expected(v: &Value) -> Value {
        let field = |k: &str, empty: Value| v.get(k).cloned().unwrap_or(empty);
        serde_json::json!({
            "name": field("name", "".into()),
            "command": field("command", "".into()),
            "args": field("args", serde_json::json!([])),
            "env": field("env", serde_json::json!({})),
            "url": field("url", "".into()),
            "headers": field("headers", serde_json::json!({})),
        })
    }

    #[test]
    fn the_shared_vectors() {
        let f = fixture();
        for case in f["words"].as_array().unwrap() {
            let got = split_words(case["line"].as_str().unwrap());
            let want: Vec<String> = serde_json::from_value(case["words"].clone()).unwrap();
            assert_eq!(got.words, want, "{case}");
            assert_eq!(got.unclosed, case["unclosed"].as_bool().unwrap(), "{case}");
        }
        for case in f["quote"].as_array().unwrap() {
            let word = case["word"].as_str().unwrap();
            assert_eq!(quote_word(word), case["quoted"].as_str().unwrap(), "{case}");
            assert_eq!(split_words(&quote_word(word)).words, [word]);
        }
        for case in f["setup"].as_array().unwrap() {
            let got: Vec<Value> = parse_setup(case["text"].as_str().unwrap())
                .iter()
                .map(server_json)
                .collect();
            let want: Vec<Value> = case["servers"]
                .as_array()
                .unwrap()
                .iter()
                .map(expected)
                .collect();
            assert_eq!(got, want, "{}", case["name"]);
        }
        for case in f["files"].as_array().unwrap() {
            let got = parse_config_file(case["text"].as_str().unwrap());
            match case.get("servers") {
                Some(servers) => {
                    let got: Vec<Value> = got.unwrap().iter().map(server_json).collect();
                    let want: Vec<Value> =
                        servers.as_array().unwrap().iter().map(expected).collect();
                    assert_eq!(got, want, "{}", case["name"]);
                }
                None => {
                    let error = got.unwrap_err();
                    let wanted = case["error"].as_str().unwrap();
                    assert!(error.contains(wanted), "{}: {error}", case["name"]);
                }
            }
        }
    }

    #[test]
    fn a_command_line_reads_back_the_same() {
        let args: Vec<String> = ["-y", "@scope/server fs", "it's", "", "a\\b"]
            .iter()
            .map(|s| s.to_string())
            .collect();
        let line = join_words("npx", &args);
        let words = split_words(&line).words;
        assert_eq!(words[0], "npx");
        assert_eq!(words[1..], args[..]);
        assert_eq!(join_words("", &[]), "");
    }
}
