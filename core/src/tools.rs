//! The built-in tools, their ids and which tools are offered.
//!
//! Ids are `own.<group>.<tool>` for built-in tools and `mcp.<server>.<tool>` for tools of an MCP
//! server. A group id is the id without its last part. The vectors are `spec/fixtures/tool-filtering.json`.

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

/// The built-in tool groups in the order the Tools tab lists them, and whether an Imp has the group
/// before anyone chooses. Computer control and sharing in the Den (which is public) are opt-in.
pub const GROUPS: [(&str, bool); 6] = [
    ("body", true),
    ("senses", true),
    ("setup", true),
    ("troupe", true),
    ("computer", false),
    ("den", false),
];

/// Declares every built-in tool once: the variant the apps dispatch on, its group and the name the
/// model calls it. [`BuiltInTool`] and [`BUILT_IN`] both come from this one list.
macro_rules! built_in_tools {
    ($($variant:ident = ($group:literal, $name:literal),)*) => {
        /// A built-in tool. The apps match on it to run the tool, so they never spell a tool name.
        #[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
        pub enum BuiltInTool {
            $($variant,)*
        }

        impl BuiltInTool {
            /// Every built-in tool, in the order the Tools tab lists them.
            pub const ALL: &[BuiltInTool] = &[$(Self::$variant,)*];

            /// The name the model calls it.
            pub fn name(self) -> &'static str {
                match self {
                    $(Self::$variant => $name,)*
                }
            }

            /// Its group (`body`, `den`...).
            pub fn group(self) -> &'static str {
                match self {
                    $(Self::$variant => $group,)*
                }
            }

            /// The built-in tool the model calls `name`.
            pub fn named(name: &str) -> Option<Self> {
                Self::ALL.iter().copied().find(|t| t.name() == name)
            }
        }

        /// Every built-in tool as (group, name the model calls it), in the order the Tools tab lists them.
        pub const BUILT_IN: &[(&str, &str)] = &[$(($group, $name),)*];
    };
}

built_in_tools! {
    ImpPlayAnimations = ("body", "imp_play_animations"),
    ImpMove = ("body", "imp_move"),
    ImpSpeak = ("body", "imp_speak"),
    ImpMakeAnimation = ("body", "imp_make_animation"),
    ImpShowAnimation = ("body", "imp_show_animation"),
    ImpRemoveAnimation = ("body", "imp_remove_animation"),
    ImpSetTraits = ("body", "imp_set_traits"),
    MacStatus = ("senses", "mac_status"),
    BrowserPage = ("senses", "browser_page"),
    ImpListTriggers = ("setup", "imp_list_triggers"),
    ImpAddTrigger = ("setup", "imp_add_trigger"),
    ImpRemoveTrigger = ("setup", "imp_remove_trigger"),
    ImpListTools = ("setup", "imp_list_tools"),
    ImpAddTool = ("setup", "imp_add_tool"),
    ImpRemoveTool = ("setup", "imp_remove_tool"),
    ImpOpenSettings = ("setup", "imp_open_settings"),
    ImpMessage = ("troupe", "imp_message"),
    ImpOpenFile = ("troupe", "imp_open_file"),
    ComputerObserve = ("computer", "computer_observe"),
    ComputerAct = ("computer", "computer_act"),
    ComputerVerify = ("computer", "computer_verify"),
    DenSearch = ("den", "den_search"),
    DenGet = ("den", "den_get"),
    DenAdd = ("den", "den_add"),
    DenShare = ("den", "den_share"),
    DenUnshare = ("den", "den_unshare"),
    DenAccount = ("den", "den_account"),
}

/// Every built-in tool as a registry entry, in listing order.
pub fn built_in() -> Vec<ToolEntry> {
    BUILT_IN.iter().map(|(g, t)| ToolEntry::own(g, t)).collect()
}

/// The built-in tool the model calls `name`.
pub fn built_in_named(name: &str) -> Option<ToolEntry> {
    BUILT_IN
        .iter()
        .find(|(_, t)| *t == name)
        .map(|(g, t)| ToolEntry::own(g, t))
}

/// The group (`body`, `den`...) of the built-in tool the model calls `name`.
pub fn group_of(name: &str) -> Option<&'static str> {
    BUILT_IN.iter().find(|(_, t)| *t == name).map(|(g, _)| *g)
}

/// Whether an Imp has the group before anyone chooses. An unknown group is off.
pub fn group_on_by_default(group: &str) -> bool {
    GROUPS.iter().any(|(g, on)| *g == group && *on)
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

    #[test]
    fn every_built_in_tool_has_one_name_and_a_known_group() {
        assert_eq!(BuiltInTool::ALL.len(), BUILT_IN.len());
        for (tool, (group, name)) in BuiltInTool::ALL.iter().zip(BUILT_IN) {
            assert_eq!((tool.group(), tool.name()), (*group, *name));
            assert_eq!(BuiltInTool::named(name), Some(*tool));
            assert!(
                GROUPS.iter().any(|(g, _)| g == group),
                "{name} is in no group"
            );
        }
        let names: std::collections::HashSet<_> = BUILT_IN.iter().map(|(_, n)| n).collect();
        assert_eq!(names.len(), BUILT_IN.len());
        assert_eq!(BuiltInTool::named("nope"), None);
    }

    fn fixture() -> Value {
        let path = concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/../spec/fixtures/tool-filtering.json"
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
    fn built_in_registry_is_consistent() {
        let all = built_in();
        let ids: BTreeSet<&str> = all.iter().map(|e| e.id.as_str()).collect();
        assert_eq!(ids.len(), all.len());
        for (g, _) in GROUPS {
            assert!(BUILT_IN.iter().any(|(bg, _)| *bg == g), "{g} has no tools");
        }
        assert_eq!(group_of("imp_speak"), Some("body"));
        assert_eq!(group_of("den_get"), Some("den"));
        assert_eq!(group_of("nope"), None);
        assert_eq!(
            built_in_named("computer_act").unwrap().id,
            "own.computer.computer_act"
        );
        assert!(
            group_on_by_default("body")
                && !group_on_by_default("computer")
                && !group_on_by_default("x")
        );
    }

    #[test]
    fn server_keys() {
        assert_eq!(server_key(""), "_");
        assert_eq!(server_key("a b/ü"), "a_b__");
        assert!(refusal("x").contains("switched off"));
    }
}
