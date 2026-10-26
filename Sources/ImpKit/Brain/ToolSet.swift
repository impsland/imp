import Foundation

/// Several tool services offered to the model as one (e.g. the shell + MCP servers).
public struct ToolSet: ToolProvider {
    public var members: [ToolProvider]

    public init(_ members: [ToolProvider]) { self.members = members }

    public func tools() async -> [ToolSpec] {
        var all: [ToolSpec] = []
        for m in members { all += await m.tools() }
        return all
    }

    public func call(_ name: String, arguments: String) async throws -> String {
        for m in members where await m.tools().contains(where: { $0.name == name }) {
            return try await m.call(name, arguments: arguments)
        }
        throw MCPError.badConfig("Unknown tool \(name).")
    }

    /// OpenAI function names allow `[a-zA-Z0-9_-]{1,64}`.
    public static func functionName(_ s: String) -> String {
        String(MCPHub.sanitize(s).prefix(64))
    }
}
