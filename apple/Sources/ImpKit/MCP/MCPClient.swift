import Foundation
import ImpCore

/// An MCP client over any transport. It owns the request ids, the waiting callers and the timers.
/// Every protocol decision (the messages, how answers are read, what a tool result says) is the
/// core's, called through `ImpCore`.
public actor MCPClient {
    private let transport: any MCPTransport
    private var nextID: UInt64 = 0
    private var pending: [UInt64: (cont: CheckedContinuation<String, Error>, timer: Task<Void, Never>)] = [:]
    private var reader: Task<Void, Never>?
    private var closing = false
    private var ended: MCPError?
    private var onEnded: (@Sendable (MCPError) -> Void)?
    /// The revision the server and the client speak, once `connect` agreed on it.
    private var version = ""

    public init(config: MCPServerConfig, auth: MCPAuthStore? = nil) throws { transport = try makeTransport(for: config, auth: auth) }
    init(config: MCPServerConfig, auth: MCPAuthStore?, session: URLSession) throws {
        transport = try makeTransport(for: config, auth: auth, session: session)
    }
    init(transport: any MCPTransport) { self.transport = transport }

    /// Starts the transport and agrees on the revision: the stateless one when the server lists it in
    /// its answer to `server/discover`, otherwise the one the `initialize` handshake agrees on.
    public func connect() async throws {
        try await transport.start()
        reader = Task { [transport] in
            for await message in transport.incoming { await self.handle(message) }
            self.transportEnded()
        }
        version = try await agreeOnVersion()
    }

    /// A server that refuses discovery in any way gets the handshake, unless it wants a sign-in or
    /// cannot be reached.
    private func agreeOnVersion() async throws -> String {
        if transport.offersStateless {
            let stateless = mcpStatelessVersion()
            transport.speak(protocolVersion: stateless)
            do {
                let result = try await request("server/discover", timeout: 30) { mcpDiscoverRequest(id: $0) }
                if try protocolCall({ try mcpSpeaksStateless(resultJson: result) }) { return stateless }
            } catch let error as MCPError {
                if case .needsSignIn = error { throw error }
            }
            transport.speak(protocolVersion: nil)
        }
        let result = try await request("initialize", timeout: 30) { mcpInitializeRequest(id: $0) }
        let agreed = try protocolCall { try mcpCheckedVersion(initializeResultJson: result) }
        transport.speak(protocolVersion: agreed)
        try await transport.send(mcpInitializedNotification())
        return agreed
    }

    /// All tools, following pagination (the core says when to stop).
    public func listTools() async throws -> [ToolSpec] {
        var tools: [ToolSpec] = []
        var cursor: String?
        var seen: [String] = []
        repeat {
            let result = try await request("tools/list", timeout: 30) { mcpToolsListRequest(id: $0, cursor: cursor, protocolVersion: version) }
            let page = try protocolCall { try mcpToolsPage(resultJson: result, seenCursors: seen) }
            for tool in page.tools {
                tools.append(ToolSpec(name: tool.name, description: tool.description,
                                      inputSchema: try JSONValue(jsonString: tool.inputSchemaJson)))
            }
            cursor = page.nextCursor
            if let cursor { seen.append(cursor) }
        } while cursor != nil
        return tools
    }

    /// Calls a tool and returns its content as text. `argumentsJSON` is what the model wrote.
    public func callTool(name: String, argumentsJSON: String) async throws -> String {
        let result = try await request("tools/call", timeout: 120) {
            try mcpToolsCallRequest(id: $0, name: name, arguments: argumentsJSON, protocolVersion: version)
        }
        return try protocolCall { try mcpToolResultText(resultJson: result) }
    }

    public func callTool(name: String, arguments: JSONValue) async throws -> String {
        try await callTool(name: name, argumentsJSON: arguments.jsonString)
    }

    /// `handler` runs once if the server goes away by itself (not on `close()`), at once if it already has.
    public func onEnd(_ handler: @escaping @Sendable (MCPError) -> Void) {
        if let ended { handler(ended) } else { onEnded = handler }
    }

    public func close() async {
        closing = true
        reader?.cancel()
        await transport.close()
        failAll(MCPError.closed(nil))
    }

    // MARK: Waiting for answers

    private func protocolCall<T>(_ body: () throws -> T) throws -> T {
        do { return try body() } catch McpProtocolError.Failed(let message) { throw MCPError.protocolError(message) }
    }

    private func request(_ method: String, timeout: TimeInterval,
                         _ build: (UInt64) throws -> String) async throws -> String {
        nextID += 1
        let id = nextID
        let message: String
        do { message = try build(id) } catch McpProtocolError.Failed(let text) { throw MCPError.protocolError(text) }
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

    private func finish(_ id: UInt64, _ result: Result<String, Error>) {
        guard let entry = pending.removeValue(forKey: id) else { return }
        entry.timer.cancel()
        entry.cont.resume(with: result)
    }

    private func failAll(_ error: Error) {
        for id in Array(pending.keys) { finish(id, .failure(error)) }
    }

    private func transportEnded() {
        let error = MCPError.closed(transport.lastWords)
        failAll(error)
        guard !closing, ended == nil else { return }
        ended = error
        onEnded?(error)
        onEnded = nil
    }

    private func handle(_ text: String) async {
        switch mcpParseMessage(text: text) {
        case .skip: break
        case .answer(let id, let resultJson): finish(id, .success(resultJson))
        case .failure(let id, let code, let message): finish(id, .failure(MCPError.rpc(code: Int(code), message: message)))
        case .request(let replyJson): try? await transport.send(replyJson)
        }
    }
}
