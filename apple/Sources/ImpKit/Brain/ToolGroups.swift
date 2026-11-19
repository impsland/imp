import Foundation

/// One group in the Tools list: a built-in group (`own.personality`) or an MCP server (`mcp.files`), with
/// its tools and how many of them an Imp may use. The count is what the registry's own filter
/// leaves on, so a tool that is off is never counted and never offered.
public struct ToolGroupState: Identifiable, Equatable, Sendable {
    public enum Source: Equatable, Sendable {
        case own(ImpToolGroup)
        case server(UUID)
    }

    public var id: String
    public var source: Source
    public var tools: [ToolEntry]
    /// The whole group is switched on for the Imp.
    public var isOn: Bool
    /// How many of its tools the Imp may use right now.
    public var on: Int
    public var total: Int { tools.count }
}

public enum ToolGroups {
    /// The built-in groups from the core registry, in its order. Empty groups are left out.
    public static func own(for imp: ImpProfile) -> [ToolGroupState] {
        let selection = imp.toolSelection
        return ImpToolGroup.allCases.compactMap { group in
            let tools = ToolRegistry.tools(in: group)
            guard !tools.isEmpty else { return nil }
            return ToolGroupState(id: ToolRegistry.ownGroupID(group), source: .own(group), tools: tools,
                                  isOn: imp.uses(group), on: ToolRegistry.filter(tools, selection).count)
        }
    }

    /// One group for each MCP server. `tools` holds the names a started server reported.
    public static func mcp(for imp: ImpProfile, servers: [MCPServerConfig], tools: [UUID: [String]]) -> [ToolGroupState] {
        let selection = imp.toolSelection
        return servers.map { server in
            let group = ToolRegistry.mcpGroupID(server: server.name)
            let entries = (tools[server.id] ?? []).map {
                ToolEntry(id: ToolRegistry.mcpID(server: server.name, tool: $0), name: $0, group: group, title: $0)
            }
            let isOn = imp.servers.contains(server.id)
            return ToolGroupState(id: group, source: .server(server.id), tools: entries, isOn: isOn,
                                  on: isOn ? ToolRegistry.filter(entries, selection).count : 0)
        }
    }

    /// Tools on and tools in all, for the marker's "n of m on".
    public static func summary(_ groups: [ToolGroupState]) -> (on: Int, total: Int) {
        (groups.reduce(0) { $0 + $1.on }, groups.reduce(0) { $0 + $1.total })
    }
}
