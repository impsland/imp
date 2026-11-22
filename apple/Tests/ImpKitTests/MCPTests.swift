import Foundation
import Testing
@testable import ImpKit
import ImpCore

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
        r = {"content": [{"type": "text", "text": "sum=%s" % (a["a"] + a["b"])}, {"type": "image", "data": "iVBORw==", "mimeType": "image/png"}], "isError": msg["params"]["name"] == "second"}
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

/// Answers the HTTP transport from a closure instead of the network, and keeps what it was sent.
final class McpStub: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest, Data) -> (Int, [String: String], Data))?
    nonisolated(unsafe) static var seen: [URLRequest] = []

    static func reset() { handler = nil; seen = [] }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        var body = request.httpBody ?? Data()
        if body.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let n = stream.read(&buffer, maxLength: buffer.count)
                if n <= 0 { break }
                body.append(buffer, count: n)
            }
        }
        Self.seen.append(request)
        let (status, headers, data) = Self.handler?(request, body) ?? (500, [:], Data())
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                                       headerFields: headers.merging(["Content-Length": String(data.count)]) { a, _ in a })!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
}

@Suite(.serialized) struct MCPTests {
    @Test func quotesShellWords() {
        #expect(StdioTransport.quote("it's") == #"'it'\''s'"#)
        #expect(StdioTransport.shellLine(command: "npx", arguments: ["-y", "a b"]) == "exec 'npx' '-y' 'a b'")
    }

    /// The transport only moves text: the headers, the statuses and the reply bodies are the core's
    /// call, so a stream, a batch and a refusal all come out of the same two functions.
    @Test func httpTransportMovesTextAndEndsItsSession() async throws {
        McpStub.reset()
        McpStub.handler = { request, body in
            let method = String(decoding: body, as: UTF8.self)
            if request.httpMethod == "DELETE" { return (200, [:], Data()) }
            if method.contains("initialize") {
                return (200, ["Content-Type": "application/json", "Mcp-Session-Id": "s-7"], Data(#"{"id":1,"result":{}}"#.utf8))
            }
            if method.contains("tools/list") {
                let sse = "event: message\r\ndata: {\"id\":2,\r\ndata: \"result\":{}}\r\n\r\ndata: {\"id\":3}\r\n\r\n"
                return (200, ["Content-Type": "text/event-stream"], Data(sse.utf8))
            }
            return (401, [:], Data("no".utf8))
        }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [McpStub.self]
        let transport = HTTPTransport(url: URL(string: "https://mcp.example.com/mcp")!,
                                      headers: ["Authorization": "Bearer x"], session: URLSession(configuration: config))
        var iterator = transport.incoming.makeAsyncIterator()
        try await transport.send(#"{"id":1,"method":"initialize"}"#)
        #expect(await iterator.next() == #"{"id":1,"result":{}}"#)
        transport.speak(protocolVersion: "2025-03-26")
        try await transport.send(#"{"id":2,"method":"tools/list"}"#)
        #expect(await iterator.next() == #"{"id":2,"result":{}}"#)
        #expect(await iterator.next() == #"{"id":3}"#)
        do {
            try await transport.send(#"{"id":4,"method":"other"}"#)
            Issue.record("a refused request did not throw")
        } catch let error as MCPError {
            #expect(error.localizedDescription.contains("401"))
        }
        await transport.close()
        let seen = McpStub.seen
        #expect(seen.map(\.httpMethod) == ["POST", "POST", "POST", "DELETE"])
        #expect(seen[0].value(forHTTPHeaderField: "Mcp-Session-Id") == nil)
        #expect(seen[0].value(forHTTPHeaderField: "Authorization") == "Bearer x")
        #expect(seen[1].value(forHTTPHeaderField: "Mcp-Session-Id") == "s-7")
        #expect(seen[1].value(forHTTPHeaderField: "MCP-Protocol-Version") == "2025-03-26")
        #expect(seen[3].value(forHTTPHeaderField: "Mcp-Session-Id") == "s-7")
        #expect(seen[3].value(forHTTPHeaderField: "Authorization") == "Bearer x")
    }

    @Test func aServerWithoutASessionGetsNoDelete() async throws {
        McpStub.reset()
        McpStub.handler = { _, _ in (200, ["Content-Type": "application/json"], Data(#"{"id":1,"result":{}}"#.utf8)) }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [McpStub.self]
        let transport = HTTPTransport(url: URL(string: "https://mcp.example.com/mcp")!, headers: [:],
                                      session: URLSession(configuration: config))
        try await transport.send(#"{"id":1,"method":"initialize"}"#)
        await transport.close()
        #expect(McpStub.seen.map(\.httpMethod) == ["POST"])
    }

    /// A server that lists the stateless revision gets no handshake: every request names the revision
    /// in its headers and its `_meta`, and a tool call names the tool.
    @Test func httpClientSpeaksStatelessWhenTheServerDoes() async throws {
        McpStub.reset()
        McpStub.handler = { request, body in
            let text = String(decoding: body, as: UTF8.self)
            let id = text.firstMatch(of: /"id"\s*:\s*(\d+)/).map { String($0.1) } ?? "0"
            let result = switch request.value(forHTTPHeaderField: "Mcp-Method") {
            case "server/discover": #"{"supportedVersions":["2026-07-28","2025-11-25"],"capabilities":{"tools":{}}}"#
            case "tools/list": #"{"tools":[{"name":"add","inputSchema":{"type":"object"}}]}"#
            case "tools/call": #"{"resultType":"complete","content":[{"type":"text","text":"5"}]}"#
            default: #"{}"#
            }
            return (200, ["Content-Type": "application/json"], Data(#"{"jsonrpc":"2.0","id":\#(id),"result":\#(result)}"#.utf8))
        }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [McpStub.self]
        let server = MCPServerConfig(name: "s", transport: .http, url: "https://mcp.example.com/mcp")
        let client = try MCPClient(config: server, auth: nil, session: URLSession(configuration: config))
        try await client.connect()
        #expect(try await client.listTools().map(\.name) == ["add"])
        #expect(try await client.callTool(name: "add", arguments: ["a": 2], workspace: FileManager.default.temporaryDirectory) == "5")
        await client.close()
        let seen = McpStub.seen
        #expect(seen.map { $0.value(forHTTPHeaderField: "Mcp-Method") } == ["server/discover", "tools/list", "tools/call"])
        #expect(seen.allSatisfy { $0.value(forHTTPHeaderField: "MCP-Protocol-Version") == "2026-07-28" })
        #expect(seen[2].value(forHTTPHeaderField: "Mcp-Name") == "add")
        #expect(seen.allSatisfy { $0.httpMethod == "POST" })
    }

    /// A server without the stateless revision refuses discovery and gets the handshake instead.
    @Test func httpClientFallsBackToTheHandshake() async throws {
        McpStub.reset()
        McpStub.handler = { request, body in
            let text = String(decoding: body, as: UTF8.self)
            let id = text.firstMatch(of: /"id"\s*:\s*(\d+)/).map { String($0.1) } ?? "0"
            let json = ["Content-Type": "application/json"]
            if text.contains("server/discover") {
                return (400, json, Data(#"{"jsonrpc":"2.0","id":\#(id),"error":{"code":-32601,"message":"Method not found"}}"#.utf8))
            }
            if text.contains("\"initialize\"") {
                return (200, json, Data(#"{"jsonrpc":"2.0","id":\#(id),"result":{"protocolVersion":"2025-11-25","capabilities":{}}}"#.utf8))
            }
            if text.contains("tools/list") {
                return (200, json, Data(#"{"jsonrpc":"2.0","id":\#(id),"result":{"tools":[]}}"#.utf8))
            }
            return (202, [:], Data())
        }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [McpStub.self]
        let server = MCPServerConfig(name: "s", transport: .http, url: "https://mcp.example.com/mcp")
        let client = try MCPClient(config: server, auth: nil, session: URLSession(configuration: config))
        try await client.connect()
        #expect(try await client.listTools().isEmpty)
        await client.close()
        let seen = McpStub.seen
        #expect(seen[0].value(forHTTPHeaderField: "Mcp-Method") == "server/discover")
        #expect(seen[1].value(forHTTPHeaderField: "MCP-Protocol-Version") == nil)
        #expect(seen.last?.value(forHTTPHeaderField: "MCP-Protocol-Version") == "2025-11-25")
        #expect(seen.last?.value(forHTTPHeaderField: "Mcp-Method") == nil)
    }

    @Test func stdioEndToEnd() async throws {
        let script = try writeFakeServer()
        let config = MCPServerConfig(name: "fake", transport: .stdio, command: "/usr/bin/python3", arguments: [script])
        let client = try MCPClient(config: config)
        try await client.connect()
        let tools = try await client.listTools()
        #expect(tools.map(\.name) == ["add", "second"])
        #expect(tools[0].inputSchema["properties"]?["a"] != nil)
        let workspace = FileManager.default.temporaryDirectory.appendingPathComponent("imp-mcp-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: workspace) }
        // The picture is saved in the workspace, and the model reads where, never the bytes.
        let out = try await client.callTool(name: "add", arguments: ["a": 2, "b": 3], workspace: workspace)
        let path = try #require(out.firstMatch(of: /\[image saved as (media\/image-[0-9a-f]{8}\.png)\. To show it, put !\[what it is\]\(\1\) in your reply\]/)?.1)
        #expect(out == "sum=5\n" + mcpMediaSaved(kind: "image", path: String(path)))
        #expect(try Data(contentsOf: workspace.appendingPathComponent(String(path))) == Data([0x89, 0x50, 0x4E, 0x47]))
        #expect(try await client.callTool(name: "second", arguments: ["a": 1, "b": 1], workspace: workspace).hasPrefix("Error: "))
        await client.close()
    }

    /// Writing to a server that's gone throws, saying why it stopped. It must not kill the process
    /// with SIGPIPE (the test runner doesn't ignore SIGPIPE the way the app does), nor just say
    /// "Broken pipe".
    @Test func writingToAServerThatExitedSaysWhy() async throws {
        let transport = StdioTransport(command: "imp-no-such-command-\(UUID().uuidString.prefix(8))", arguments: [], environment: [:])
        try await transport.start()
        for await _ in transport.incoming {}                  // ends once the server has exited
        let big = String(repeating: "x", count: 200_000)   // more than a pipe holds
        do {
            for _ in 0..<5 { try await transport.send(#"{"jsonrpc":"2.0","method":"ping","params":{"pad":"\#(big)"}}"#) }
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
        #expect(try await hub.call("my_srv__add", arguments: #"{"a":1,"b":1}"#, workspace: FileManager.default.temporaryDirectory).hasPrefix("sum=2"))
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

extension MCPTests {
    /// The core names the tools: servers in name order, two tools with one name numbered.
    @Test func hubNumbersToolsThatShareAName() async throws {
        let script = try writeFakeServer()
        let a = MCPServerConfig(name: "a b", transport: .stdio, command: "/usr/bin/python3", arguments: [script])
        let b = MCPServerConfig(name: "a_b", transport: .stdio, command: "/usr/bin/python3", arguments: [script])
        let hub = MCPHub()
        await hub.update([a, b])
        let catalog = await hub.catalog()
        #expect(catalog.map(\.spec.name) == ["a_b__add", "a_b__second", "a_b__add_2", "a_b__second_2"])
        #expect(catalog.compactMap(\.entry?.id) == ["mcp.a_b.add", "mcp.a_b.second", "mcp.a_b.add", "mcp.a_b.second"])
        #expect(catalog.compactMap(\.entry?.group) == Array(repeating: "mcp.a_b", count: 4))
        await hub.update([])
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
