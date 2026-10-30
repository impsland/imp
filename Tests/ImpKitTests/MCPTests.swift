import Foundation
import Testing
@testable import ImpKit

private let fakeServer = #"""
import sys, json
for line in sys.stdin:
    try: msg = json.loads(line)
    except Exception: continue
    m, i = msg.get("method"), msg.get("id")
    if i is None: continue
    if m == "initialize":
        r = {"protocolVersion": "2025-06-18", "capabilities": {"tools": {}}, "serverInfo": {"name": "fake", "version": "1"}}
    elif m == "tools/list":
        if msg["params"].get("cursor") == "p2":
            r = {"tools": [{"name": "second", "description": "two", "inputSchema": {"type": "object"}}]}
        else:
            r = {"tools": [{"name": "add", "description": "Adds", "inputSchema": {"type": "object", "properties": {"a": {"type": "number"}}}}], "nextCursor": "p2"}
    elif m == "tools/call":
        a = msg["params"]["arguments"]
        r = {"content": [{"type": "text", "text": "sum=%s" % (a["a"] + a["b"])}, {"type": "image", "data": "x", "mimeType": "image/png"}], "isError": msg["params"]["name"] == "second"}
    else:
        sys.stdout.write(json.dumps({"jsonrpc": "2.0", "id": i, "error": {"code": -32601, "message": "nope"}}) + "\n"); sys.stdout.flush(); continue
    sys.stdout.write(json.dumps({"jsonrpc": "2.0", "id": i, "result": r}) + "\n"); sys.stdout.flush()
"""#

/// Lists one tool, then exits with a word on stderr.
private let exitingServer = #"""
import sys, json
for line in sys.stdin:
    msg = json.loads(line); m, i = msg.get("method"), msg.get("id")
    if i is None: continue
    if m == "initialize":
        r = {"protocolVersion": "2025-06-18", "capabilities": {"tools": {}}, "serverInfo": {"name": "x", "version": "1"}}
    else:
        r = {"tools": [{"name": "t", "description": "", "inputSchema": {"type": "object"}}]}
    sys.stdout.write(json.dumps({"jsonrpc": "2.0", "id": i, "result": r}) + "\n"); sys.stdout.flush()
    if m == "tools/list": sys.stderr.write("out of coffee\n"); sys.exit(3)
"""#

private func writeFakeServer(_ source: String = fakeServer) throws -> String {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("imp-mcp-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let path = dir.appendingPathComponent("server.py")
    try source.write(to: path, atomically: true, encoding: .utf8)
    return path.path
}

struct MCPTests {
    @Test func sanitizesAndMapsNames() {
        #expect(MCPHub.sanitize("my server.v2") == "my_server_v2")
        #expect(MCPHub.sanitize("") == "_")
        #expect(MCPHub.exposedName(server: "git hub", tool: "list/issues") == "git_hub__list_issues")
        let long = MCPHub.exposedName(server: String(repeating: "a", count: 50), tool: String(repeating: "b", count: 50))
        #expect(long.count == 64)
    }

    @Test func quotesShellWords() {
        #expect(StdioTransport.quote("it's") == #"'it'\''s'"#)
        #expect(StdioTransport.shellLine(command: "npx", arguments: ["-y", "a b"]) == "exec 'npx' '-y' 'a b'")
    }

    @Test func parsesSSE() {
        let text = "event: message\ndata: {\"id\":1,\r\ndata: \"result\":{}}\n\n: comment\ndata: {\"id\":2}\n\n"
        let msgs = HTTPTransport.parseSSE(text)
        #expect(msgs.count == 2)
        #expect(msgs[0]["id"]?.int == 1)
        #expect(msgs[1]["id"]?.int == 2)
        let json = HTTPTransport.messages(in: Data(#"[{"id":3}]"#.utf8), contentType: "application/json")
        #expect(json.count == 1)
    }

    @Test func flattensToolResults() throws {
        let r = try JSONValue(jsonString: #"{"content":[{"type":"text","text":"a"},{"type":"image"}],"isError":true}"#)
        #expect(MCPClient.toolResultText(from: r) == "Error: a\n[image]")
    }

    @Test func stdioEndToEnd() async throws {
        let script = try writeFakeServer()
        let config = MCPServerConfig(name: "fake", transport: .stdio, command: "/usr/bin/python3", arguments: [script])
        let client = try MCPClient(config: config)
        try await client.connect()
        let tools = try await client.listTools()
        #expect(tools.map(\.name) == ["add", "second"])
        #expect(tools[0].inputSchema["properties"]?["a"] != nil)
        let out = try await client.callTool(name: "add", arguments: ["a": 2, "b": 3])
        #expect(out == "sum=5\n[image]")
        #expect(try await client.callTool(name: "second", arguments: ["a": 1, "b": 1]).hasPrefix("Error: "))
        await client.close()
    }

    /// Writing to a server that's gone throws, saying why it stopped. It must not kill the process
    /// with SIGPIPE (the test runner doesn't ignore SIGPIPE the way the app does), nor just say
    /// "Broken pipe".
    @Test func writingToAServerThatExitedSaysWhy() async throws {
        let transport = StdioTransport(command: "imp-no-such-command-\(UUID().uuidString.prefix(8))", arguments: [], environment: [:])
        try await transport.start()
        for await _ in transport.incoming {}                  // ends once the server has exited
        let big = JSONValue.string(String(repeating: "x", count: 200_000))   // more than a pipe holds
        do {
            for _ in 0..<5 { try await transport.send(["jsonrpc": "2.0", "method": "ping", "params": ["pad": big]]) }
            Issue.record("wrote to a server that had exited")
        } catch let error as MCPError {
            #expect(error.localizedDescription.contains("not found"))
        }
        await transport.close()
    }

    @Test func aServerThatExitsStopsOfferingItsTools() async throws {
        let config = MCPServerConfig(name: "x", transport: .stdio, command: "/usr/bin/python3",
                                     arguments: [try writeFakeServer(exitingServer)])
        let hub = MCPHub()
        await hub.update([config])
        for _ in 0..<50 {
            if case .failed = await hub.status[config.id] { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        guard case .failed(let why) = await hub.status[config.id] else { Issue.record("still ready"); return }
        #expect(why.contains("out of coffee"))
        #expect(await hub.tools().isEmpty)
    }

    @Test func hubConnectsAndRoutesCalls() async throws {
        let script = try writeFakeServer()
        let config = MCPServerConfig(name: "my srv", transport: .stdio, command: "/usr/bin/python3", arguments: [script])
        let hub = MCPHub()
        await hub.update([config])
        let tools = await hub.tools()
        #expect(tools.map(\.name) == ["my_srv__add", "my_srv__second"])
        #expect(try await hub.call("my_srv__add", arguments: #"{"a":1,"b":1}"#).hasPrefix("sum=2"))
        guard case .ready(let count, _) = await hub.status[config.id] else { Issue.record("not ready"); return }
        #expect(count == 2)
        var disabled = config; disabled.isEnabled = false
        await hub.update([disabled])
        #expect(await hub.status[config.id] == nil)
        #expect(await hub.tools().isEmpty)
        let tested = await hub.test(config)
        #expect(tested == .ready(toolCount: 2, toolNames: ["add", "second"]))
        let bad = MCPServerConfig(name: "bad", transport: .stdio, command: "/nonexistent-cmd-xyz")
        if case .failed = await hub.test(bad) {} else { Issue.record("expected failure") }
    }
}

@Suite struct CommandLineTests {
    @Test func splitsQuotedWords() {
        var c = MCPServerConfig(name: "fs", transport: .stdio)
        c.commandLine = #"npx -y "@scope/server fs" '/Users/me/My Docs' a\ b"#
        #expect(c.command == "npx")
        #expect(c.arguments == ["-y", "@scope/server fs", "/Users/me/My Docs", "a b"])
    }

    @Test func roundTrips() {
        var c = MCPServerConfig(name: "x", transport: .stdio, command: "uvx", arguments: ["mcp-server-fetch", "it's here"])
        let line = c.commandLine
        c.commandLine = line
        #expect(c.command == "uvx" && c.arguments == ["mcp-server-fetch", "it's here"])
    }
}
