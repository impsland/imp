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

    /// The tools the selection leaves on, with what the person wrote over their names and descriptions: the ones
    /// the model is offered. A written name that is not allowed (`ToolText.isValid`) or that another offered tool has
    /// is ignored. The entry keeps the tool's own name (`entry.name`); `spec.name` is the one the model uses.
    private func offered(_ all: [(member: ToolProvider, tool: CatalogTool)]) -> [(member: ToolProvider, tool: CatalogTool, real: String)] {
        let on = all.filter { selection.allows($0.tool.entry) }
        var taken = Set(on.map(\.tool.spec.name))
        return on.map { item in
            var tool = item.tool
            let real = tool.spec.name
            if let id = tool.entry?.id, let text = selection.text[id] {
                if let name = text.name, name != real, ToolText.isValid(name: name), !taken.contains(name) {
                    taken.remove(real); taken.insert(name)
                    tool.spec.name = name
                }
                if let description = text.description { tool.spec.description = ToolText.expand(description, tool.fills) }
            }
            return (item.member, tool, real)
        }
    }

    public func catalog() async -> [CatalogTool] { offered(await everything()).map(\.tool) }

    public func tools() async -> [ToolSpec] { await catalog().map(\.spec) }

    /// The tools the selection leaves on, as the screen that edits their text lists them.
    public func textRows() async -> [ToolTextRow] {
        rows(await everything().filter { selection.allows($0.tool.entry) })
    }

    /// Every tool the members have, switched on or off: what the screen that edits their text lists, so a tool that is
    /// off for now can still be written about.
    public func allTextRows() async -> [ToolTextRow] { rows(await everything()) }

    private func rows(_ items: [(member: ToolProvider, tool: CatalogTool)]) -> [ToolTextRow] {
        items.compactMap { item in
            guard let entry = item.tool.entry else { return nil }
            return ToolTextRow(id: entry.id, defaultName: item.tool.spec.name,
                               defaultDescription: ToolText.template(item.tool.spec.description, item.tool.fills),
                               text: selection.text[entry.id], placeholders: item.tool.fills.keys.sorted())
        }
    }

    public func call(_ name: String, arguments: String) async throws -> String {
        try await run(name, arguments: arguments).text
    }

    /// `name` is what the model called the tool: a renamed tool runs under its own name.
    public func run(_ name: String, arguments: String) async throws -> ToolOutput {
        let all = await everything()
        guard let found = offered(all).first(where: { $0.tool.spec.name == name }) else {
            // A tool that exists but is switched off gets its own message.
            if all.contains(where: { $0.tool.spec.name == name && !selection.allows($0.tool.entry) }) {
                throw MCPError.badConfig(ToolRegistry.refusal(for: name))
            }
            throw MCPError.badConfig("Unknown tool \(name).")
        }
        return try await found.member.run(found.real, arguments: arguments)
    }

    /// OpenAI function names allow `[a-zA-Z0-9_-]{1,64}`.
    public static func functionName(_ s: String) -> String {
        String(MCPHub.sanitize(s).prefix(64))
    }
}
