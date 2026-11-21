import Foundation
import ImpCore

/// One tool as the registry knows it: a stable id, the name the model calls it by, and its group.
///
/// Ids: `own.<group>.<tool>` for the built-in tools (for instance `own.personality.imp_message`) and
/// `mcp.<server>.<tool>` for tools of an MCP server (`<server>` is its name with anything outside
/// letters, digits, `_` and `-` turned into `_`). A group is the id without the last part:
/// `own.personality`, `mcp.files`. The ids are what saved choices and Den packages refer to.
public struct ToolEntry: Hashable, Sendable, Identifiable, Codable {
    public var id: String
    /// What the model calls it (the function name it is offered under).
    public var name: String
    /// The group's id (`own.personality`, `mcp.files`).
    public var group: String
    /// A few plain words for the Tools tab. Empty for tools of a server (they show their own name).
    public var title: String

    public init(id: String, name: String, group: String, title: String = "") {
        self.id = id; self.name = name; self.group = group; self.title = title
    }
}

/// A tool as offered: its registry entry (nil for tools that aren't switchable, like the shell) and its schema.
public struct CatalogTool: Sendable {
    public var entry: ToolEntry?
    public var spec: ToolSpec
    /// What the changing parts of its description are right now (`{imps}`…): a description a person wrote may use them.
    public var fills: [String: String]

    public init(entry: ToolEntry?, spec: ToolSpec, fills: [String: String] = [:]) { self.entry = entry; self.spec = spec; self.fills = fills }
}

/// What is switched off: whole groups and single tools, by id. Everything else is on.
public struct ToolSelection: Codable, Hashable, Sendable {
    public var groupsOff: Set<String>
    public var toolsOff: Set<String>
    /// What was written over single tools' names and descriptions, by id (`ToolSet` applies it).
    public var text: [String: ToolText]

    public init(groupsOff: Set<String> = [], toolsOff: Set<String> = [], text: [String: ToolText] = [:]) {
        self.groupsOff = groupsOff; self.toolsOff = toolsOff; self.text = text
    }

    private enum CodingKeys: String, CodingKey { case groupsOff, toolsOff, text }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        groupsOff = try c.decodeIfPresent(Set<String>.self, forKey: .groupsOff) ?? []
        toolsOff = try c.decodeIfPresent(Set<String>.self, forKey: .toolsOff) ?? []
        text = try c.decodeIfPresent([String: ToolText].self, forKey: .text) ?? [:]
    }

    /// Everything on.
    public static let all = ToolSelection()

    /// A tool without an entry can't be switched, so it's allowed.
    public func allows(_ entry: ToolEntry?) -> Bool {
        guard let entry else { return true }
        return ImpCore.toolAllowed(selection: ImpCore.ToolSelection(groupsOff: Array(groupsOff), toolsOff: Array(toolsOff)),
                                   id: entry.id, group: entry.group)
    }
}

/// The one list of tools with ids, groups and an on/off state. The filter here is the only place a
/// selection is applied (`ToolSet`), on the Mac and on the iPhone alike.
public enum ToolRegistry {
    public static func ownGroupID(_ group: ImpToolGroup) -> String { ImpCore.toolOwnGroupId(group: group.rawValue) }

    public static func ownID(_ group: ImpToolGroup, tool: String) -> String { ImpCore.toolOwnId(group: group.rawValue, tool: tool) }

    public static func mcpGroupID(server name: String) -> String { ImpCore.toolMcpGroupId(server: name) }

    public static func mcpID(server name: String, tool: String) -> String { ImpCore.toolMcpId(server: name, tool: tool) }

    /// The words a section's agent sheet shows for each built-in tool (short: the section says what they act on),
    /// by the name the model calls it. The ids, groups and order come from the core.
    private static let titles: [String: String] = [
        OwnTools.play: String(localized: "tool.play"),
        OwnTools.move: String(localized: "tool.move"),
        OwnTools.createImp: String(localized: "tool.create_imp"),
        OwnTools.makeAnimation: String(localized: "tool.make_animation"),
        OwnTools.showAnimation: String(localized: "tool.show_animation"),
        OwnTools.removeAnimation: String(localized: "tool.remove_animation"),
        OwnTools.setTraits: String(localized: "tool.set_traits"),
        OwnTools.showBackground: String(localized: "tool.show_background"),
        OwnTools.setBackground: String(localized: "tool.set_background"),
        OwnTools.status: String(localized: "tool.mac_status"),
        OwnTools.page: String(localized: "tool.browser_page"),
        OwnTools.listTriggers: String(localized: "tool.list_triggers"),
        OwnTools.addTrigger: String(localized: "tool.add_trigger"),
        OwnTools.removeTrigger: String(localized: "tool.remove_trigger"),
        OwnTools.listTools: String(localized: "tool.list_tools"),
        OwnTools.addTool: String(localized: "tool.add_tool"),
        OwnTools.addKit: String(localized: "tool.add_kit"),
        OwnTools.exportKit: String(localized: "tool.export_kit"),
        OwnTools.removeTool: String(localized: "tool.remove_tool"),
        OwnTools.openSettings: String(localized: "tool.open_settings"),
        OwnTools.message: String(localized: "tool.message"),
        OwnTools.openFile: String(localized: "tool.open_file"),
        ComputerTools.observe: String(localized: "tool.observe"),
        ComputerTools.act: String(localized: "tool.act"),
        ComputerTools.verify: String(localized: "tool.verify"),
    ]

    private static func entry(_ e: ImpCore.ToolEntry) -> ToolEntry {
        ToolEntry(id: e.id, name: e.name, group: e.group, title: titles[e.name] ?? "")
    }

    /// Every built-in tool, in the order the Tools tab lists them.
    public static let builtIn: [ToolEntry] = ImpCore.toolBuiltIn().map(entry)

    /// The built-in tool the model calls `name`.
    public static func entry(named name: String) -> ToolEntry? { ImpCore.toolBuiltInNamed(name: name).map(entry) }

    /// The built-in tools of one group.
    public static func tools(in group: ImpToolGroup) -> [ToolEntry] { builtIn.filter { $0.group == ownGroupID(group) } }

    /// The tools `selection` leaves on. The one filter every client applies before offering tools.
    public static func filter(_ tools: [CatalogTool], _ selection: ToolSelection) -> [CatalogTool] {
        tools.filter { selection.allows($0.entry) }
    }

    /// The entries `selection` leaves on.
    public static func filter(_ entries: [ToolEntry], _ selection: ToolSelection) -> [ToolEntry] {
        entries.filter { selection.allows($0) }
    }

    /// What a call to a switched-off tool is told.
    public static func refusal(for name: String) -> String {
        ImpCore.toolRefusal(name: name)
    }
}
