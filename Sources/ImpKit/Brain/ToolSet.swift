import Foundation

/// Several tool services offered to the model as one (e.g. the shell + MCP servers).
/// This is where a `ToolSelection` is applied: what is switched off is neither offered nor run.
public struct ToolSet: ToolProvider {
    public var members: [ToolProvider]
    public var selection: ToolSelection

    public init(_ members: [ToolProvider], selection: ToolSelection = .all) {
        self.members = members; self.selection = selection
    }

    /// Every tool the members have, switched on or off.
    private func everything() async -> [(member: ToolProvider, tool: CatalogTool)] {
        var all: [(ToolProvider, CatalogTool)] = []
        for m in members { all += await m.catalog().map { (m, $0) } }
        return all
    }

    public func catalog() async -> [CatalogTool] {
        ToolRegistry.filter(await everything().map(\.tool), selection)
    }

    public func tools() async -> [ToolSpec] { await catalog().map(\.spec) }

    public func call(_ name: String, arguments: String) async throws -> String {
        try await run(name, arguments: arguments).text
    }

    public func run(_ name: String, arguments: String) async throws -> ToolOutput {
        let all = await everything()
        guard let found = all.first(where: { $0.tool.spec.name == name && selection.allows($0.tool.entry) }) else {
            // A tool that exists but is switched off gets its own message.
            if all.contains(where: { $0.tool.spec.name == name }) { throw MCPError.badConfig(ToolRegistry.refusal(for: name)) }
            throw MCPError.badConfig("Unknown tool \(name).")
        }
        return try await found.member.run(name, arguments: arguments)
    }

    /// OpenAI function names allow `[a-zA-Z0-9_-]{1,64}`.
    public static func functionName(_ s: String) -> String {
        String(MCPHub.sanitize(s).prefix(64))
    }
}
