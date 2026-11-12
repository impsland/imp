//! Tool (MCP server) rules of a kit: names, commands, and addresses that must not carry secrets.

use serde_json::Value;

use super::{Problems, pointer_part};

const SECRET_HINTS: [&str; 7] = [
    "key",
    "token",
    "secret",
    "password",
    "auth",
    "sig",
    "credential",
];

pub(super) fn check_server(key: &str, server: &Value, problems: &mut Problems) {
    let at = format!("/mcpServers/{}", pointer_part(key));
    if key.trim().is_empty() || key.chars().count() > 64 {
        problems.add(&at, "tool names have 1 to 64 characters");
    }
    let Some(server) = server.as_object() else {
        problems.add(&at, "must be an object");
        return;
    };
    let command = server.get("command");
    let url = server.get("url");
    match (command, url) {
        (Some(_), Some(_)) => problems.add(&at, "has both a command and a url"),
        (None, None) => problems.add(&at, "needs a command or a url"),
        (Some(c), None) => {
            if !c.as_str().is_some_and(|c| !c.trim().is_empty()) {
                problems.add(&format!("{at}/command"), "must be text");
            }
        }
        (None, Some(u)) => match u.as_str() {
            Some(u) => {
                if let Some(problem) = url_problem(u) {
                    problems.add(&format!("{at}/url"), problem);
                }
            }
            None => problems.add(&format!("{at}/url"), "must be text"),
        },
    }
    if let Some(args) = server.get("args").filter(|a| !a.is_null())
        && !args
            .as_array()
            .is_some_and(|a| a.iter().all(Value::is_string))
    {
        problems.add(&format!("{at}/args"), "must be a list of text");
    }
    for field in ["env", "headers"] {
        let Some(values) = server.get(field).filter(|v| !v.is_null()) else {
            continue;
        };
        let Some(values) = values.as_object() else {
            problems.add(&format!("{at}/{field}"), "must be an object");
            continue;
        };
        for (name, value) in values {
            if value.as_str() != Some("") {
                problems.add(
                    &format!("{at}/{field}/{}", pointer_part(name)),
                    "must be empty, a kit holds no secrets",
                );
            }
        }
    }
}

/// What's wrong with an address in a kit, if anything: not http(s), credentials in it, or a query
/// parameter named like a secret.
pub(super) fn url_problem(url: &str) -> Option<String> {
    let rest = url
        .strip_prefix("https://")
        .or_else(|| url.strip_prefix("http://"));
    let Some(rest) = rest else {
        return Some("must start with https:// or http://".to_owned());
    };
    let rest = rest.split('#').next().unwrap_or_default();
    let (before_query, query) = match rest.split_once('?') {
        Some((a, q)) => (a, Some(q)),
        None => (rest, None),
    };
    let authority = before_query.split('/').next().unwrap_or_default();
    if authority.is_empty() || authority.contains(char::is_whitespace) {
        return Some("has no host".to_owned());
    }
    if authority.contains('@') {
        return Some("must not carry a user name or password".to_owned());
    }
    for pair in query.unwrap_or_default().split('&') {
        let name = pair
            .split('=')
            .next()
            .unwrap_or_default()
            .to_ascii_lowercase();
        if SECRET_HINTS.iter().any(|hint| name.contains(hint)) {
            return Some(format!(
                "has a query parameter ({name}) that looks like a secret"
            ));
        }
    }
    None
}
