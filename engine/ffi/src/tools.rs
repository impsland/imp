//! Tool ids and the one selection rule.

use imp_engine::tools::{self, BuiltInTool};

/// What is switched off: whole groups and single tools, by id.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct ToolSelection {
    pub groups_off: Vec<String>,
    pub tools_off: Vec<String>,
}

impl From<ToolSelection> for tools::ToolSelection {
    fn from(s: ToolSelection) -> Self {
        Self {
            groups_off: s.groups_off.into_iter().collect(),
            tools_off: s.tools_off.into_iter().collect(),
        }
    }
}

/// Whether `selection` leaves on the tool with this id in this group.
#[uniffi::export]
pub fn tool_allowed(selection: ToolSelection, id: String, group: String) -> bool {
    let entry = tools::ToolEntry::new(id.clone(), id, group);
    tools::ToolSelection::from(selection).allows(Some(&entry))
}

/// A server name as it appears in tool ids.
#[uniffi::export]
pub fn tool_server_key(name: String) -> String {
    tools::server_key(&name)
}

#[uniffi::export]
pub fn tool_own_id(group: String, tool: String) -> String {
    tools::own_id(&group, &tool)
}

#[uniffi::export]
pub fn tool_own_group_id(group: String) -> String {
    tools::own_group_id(&group)
}

#[uniffi::export]
pub fn tool_mcp_id(server: String, tool: String) -> String {
    tools::mcp_id(&server, &tool)
}

#[uniffi::export]
pub fn tool_mcp_group_id(server: String) -> String {
    tools::mcp_group_id(&server)
}

/// What a call to a switched-off tool is told.
#[uniffi::export]
pub fn tool_refusal(name: String) -> String {
    tools::refusal(&name)
}

/// A built-in tool: its id, the name the model calls it and its group id.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct ToolEntry {
    pub id: String,
    pub name: String,
    pub group: String,
}

impl From<tools::ToolEntry> for ToolEntry {
    fn from(e: tools::ToolEntry) -> Self {
        Self {
            id: e.id,
            name: e.name,
            group: e.group,
        }
    }
}

/// Every built-in tool in the order the Tools tab lists them.
#[uniffi::export]
pub fn tool_built_in() -> Vec<ToolEntry> {
    tools::built_in().into_iter().map(Into::into).collect()
}

/// The built-in tool the model calls `name`.
#[uniffi::export]
pub fn tool_built_in_named(name: String) -> Option<ToolEntry> {
    tools::built_in_named(&name).map(Into::into)
}

/// The built-in groups (`body`, `den`...) in listing order.
#[uniffi::export]
pub fn tool_group_names() -> Vec<String> {
    tools::GROUPS.iter().map(|(g, _)| g.to_string()).collect()
}

/// The group of the built-in tool the model calls `name`.
#[uniffi::export]
pub fn tool_group_of(name: String) -> Option<String> {
    tools::group_of(&name).map(str::to_string)
}

/// Whether an Imp has the group before anyone chooses.
#[uniffi::export]
pub fn tool_group_on_by_default(group: String) -> bool {
    tools::group_on_by_default(&group)
}

/// A built-in tool, as the apps dispatch on it. The variants are checked against imp-engine's list by
/// the compiler.
#[uniffi::remote(Enum)]
pub enum BuiltInTool {
    ImpPlayAnimations,
    ImpMove,
    ImpSpeak,
    ImpMakeAnimation,
    ImpShowAnimation,
    ImpRemoveAnimation,
    ImpSetTraits,
    MacStatus,
    BrowserPage,
    ImpListTriggers,
    ImpAddTrigger,
    ImpRemoveTrigger,
    ImpListTools,
    ImpAddTool,
    ImpAddKit,
    ImpExportKit,
    ImpRemoveTool,
    ImpOpenSettings,
    ImpMessage,
    ImpOpenFile,
    ComputerObserve,
    ComputerAct,
    ComputerVerify,
}

/// The name the model calls a built-in tool.
#[uniffi::export]
pub fn tool_built_in_name(tool: BuiltInTool) -> String {
    tool.name().to_string()
}

/// The built-in tool the model calls `name`.
#[uniffi::export]
pub fn tool_built_in_tool(name: String) -> Option<BuiltInTool> {
    BuiltInTool::named(&name)
}
