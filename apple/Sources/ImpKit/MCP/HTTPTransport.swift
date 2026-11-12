import Foundation
import ImpCore

/// MCP Streamable HTTP over URLSession: each message is a POST. The core decides the headers, which
/// statuses are fine and what the reply body holds (JSON, a batch or an event stream).
public final class HTTPTransport: MCPTransport, @unchecked Sendable {
    public let incoming: AsyncStream<String>
    private let continuation: AsyncStream<String>.Continuation
    private let url: URL
    private let headers: [String: String]
    private let session: URLSession
    private let lock = NSLock()
    private var sessionID: String?
    private var protocolVersion: String?

    public init(url: URL, headers: [String: String], session: URLSession = .shared) {
        (incoming, continuation) = AsyncStream.makeStream(of: String.self)
        self.url = url; self.headers = headers; self.session = session
    }

    public func start() async throws {}

    public func initialized(protocolVersion: String) {
        lock.withLock { self.protocolVersion = protocolVersion }
    }

    private func request(method: String, protocolHeaders: [McpHeader], timeout: TimeInterval) -> URLRequest {
        var r = URLRequest(url: url, timeoutInterval: timeout)
        r.httpMethod = method
        for (k, v) in headers { r.setValue(v, forHTTPHeaderField: k) }
        for h in protocolHeaders { r.setValue(h.value, forHTTPHeaderField: h.name) }
        return r
    }

    private var known: (session: String?, protocolVersion: String?) {
        lock.withLock { (sessionID, protocolVersion) }
    }

    public func send(_ message: String) async throws {
        let (session, version) = known
        var r = request(method: "POST", protocolHeaders: mcpPostHeaders(session: session, protocolVersion: version), timeout: 120)
        r.httpBody = Data(message.utf8)
        let (data, response) = try await self.session.data(for: r)
        guard let http = response as? HTTPURLResponse else { return }
        if let id = http.value(forHTTPHeaderField: mcpSessionHeaderName()) {
            lock.withLock { sessionID = id }
        }
        guard mcpReplyIsAccepted(status: UInt16(clamping: http.statusCode)) else {
            throw MCPError.http(http.statusCode, String(decoding: data.prefix(300), as: UTF8.self))
        }
        guard !data.isEmpty else { return } // 202 Accepted for notifications/responses
        let type = http.value(forHTTPHeaderField: "Content-Type") ?? ""
        do {
            for text in try mcpReplyMessages(contentType: type, body: data) { continuation.yield(text) }
        } catch McpProtocolError.Failed(let message) {
            throw MCPError.protocolError(message)
        }
    }

    /// Ends the session with a DELETE when the server started one, as Streamable HTTP says.
    public func close() async {
        let (session, version) = known
        if let end = mcpEndHeaders(session: session, protocolVersion: version) {
            _ = try? await self.session.data(for: request(method: "DELETE", protocolHeaders: end, timeout: 5))
            lock.withLock { sessionID = nil }
        }
        continuation.finish()
    }
}
