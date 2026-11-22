//! The built-in tools, their ids and which tools are offered.
//!
//! Ids are `own.<group>.<tool>` for built-in tools and `mcp.<server>.<tool>` for tools of an MCP
//! server. A group id is the id without its last part. The vectors are `spec/fixtures/tool-filtering.json`.

use std::collections::{BTreeMap, BTreeSet};

/// One tool as the registry knows it.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct ToolEntry {
    pub id: String,
    /// What the model calls it.
    pub name: String,
    /// The group's id (`own.personality`, `mcp.files`).
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

/// The id of a built-in tool group, `own.<group>`.
pub fn own_group_id(group: &str) -> String {
    format!("own.{group}")
}

/// The id of a built-in tool, `own.<group>.<tool>`.
pub fn own_id(group: &str, tool: &str) -> String {
    format!("own.{group}.{tool}")
}

/// A server name as it appears in ids: anything but ASCII letters, digits, `_` and `-` becomes `_`.
/// An empty name becomes `_` as well, so an id always has a server part.
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

/// The id of one MCP server's tool group, `mcp.<server>`, with the server name made into a key.
pub fn mcp_group_id(server: &str) -> String {
    format!("mcp.{}", server_key(server))
}

/// The id of one tool of an MCP server, `mcp.<server>.<tool>`. The tool name is used as the server sent it.
pub fn mcp_id(server: &str, tool: &str) -> String {
    format!("mcp.{}.{tool}", server_key(server))
}

/// The built-in tool groups in the order the Tools tab lists them, each with whether an Imp has the
/// group before anyone chooses. Computer control is opt-in.
pub const GROUPS: [(&str, bool); 8] = [
    ("personality", true),
    ("look", true),
    ("animations", true),
    ("triggers", true),
    ("tools", true),
    ("senses", true),
    ("skills", true),
    ("computer", false),
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

            /// Its group (`animations`, `senses`...).
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
    ImpMessage = ("personality", "imp_message"),
    ImpCreateImp = ("personality", "imp_create_imp"),
    ImpOpenFile = ("personality", "imp_open_file"),
    ImpOpenSettings = ("personality", "imp_open_settings"),
    ImpSetTraits = ("look", "imp_set_traits"),
    ImpShowBackground = ("look", "imp_show_background"),
    ImpSetBackground = ("look", "imp_set_background"),
    ImpPlayAnimations = ("animations", "imp_play_animations"),
    ImpShowAnimation = ("animations", "imp_show_animation"),
    ImpMakeAnimation = ("animations", "imp_make_animation"),
    ImpRemoveAnimation = ("animations", "imp_remove_animation"),
    ImpMove = ("animations", "imp_move"),
    ImpListTriggers = ("triggers", "imp_list_triggers"),
    ImpAddTrigger = ("triggers", "imp_add_trigger"),
    ImpRemoveTrigger = ("triggers", "imp_remove_trigger"),
    ImpListTools = ("tools", "imp_list_tools"),
    ImpAddTool = ("tools", "imp_add_tool"),
    ImpRemoveTool = ("tools", "imp_remove_tool"),
    ImpAddKit = ("tools", "imp_add_kit"),
    ImpExportKit = ("tools", "imp_export_kit"),
    MacStatus = ("senses", "mac_status"),
    BrowserPage = ("senses", "browser_page"),
    UseSkill = ("skills", "use_skill"),
    ComputerObserve = ("computer", "computer_observe"),
    ComputerAct = ("computer", "computer_act"),
    ComputerVerify = ("computer", "computer_verify"),
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

/// The group (`animations`, `senses`...) of the built-in tool the model calls `name`.
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
    /// What the person changed about how single tools read to the model, by id.
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub text: BTreeMap<String, ToolText>,
}

/// What the person wrote over a tool's name and description (the agent file's `toolText`, by tool id).
/// Whatever is `None` stays as the app made it.
#[derive(Debug, Clone, Default, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
pub struct ToolText {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub name: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub description: Option<String>,
}

/// The parts of a description that change, which a description the person wrote may use.
pub const PLACEHOLDERS: [&str; 3] = ["imps", "animations", "place"];

/// A name the model can call a tool by: 1 to 64 letters, digits, `_` and `-`.
pub fn valid_tool_name(name: &str) -> bool {
    (1..=64).contains(&name.len())
        && name
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || c == '_' || c == '-')
}

/// What is wrong with a set of overrides, in plain words: names that are not allowed or are used twice.
pub fn tool_text_problems(text: &BTreeMap<String, ToolText>) -> Vec<String> {
    let mut out = Vec::new();
    let mut seen: BTreeMap<&str, &str> = BTreeMap::new();
    for (id, t) in text {
        let Some(name) = t.name.as_deref() else {
            continue;
        };
        if !valid_tool_name(name) {
            out.push(format!(
                "toolText {id}: the name {name:?} is not allowed: use 1 to 64 letters, digits, _ and -."
            ));
        } else if let Some(other) = seen.insert(name, id) {
            out.push(format!(
                "toolText {id}: the name {name:?} is also used by {other}."
            ));
        }
    }
    out
}

/// Fills `{key}` in `text` from `fills`. A `{...}` that is not a key stays as it is.
pub fn expand_placeholders(text: &str, fills: &BTreeMap<String, String>) -> String {
    let mut out = text.to_string();
    for (key, value) in fills {
        out = out.replace(&format!("{{{key}}}"), value);
    }
    out
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

/// Whether calls to the tool `name` that come together in one reply may run at the same time. Only
/// `imp_message` does: each call waits on a different Imp. Others (the shell, files) may depend on the order.
pub fn runs_concurrently(tool: &str) -> bool {
    tool == BuiltInTool::ImpMessage.name()
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
    fn tool_names_and_placeholders() {
        assert!(valid_tool_name("ask-friend_2") && valid_tool_name(&"x".repeat(64)));
        assert!(
            !valid_tool_name("") && !valid_tool_name("a b") && !valid_tool_name(&"x".repeat(65))
        );
        let fills = BTreeMap::from([("imps".to_string(), "Mo, Bo".to_string())]);
        assert_eq!(
            expand_placeholders("To {imps} {other}", &fills),
            "To Mo, Bo {other}"
        );
    }

    #[test]
    fn only_messages_to_imps_run_together() {
        assert!(runs_concurrently("imp_message"));
        for name in [
            "imp_create_imp",
            "imp_open_file",
            "shell",
            "computer_act",
            "",
        ] {
            assert!(!runs_concurrently(name), "{name}");
        }
    }

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
                ..ToolSelection::all()
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
        assert_eq!(group_of("imp_create_imp"), Some("personality"));
        assert_eq!(group_of("imp_add_kit"), Some("tools"));
        assert_eq!(group_of("imp_export_kit"), Some("tools"));
        assert_eq!(group_of("den_get"), None);
        assert_eq!(group_of("nope"), None);
        assert_eq!(
            built_in_named("computer_act").unwrap().id,
            "own.computer.computer_act"
        );
        assert!(
            group_on_by_default("personality")
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
