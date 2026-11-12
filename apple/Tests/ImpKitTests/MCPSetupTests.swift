import Foundation
import Testing
@testable import ImpKit

@Suite struct MCPSetupTests {
    @Test func readsAClaudeStyleConfig() throws {
        let json = #"""
        {"mcpServers": {
          "github": {"command": "npx", "args": ["-y", "@modelcontextprotocol/server-github"], "env": {"GITHUB_TOKEN": "t"}},
          "remote": {"type": "http", "url": "https://mcp.example.com/mcp", "headers": {"Authorization": "Bearer x"}}
        }}
        """#
        let servers = MCPServerConfig.parse(setup: json)
        #expect(servers.map(\.name) == ["github", "remote"])
        #expect(servers[0].transport == .stdio && servers[0].command == "npx")
        #expect(servers[0].arguments == ["-y", "@modelcontextprotocol/server-github"] && servers[0].environment == ["GITHUB_TOKEN": "t"])
        #expect(servers[1].transport == .http && servers[1].url == "https://mcp.example.com/mcp")
        #expect(servers[1].headers == ["Authorization": "Bearer x"])
    }

    @Test func keepsNumbersAndEmptyArguments() {
        let s = MCPServerConfig.parse(setup: #"{"command": "srv", "args": ["--port", 8080, "--name", "", "-v"]}"#)
        #expect(s.first?.arguments == ["--port", "8080", "--name", "", "-v"])
        var copy = s[0]
        copy.commandLine = s[0].commandLine
        #expect(copy.arguments == s[0].arguments)
        #expect(MCPServerConfig(name: "", transport: .stdio).commandLine == "")
    }

    @Test func readsSnippetsAndBareServers() {
        let pair = MCPServerConfig.parse(setup: #""memory": {"command": "npx", "args": ["-y", "@modelcontextprotocol/server-memory"]},"#)
        #expect(pair.map(\.name) == ["memory"])
        let bare = MCPServerConfig.parse(setup: #"{"command": "uvx mcp-server-fetch"}"#)
        #expect(bare.first?.name == "Fetch" && bare.first?.command == "uvx" && bare.first?.arguments == ["mcp-server-fetch"])
        #expect(MCPServerConfig.parse(setup: #"{"servers": {"x": {"url": "https://x.dev/mcp"}}}"#).first?.transport == .http)
    }

    @Test func readsCommandsAndAddresses() {
        let cmd = MCPServerConfig.parse(setup: "$ npx -y @modelcontextprotocol/server-filesystem ~/Documents\n")
        #expect(cmd.first?.name == "Filesystem" && cmd.first?.arguments.last == "~/Documents")
        #expect(MCPServerConfig.parse(setup: "docker run -i --rm mcp/fetch").first?.name == "Fetch")
        let web = MCPServerConfig.parse(setup: "https://mcp.linear.app/mcp")
        #expect(web.first?.transport == .http && web.first?.name == "Linear")
    }

    @Test func ignoresJunk() {
        #expect(MCPServerConfig.parse(setup: "  ").isEmpty)
        #expect(MCPServerConfig.parse(setup: "{not json").isEmpty)
        #expect(MCPServerConfig.parse(setup: #"{"name": "nothing runnable"}"#).isEmpty)
    }
}
