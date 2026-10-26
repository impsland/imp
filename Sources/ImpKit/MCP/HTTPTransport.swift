import Foundation

/// MCP Streamable HTTP: each message is a POST. The reply is JSON or an SSE stream.
public final class HTTPTransport: MCPTransport, @unchecked Sendable {
    public let incoming: AsyncStream<JSONValue>
    private let continuation: AsyncStream<JSONValue>.Continuation
    private let url: URL
    private let headers: [String: String]
    private let session: URLSession
    private let lock = NSLock()
    private var sessionID: String?
    private var protocolVersion: String?

    public init(url: URL, headers: [String: String], session: URLSession = .shared) {
        (incoming, continuation) = AsyncStream.makeStream(of: JSONValue.self)
        self.url = url; self.headers = headers; self.session = session
    }

    public func start() async throws {}

    public func initialized(protocolVersion: String) {
        lock.withLock { self.protocolVersion = protocolVersion }
    }

    private func request(method: String, timeout: TimeInterval) -> URLRequest {
        var r = URLRequest(url: url, timeoutInterval: timeout)
        r.httpMethod = method
        for (k, v) in headers { r.setValue(v, forHTTPHeaderField: k) }
        lock.withLock {
            if let sessionID { r.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id") }
            if let protocolVersion { r.setValue(protocolVersion, forHTTPHeaderField: "MCP-Protocol-Version") }
        }
        return r
    }

    public func send(_ message: JSONValue) async throws {
        var r = request(method: "POST", timeout: 120)
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        r.httpBody = try encodeLine(message)
        let (data, response) = try await session.data(for: r)
        guard let http = response as? HTTPURLResponse else { return }
        if let id = http.value(forHTTPHeaderField: "Mcp-Session-Id") {
            lock.withLock { sessionID = id }
        }
        guard (200..<300).contains(http.statusCode) else {
            throw MCPError.http(http.statusCode, String(decoding: data.prefix(300), as: UTF8.self))
        }
        guard !data.isEmpty else { return } // 202 Accepted for notifications/responses
        let type = http.value(forHTTPHeaderField: "Content-Type") ?? ""
        for value in Self.messages(in: data, contentType: type) { continuation.yield(value) }
    }

    /// Decodes a POST reply body: a JSON message, a JSON batch, or an SSE stream.
    static func messages(in data: Data, contentType: String) -> [JSONValue] {
        if contentType.contains("text/event-stream") { return parseSSE(String(decoding: data, as: UTF8.self)) }
        guard let value = try? JSONDecoder().decode(JSONValue.self, from: data) else { return [] }
        return value.array ?? [value]
    }

    /// JSON payloads of each SSE event (`data:` lines joined per event).
    static func parseSSE(_ text: String) -> [JSONValue] {
        var out: [JSONValue] = []
        var lines: [String] = []
        func flush() {
            defer { lines = [] }
            guard !lines.isEmpty, let v = try? JSONDecoder().decode(JSONValue.self, from: Data(lines.joined(separator: "\n").utf8))
            else { return }
            out.append(v)
        }
        for raw in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let line = String(raw)
            if line.isEmpty { flush() }
            else if line.hasPrefix("data:") {
                let rest = line.dropFirst(5)
                lines.append(String(rest.hasPrefix(" ") ? rest.dropFirst() : rest))
            }
        }
        flush()
        return out
    }

    public func close() async {
        let hasSession = lock.withLock { sessionID != nil }
        if hasSession { _ = try? await session.data(for: request(method: "DELETE", timeout: 5)) }
        continuation.finish()
    }
}
