import Foundation

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
        return !groupsOff.contains(entry.group) && !toolsOff.contains(entry.id)
    }
}

/// The one list of tools with ids, groups and an on/off state. The filter here is the only place a
/// selection is applied (`ToolSet`), on the Mac and on the iPhone alike.
public enum ToolRegistry {
    public static func ownGroupID(_ group: ImpToolGroup) -> String { "own.\(group.rawValue)" }

    public static func ownID(_ group: ImpToolGroup, tool: String) -> String { "own.\(group.rawValue).\(tool)" }

    /// A server name as it appears in ids.
    public static func serverKey(_ name: String) -> String { MCPHub.sanitize(name) }

    public static func mcpGroupID(server name: String) -> String { "mcp.\(serverKey(name))" }

    public static func mcpID(server name: String, tool: String) -> String { "mcp.\(serverKey(name)).\(tool)" }

    /// Every built-in tool, in the order the Tools tab lists them.
    public static let builtIn: [ToolEntry] = {
        let rows: [(ImpToolGroup, String, String)] = [
            (.body, OwnTools.play, String(localized: "Play animations")),
            (.body, OwnTools.move, String(localized: "Move around the screen")),
            (.body, OwnTools.speak, String(localized: "Speak out loud")),
            (.body, OwnTools.makeAnimation, String(localized: "Make an animation")),
            (.body, OwnTools.showAnimation, String(localized: "Look at an animation")),
            (.body, OwnTools.removeAnimation, String(localized: "Remove an animation")),
            (.body, OwnTools.setTraits, String(localized: "Change its character")),
            (.senses, OwnTools.status, String(localized: "Read the Mac's state")),
            (.senses, OwnTools.page, String(localized: "Read the browser page")),
            (.setup, OwnTools.listTriggers, String(localized: "List its triggers")),
            (.setup, OwnTools.addTrigger, String(localized: "Add a trigger")),
            (.setup, OwnTools.removeTrigger, String(localized: "Remove a trigger")),
            (.setup, OwnTools.listTools, String(localized: "List extra tools")),
            (.setup, OwnTools.addTool, String(localized: "Add an extra tool")),
            (.setup, OwnTools.removeTool, String(localized: "Remove an extra tool")),
            (.setup, OwnTools.openSettings, String(localized: "Open Settings")),
            (.troupe, OwnTools.message, String(localized: "Message another Imp")),
            (.computer, ComputerTools.observe, String(localized: "Look at the screen")),
            (.computer, ComputerTools.act, String(localized: "Click, type and scroll")),
            (.computer, ComputerTools.verify, String(localized: "Check what happened")),
            (.den, OwnTools.denSearch, String(localized: "Search the Den")),
            (.den, OwnTools.denGet, String(localized: "Look at something in the Den")),
            (.den, OwnTools.denAdd, String(localized: "Take something from the Den")),
            (.den, OwnTools.denShare, String(localized: "Share in the Den")),
            (.den, OwnTools.denUnshare, String(localized: "Take back from the Den")),
            (.den, OwnTools.denAccount, String(localized: "Use its Den account")),
        ]
        return rows.map { ToolEntry(id: ownID($0.0, tool: $0.1), name: $0.1, group: ownGroupID($0.0), title: $0.2) }
    }()

    private static let byName = Dictionary(builtIn.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })

    /// The built-in tool the model calls `name`.
    public static func entry(named name: String) -> ToolEntry? { byName[name] }

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
        "The tool \(name) is switched off, so it can't be used. Do it another way, or tell the user it can be switched on in Settings."
    }
}
