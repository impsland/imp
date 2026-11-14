import Foundation
import ImpCore

/// One tool as the registry knows it: a stable id, the name the model calls it by, and its group.
///
/// Ids: `own.<group>.<tool>` for the built-in tools (for instance `own.body.imp_speak`) and
/// `mcp.<server>.<tool>` for tools of an MCP server (`<server>` is its name with anything outside
/// letters, digits, `_` and `-` turned into `_`). A group is the id without the last part:
/// `own.body`, `mcp.files`. The ids are what saved choices and Den packages refer to.
public struct ToolEntry: Hashable, Sendable, Identifiable, Codable {
    public var id: String
    /// What the model calls it (the function name it is offered under).
    public var name: String
    /// The group's id (`own.body`, `mcp.files`).
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

    public init(entry: ToolEntry?, spec: ToolSpec) { self.entry = entry; self.spec = spec }
}

/// What is switched off: whole groups and single tools, by id. Everything else is on.
public struct ToolSelection: Codable, Hashable, Sendable {
    public var groupsOff: Set<String>
    public var toolsOff: Set<String>

    public init(groupsOff: Set<String> = [], toolsOff: Set<String> = []) {
        self.groupsOff = groupsOff; self.toolsOff = toolsOff
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

    /// The words the Tools tab shows for each built-in tool, by the name the model calls it. The ids,
    /// groups and order come from the core.
    private static let titles: [String: String] = [
        OwnTools.play: String(localized: "Play animations"),
        OwnTools.move: String(localized: "Move around the screen"),
        OwnTools.speak: String(localized: "Speak out loud"),
        OwnTools.makeAnimation: String(localized: "Make an animation"),
        OwnTools.showAnimation: String(localized: "Look at an animation"),
        OwnTools.removeAnimation: String(localized: "Remove an animation"),
        OwnTools.setTraits: String(localized: "Change its character"),
        OwnTools.status: String(localized: "Read the Mac's state"),
        OwnTools.page: String(localized: "Read the browser page"),
        OwnTools.listTriggers: String(localized: "List its triggers"),
        OwnTools.addTrigger: String(localized: "Add a trigger"),
        OwnTools.removeTrigger: String(localized: "Remove a trigger"),
        OwnTools.listTools: String(localized: "List extra tools"),
        OwnTools.addTool: String(localized: "Add an extra tool"),
        OwnTools.removeTool: String(localized: "Remove an extra tool"),
        OwnTools.openSettings: String(localized: "Open Settings"),
        OwnTools.message: String(localized: "Message another Imp"),
        OwnTools.openFile: String(localized: "Open a shared file"),
        ComputerTools.observe: String(localized: "Look at the screen"),
        ComputerTools.act: String(localized: "Click, type and scroll"),
        ComputerTools.verify: String(localized: "Check what happened"),
        OwnTools.denSearch: String(localized: "Search the Den"),
        OwnTools.denGet: String(localized: "Look at something in the Den"),
        OwnTools.denAdd: String(localized: "Take something from the Den"),
        OwnTools.denShare: String(localized: "Share in the Den"),
        OwnTools.denUnshare: String(localized: "Take back from the Den"),
        OwnTools.denAccount: String(localized: "Use its Den account"),
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
