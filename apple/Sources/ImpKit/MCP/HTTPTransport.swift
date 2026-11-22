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
    private let authorizer: MCPAuthorizer?

    public init(url: URL, headers: [String: String], session: URLSession = .shared, auth: MCPAuthStore? = nil) {
        (incoming, continuation) = AsyncStream.makeStream(of: String.self)
        self.url = url; self.headers = headers; self.session = session
        authorizer = auth.map { MCPAuthorizer(serverURL: url.absoluteString, store: $0, session: session) }
    }

    public func start() async throws {}

    public var offersStateless: Bool { true }

    public func speak(protocolVersion: String?) {
        lock.withLock {
            self.protocolVersion = protocolVersion
            if protocolVersion == nil { sessionID = nil }
        }
    }

    /// A header the person set themselves wins over a stored sign-in.
    private var setsAuthorization: Bool { headers.keys.contains { $0.lowercased() == "authorization" } }

    private func request(method: String, protocolHeaders: [McpHeader], timeout: TimeInterval) async -> URLRequest {
        var r = URLRequest(url: url, timeoutInterval: timeout)
        r.httpMethod = method
        for (k, v) in headers { r.setValue(v, forHTTPHeaderField: k) }
        if !setsAuthorization, let h = await authorizer?.header() { r.setValue(h.value, forHTTPHeaderField: h.name) }
        for h in protocolHeaders { r.setValue(h.value, forHTTPHeaderField: h.name) }
        return r
    }

    private var known: (session: String?, protocolVersion: String?) {
        lock.withLock { (sessionID, protocolVersion) }
    }

    public func send(_ message: String) async throws {
        let (session, version) = known
        let protocolHeaders: [McpHeader]
        do {
            protocolHeaders = try mcpPostHeaders(message: message, session: session, protocolVersion: version)
        } catch McpProtocolError.Failed(let text) {
            throw MCPError.protocolError(text)
        }
        var (data, response) = try await post(message, protocolHeaders)
        if let http = response as? HTTPURLResponse, http.statusCode == 401, !setsAuthorization,
           let authorizer, await authorizer.refreshStored() {
            (data, response) = try await post(message, protocolHeaders)   // once, with the fresh token
        }
        guard let http = response as? HTTPURLResponse else { return }
        if let signIn = needsSignIn(http) { throw signIn }
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

    private func post(_ message: String, _ protocolHeaders: [McpHeader]) async throws -> (Data, URLResponse) {
        var r = await request(method: "POST", protocolHeaders: protocolHeaders, timeout: 120)
        r.httpBody = Data(message.utf8)
        return try await session.data(for: r)
    }

    /// A 401, or a 403 that asks for more permission, means the person has to sign in (again).
    private func needsSignIn(_ http: HTTPURLResponse) -> MCPError? {
        guard http.statusCode == 401 || http.statusCode == 403 else { return nil }
        let challenge = http.value(forHTTPHeaderField: "WWW-Authenticate").flatMap { mcpParseChallenge(header: $0) }
        if http.statusCode == 403, challenge?.insufficientScope != true { return nil }
        if setsAuthorization { return nil }   // their own credentials were refused: plain HTTP error
        return .needsSignIn(url: url.absoluteString, challenge: challenge)
    }

    /// Ends the session with a DELETE when the server started one, as Streamable HTTP says.
    public func close() async {
        let (session, version) = known
        if let end = mcpEndHeaders(session: session, protocolVersion: version) {
            _ = try? await self.session.data(for: await request(method: "DELETE", protocolHeaders: end, timeout: 5))
            lock.withLock { sessionID = nil }
        }
        continuation.finish()
    }
}
