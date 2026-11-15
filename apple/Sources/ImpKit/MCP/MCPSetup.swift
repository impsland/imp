import Foundation
import ImpCore

extension MCPServerConfig {
    /// Servers from whatever an MCP server's page tells you to copy:
    /// - a JSON config: `{"mcpServers": {"name": {...}}}` (also `"servers"`), a map of named servers,
    ///   or one server object (`command`/`args`/`env`, or `url`/`headers`),
    /// - a web address (`https://…`), for a remote server,
    /// - a command line (`npx -y @scope/server-memory`), for a local one.
    /// Empty when the text is none of these. The core reads it (`mcp::setup`, the vectors in
    /// `spec/fixtures/mcp-setup.json`), as the command line app does.
    public static func parse(setup text: String) -> [MCPServerConfig] {
        ImpCore.mcpParseSetup(text: text).map { found in
            let name = found.name.isEmpty ? newToolName : found.name
            return found.url.isEmpty
                ? MCPServerConfig(name: name, transport: .stdio, command: found.command, arguments: found.args,
                                  environment: found.env)
                : MCPServerConfig(name: name, transport: .http, url: found.url, headers: found.headers)
        }
    }

    /// "Memory" for `npx -y @modelcontextprotocol/server-memory`, "Fetch" for `uvx mcp-server-fetch`.
    static func suggestedName(commandLine words: [String]) -> String {
        let name = ImpCore.mcpSuggestedNameForCommand(words: words)
        return name.isEmpty ? newToolName : name
    }

    /// "Example" for `https://mcp.example.com/mcp`.
    static func suggestedName(url: String) -> String {
        let name = ImpCore.mcpSuggestedNameForUrl(url: url)
        return name.isEmpty ? newToolName : name
    }

    /// The name of a server nothing suggested a name for.
    private static var newToolName: String { String(localized: "New tool") }
}
