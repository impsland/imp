import Foundation

/// Minimal MCP client (spec 2025-06-18) over any transport.
public actor MCPClient {
    public static let protocolVersion = "2025-06-18"

    private let transport: any MCPTransport
    private var nextID = 0
    private var pending: [Int: (cont: CheckedContinuation<JSONValue, Error>, timer: Task<Void, Never>)] = [:]
    private var reader: Task<Void, Never>?

    public init(config: MCPServerConfig) throws { transport = try makeTransport(for: config) }
    init(transport: any MCPTransport) { self.transport = transport }

    /// Starts the transport and performs the initialize handshake.
    public func connect() async throws {
        try await transport.start()
        reader = Task { [transport] in
            for await message in transport.incoming { await self.handle(message) }
            self.transportEnded()
        }
        let result = try await request("initialize", [
            "protocolVersion": .string(Self.protocolVersion),
            "capabilities": .object([:]),
            "clientInfo": ["name": "Imp", "version": "1.0"],
        ], timeout: 30)
        transport.initialized(protocolVersion: result["protocolVersion"]?.string ?? Self.protocolVersion)
        try await transport.send(["jsonrpc": "2.0", "method": "notifications/initialized"])
    }

    /// All tools, following pagination.
    public func listTools() async throws -> [ToolSpec] {
        var tools: [ToolSpec] = []
        var cursor: String?
        repeat {
            let params: JSONValue = cursor.map { ["cursor": .string($0)] } ?? [:]
            let result = try await request("tools/list", params, timeout: 30)
            for t in result["tools"]?.array ?? [] {
                guard let name = t["name"]?.string else { continue }
                tools.append(ToolSpec(name: name, description: t["description"]?.string ?? "",
                                      inputSchema: t["inputSchema"] ?? ["type": "object"]))
            }
            cursor = result["nextCursor"]?.string
        } while cursor != nil
        return tools
    }

    /// Calls a tool and flattens its content to text.
    public func callTool(name: String, arguments: JSONValue) async throws -> String {
        let result = try await request("tools/call", ["name": .string(name), "arguments": arguments], timeout: 120)
        return Self.toolResultText(from: result)
    }

    public func close() async {
        reader?.cancel()
        await transport.close()
        failAll(MCPError.closed)
    }

    static func toolResultText(from result: JSONValue) -> String {
        let parts = (result["content"]?.array ?? []).map { item -> String in
            let type = item["type"]?.string ?? "unknown"
            switch type {
            case "text": return item["text"]?.string ?? ""
            case "resource": return item["resource"]?["text"]?.string ?? "[resource]"
            case "resource_link": return "[resource: \(item["uri"]?.string ?? "")]"
            default: return "[\(type)]"
            }
        }
        let text = parts.joined(separator: "\n")
        return result["isError"]?.bool == true ? "Error: " + text : text
    }

    // MARK: JSON-RPC

    private func request(_ method: String, _ params: JSONValue, timeout: TimeInterval) async throws -> JSONValue {
        nextID += 1
        let id = nextID
        let message: JSONValue = ["jsonrpc": "2.0", "id": .number(Double(id)), "method": .string(method), "params": params]
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { cont in
                guard !Task.isCancelled else { return cont.resume(throwing: CancellationError()) }
                let timer = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(timeout))
                    await self?.finish(id, .failure(MCPError.timeout(method)))
                }
                pending[id] = (cont, timer)
                Task { [transport] in
                    do { try await transport.send(message) } catch { self.finish(id, .failure(error)) }
                }
            }
        } onCancel: {
            Task { await self.finish(id, .failure(CancellationError())) }
        }
    }

    private func finish(_ id: Int, _ result: Result<JSONValue, Error>) {
        guard let entry = pending.removeValue(forKey: id) else { return }
        entry.timer.cancel()
        entry.cont.resume(with: result)
    }

    private func failAll(_ error: Error) {
        for id in Array(pending.keys) { finish(id, .failure(error)) }
    }

    private func transportEnded() { failAll(MCPError.closed) }

    private func handle(_ message: JSONValue) async {
        let id = message["id"]
        if message["method"] != nil {
            // Server request: only `ping` is supported. Notifications need no answer.
            guard let id else { return }
            let reply: JSONValue = message["method"]?.string == "ping"
                ? ["jsonrpc": "2.0", "id": id, "result": [:]]
                : ["jsonrpc": "2.0", "id": id, "error": ["code": .number(-32601), "message": "Method not found"]]
            try? await transport.send(reply)
        } else if let n = id?.int {
            if let error = message["error"] {
                finish(n, .failure(MCPError.rpc(code: error["code"]?.int ?? -1,
                                                message: error["message"]?.string ?? "Unknown MCP error")))
            } else {
                finish(n, .success(message["result"] ?? .null))
            }
        }
    }
}
