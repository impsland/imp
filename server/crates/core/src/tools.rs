//! Tool ids and which tools are offered. Follows Swift `ToolRegistry`.
//!
//! Ids are `own.<group>.<tool>` for built-in tools and `mcp.<server>.<tool>` for tools of an MCP
//! server. A group id is the id without its last part. The vectors are `Tests/Fixtures/tool-filtering.json`.

use std::collections::BTreeSet;

/// One tool as the registry knows it.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct ToolEntry {
    pub id: String,
    /// What the model calls it.
    pub name: String,
    /// The group's id (`own.body`, `mcp.files`).
    pub group: String,
    pub title: String,
}

impl ToolEntry {
    pub fn new(id: impl Into<String>, name: impl Into<String>, group: impl Into<String>) -> Self {
        Self {
            id: id.into(),
            name: name.into(),
            group: group.into(),
            title: String::new(),
        }
    }

    /// A built-in tool entry from its group and tool name.
    pub fn own(group: &str, tool: &str) -> Self {
        Self::new(own_id(group, tool), tool, own_group_id(group))
    }

    /// An entry for a tool of an MCP server.
    pub fn mcp(server: &str, tool: &str, exposed_name: &str) -> Self {
        Self::new(mcp_id(server, tool), exposed_name, mcp_group_id(server))
    }
}

pub fn own_group_id(group: &str) -> String {
    format!("own.{group}")
}

pub fn own_id(group: &str, tool: &str) -> String {
    format!("own.{group}.{tool}")
}

/// A server name as it appears in ids: anything but ASCII letters, digits, `_` and `-` becomes `_`.
pub fn server_key(name: &str) -> String {
    let mapped: String = name
        .chars()
        .map(|c| {
            if c.is_ascii_alphanumeric() || c == '_' || c == '-' {
                c
            } else {
                '_'
            }
        })
        .collect();
    if mapped.is_empty() {
        "_".to_string()
    } else {
        mapped
    }
}

pub fn mcp_group_id(server: &str) -> String {
    format!("mcp.{}", server_key(server))
}

pub fn mcp_id(server: &str, tool: &str) -> String {
    format!("mcp.{}.{tool}", server_key(server))
}

/// What is switched off: whole groups and single tools, by id. Everything else is on.
#[derive(Debug, Clone, Default, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
pub struct ToolSelection {
    #[serde(default)]
    pub groups_off: BTreeSet<String>,
    #[serde(default)]
    pub tools_off: BTreeSet<String>,
}

impl ToolSelection {
    /// Everything on.
    pub fn all() -> Self {
        Self::default()
    }

    /// A tool without an entry can't be switched, so it is allowed.
    pub fn allows(&self, entry: Option<&ToolEntry>) -> bool {
        match entry {
            None => true,
            Some(e) => !self.groups_off.contains(&e.group) && !self.tools_off.contains(&e.id),
        }
    }

    /// The items this selection leaves on. `entry_of` gives an item's entry, if it has one.
    pub fn filter<'a, T>(
        &self,
        items: &'a [T],
        entry_of: impl Fn(&T) -> Option<&ToolEntry>,
    ) -> Vec<&'a T> {
        items.iter().filter(|t| self.allows(entry_of(t))).collect()
    }
}

/// What a call to a switched-off tool is told.
pub fn refusal(name: &str) -> String {
    format!(
        "The tool {name} is switched off, so it can't be used. Do it another way, or tell the user it can be switched on in Settings."
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::Value;

    fn fixture() -> Value {
        let path = concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/../../../Tests/Fixtures/tool-filtering.json"
        );
        serde_json::from_str(&std::fs::read_to_string(path).expect("fixture")).expect("json")
    }

    fn strings(v: &Value) -> BTreeSet<String> {
        v.as_array()
            .map(|a| a.iter().map(|s| s.as_str().unwrap().to_string()).collect())
            .unwrap_or_default()
    }

    #[test]
    fn ids_match_the_vectors() {
        let f = fixture();
        for row in f["ids"].as_array().unwrap() {
            let tool = row["tool"].as_str().unwrap();
            let (id, group) = match row["kind"].as_str().unwrap() {
                "own" => {
                    let g = row["group"].as_str().unwrap();
                    (own_id(g, tool), own_group_id(g))
                }
                _ => {
                    let s = row["server"].as_str().unwrap();
                    (mcp_id(s, tool), mcp_group_id(s))
                }
            };
            assert_eq!(id, row["id"].as_str().unwrap());
            assert_eq!(group, row["groupID"].as_str().unwrap());
        }
    }

    #[test]
    fn filtering_matches_the_vectors() {
        let f = fixture();
        let cases = f["cases"].as_array().unwrap();
        assert!(!cases.is_empty());
        for case in cases {
            let selection = ToolSelection {
                groups_off: strings(&case["groupsOff"]),
                tools_off: strings(&case["toolsOff"]),
            };
            let tools: Vec<(String, Option<ToolEntry>)> = case["tools"]
                .as_array()
                .unwrap()
                .iter()
                .map(|t| {
                    let name = t["name"].as_str().unwrap().to_string();
                    let entry = t["id"]
                        .as_str()
                        .map(|id| ToolEntry::new(id, &name, t["group"].as_str().unwrap()));
                    (name, entry)
                })
                .collect();
            let offered: Vec<&str> = selection
                .filter(&tools, |t| t.1.as_ref())
                .iter()
                .map(|t| t.0.as_str())
                .collect();
            let want: Vec<&str> = case["offered"]
                .as_array()
                .unwrap()
                .iter()
                .map(|s| s.as_str().unwrap())
                .collect();
            assert_eq!(offered, want, "{}", case["name"]);
        }
    }

    #[test]
    fn server_keys() {
        assert_eq!(server_key(""), "_");
        assert_eq!(server_key("a b/ü"), "a_b__");
        assert!(refusal("x").contains("switched off"));
    }
}
