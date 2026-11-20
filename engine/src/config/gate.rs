//! What a tool call is, as far as permissions go: the action and the resource the rules are read against
//! (`docs/architecture/configuration.md`, "Permissions"). Both apps classify with [`classify`], so a rule
//! means the same in the terminal and on the Mac. The vectors are `spec/fixtures/config/vectors.json`
//! (`gate`).
//!
//! | The call | Action | Resource |
//! |---|---|---|
//! | an Imp's own tool (`own.<group>.<tool>`, or a built-in name) | the group | the tool's name |
//! | `imp_message` | `message` | the Imp's name (`to`) |
//! | `imp_create_imp` | `personality` | `imp_create_imp` (an own tool like the rest) |
//! | the skill tool | `skill` | the skill's name |
//! | a tool of an MCP server (`mcp.<server>.<tool>`) | `mcp` | `<server>/<tool>` |
//! | a shell tool | `shell` | the command line |
//! | a tool that reads a file | `read` | the path |
//! | a tool that writes or edits a file | `edit` | the path |
//! | anything else | the tool's own name | `*` |

use crate::agents::SKILL_TOOL;
use crate::config::permissions::{Effect, Rule, decide_in};
use crate::tools::{BuiltInTool, server_key};
use serde_json::Value;

/// The name of the tool that asks another Imp.
const MESSAGE_TOOL: &str = "imp_message";
const SHELL_TOOLS: &[&str] = &["shell", "run_command", "bash"];
const READ_TOOLS: &[&str] = &["read_file", "read", "view_file"];
const EDIT_TOOLS: &[&str] = &[
    "write_file",
    "create_file",
    "edit_file",
    "write",
    "edit",
    "str_replace_editor",
];

/// What a tool call does, in the words the rules use.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Permission {
    pub action: String,
    pub resource: String,
}

impl Permission {
    fn new(action: &str, resource: impl Into<String>) -> Self {
        Self {
            action: action.into(),
            resource: resource.into(),
        }
    }

    /// `shell ls -la`, `mcp files/read_file`: how a person reads it.
    pub fn what(&self) -> String {
        format!("{} {}", self.action, self.resource)
    }
}

/// The first of `keys` that is a text in the JSON `arguments`; `*` when there is none (no arguments at all
/// is how a tool list is classified, before any call is made).
fn argument(arguments: &str, keys: &[&str]) -> String {
    serde_json::from_str::<Value>(arguments)
        .ok()
        .and_then(|v| {
            keys.iter()
                .find_map(|k| v.get(k).and_then(Value::as_str).map(str::to_string))
        })
        .filter(|s| !s.is_empty())
        .unwrap_or_else(|| "*".into())
}

/// The action and resource of the call of tool `name` (its registry id, when it has one) with the model's JSON
/// `arguments`. `servers` are the names of the MCP servers, to give a server's key (the part of an id) its name.
pub fn classify(
    tool_id: Option<&str>,
    name: &str,
    arguments: &str,
    servers: &[String],
) -> Permission {
    if name == SKILL_TOOL {
        return Permission::new("skill", argument(arguments, &["name"]));
    }
    if name == MESSAGE_TOOL {
        return Permission::new("message", argument(arguments, &["to"]));
    }
    if let Some(id) = tool_id {
        if let Some((group, tool)) = id.strip_prefix("own.").and_then(|r| r.split_once('.')) {
            return Permission::new(group, tool);
        }
        if let Some((key, tool)) = id.strip_prefix("mcp.").and_then(|r| r.split_once('.')) {
            let server = servers
                .iter()
                .find(|s| server_key(s) == key)
                .map_or(key, String::as_str);
            return Permission::new("mcp", format!("{server}/{tool}"));
        }
    }
    if let Some(tool) = BuiltInTool::named(name) {
        return Permission::new(tool.group(), name);
    }
    if SHELL_TOOLS.contains(&name) {
        return Permission::new("shell", argument(arguments, &["command", "cmd"]));
    }
    if READ_TOOLS.contains(&name) {
        return Permission::new("read", argument(arguments, &["path", "file_path", "file"]));
    }
    if EDIT_TOOLS.contains(&name) {
        return Permission::new("edit", argument(arguments, &["path", "file_path", "file"]));
    }
    Permission::new(name, "*")
}

/// The verdict on one call: what it is and what the rules say (`~` in a rule's resource is `home`).
pub fn judge(
    rules: &[Rule],
    home: Option<&str>,
    tool_id: Option<&str>,
    name: &str,
    arguments: &str,
    servers: &[String],
) -> (Effect, Permission) {
    let permission = classify(tool_id, name, arguments, servers);
    let effect = decide_in(rules, &permission.action, &permission.resource, home);
    (effect, permission)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::tools::{mcp_id, own_id};

    fn servers() -> Vec<String> {
        vec!["my files".to_string()]
    }

    fn is(p: Permission, action: &str, resource: &str) {
        assert_eq!((p.action.as_str(), p.resource.as_str()), (action, resource));
    }

    #[test]
    fn own_tools_are_their_group_and_name() {
        for (group, tool) in crate::tools::BUILT_IN {
            if *tool == MESSAGE_TOOL {
                continue;
            }
            let id = own_id(group, tool);
            is(classify(Some(&id), tool, "{}", &[]), group, tool);
            is(classify(None, tool, "{}", &[]), group, tool);
        }
    }

    #[test]
    fn a_message_is_the_name_of_the_imp() {
        let id = own_id("personality", MESSAGE_TOOL);
        is(
            classify(Some(&id), MESSAGE_TOOL, r#"{"to":"Pip","text":"hi"}"#, &[]),
            "message",
            "Pip",
        );
        is(classify(Some(&id), MESSAGE_TOOL, "", &[]), "message", "*");
    }

    #[test]
    fn a_skill_is_its_name() {
        is(
            classify(None, SKILL_TOOL, r#"{"name":"review"}"#, &[]),
            "skill",
            "review",
        );
    }

    #[test]
    fn an_mcp_tool_is_server_and_tool_with_the_servers_own_name() {
        let id = mcp_id("my files", "write_file");
        assert_eq!(id, "mcp.my_files.write_file");
        is(
            classify(Some(&id), "my_files_write_file", "{}", &servers()),
            "mcp",
            "my files/write_file",
        );
        is(
            classify(Some(&id), "x", "{}", &[]),
            "mcp",
            "my_files/write_file",
        );
        let dotted = mcp_id("files", "a.b");
        is(classify(Some(&dotted), "x", "{}", &[]), "mcp", "files/a.b");
    }

    #[test]
    fn shell_reads_and_edits_are_the_command_or_the_path() {
        for name in SHELL_TOOLS {
            is(
                classify(None, name, r#"{"command":"rm -rf /tmp/x"}"#, &[]),
                "shell",
                "rm -rf /tmp/x",
            );
        }
        for name in READ_TOOLS {
            is(
                classify(None, name, r#"{"path":"/etc/hosts"}"#, &[]),
                "read",
                "/etc/hosts",
            );
        }
        for name in EDIT_TOOLS {
            is(
                classify(None, name, r#"{"file_path":"/tmp/a"}"#, &[]),
                "edit",
                "/tmp/a",
            );
        }
        is(classify(None, "shell", "not json", &[]), "shell", "*");
    }

    #[test]
    fn anything_else_is_its_own_action() {
        is(
            classify(None, "teleport", r#"{"to":"x"}"#, &[]),
            "teleport",
            "*",
        );
    }

    #[test]
    fn the_rules_decide_on_what_was_classified() {
        let rules = [
            Rule::new("shell", "rm -rf *", Effect::Deny),
            Rule::new("mcp", "files/write_file", Effect::Ask),
        ];
        let (effect, p) = judge(
            &rules,
            None,
            None,
            "shell",
            r#"{"command":"rm -rf /"}"#,
            &[],
        );
        assert_eq!(effect, Effect::Deny);
        assert_eq!(p.what(), "shell rm -rf /");
        let id = mcp_id("files", "write_file");
        let (effect, _) = judge(&rules, None, Some(&id), "x", "{}", &["files".into()]);
        assert_eq!(effect, Effect::Ask);
        let (effect, _) = judge(&rules, None, None, "shell", r#"{"command":"ls"}"#, &[]);
        assert_eq!(effect, Effect::Allow);
    }
}
