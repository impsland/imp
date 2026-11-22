import Foundation
import ImpCore

public enum MCPError: LocalizedError, Sendable {
    case rpc(code: Int, message: String)
    case timeout(String)
    /// With the server's last words (the end of its stderr), when it left any.
    case closed(String?)
    case badConfig(String)
    case http(Int, String)
    /// A message the protocol could not make or read, as the core words it.
    case protocolError(String)
    /// The server wants a sign-in (HTTP 401, or 403 asking for more permission). The challenge is
    /// what its `WWW-Authenticate` header said, as the core read it.
    case needsSignIn(url: String, challenge: McpChallenge?)
    /// The person did not sign in to the server (or could not): what to tell the model.
    case signInRequired(server: String)

    public var errorDescription: String? {
        switch self {
        case .rpc(_, let m): m
        case .timeout(let what): String(localized: "MCP request timed out (\(what)).")
        case .closed(let why?): String(localized: "The MCP server closed the connection: \(why)")
        case .closed(nil): String(localized: "The MCP server closed the connection.")
        case .badConfig(let m): m
        case .http(let status, let m):
            m.isEmpty ? mcpStatusText(status: UInt16(clamping: status)) : mcpStatusText(status: UInt16(clamping: status)) + ". " + m
        case .protocolError(let m): m
        case .needsSignIn: String(localized: "The MCP server asks you to sign in.")
        case .signInRequired(let server):
            String(localized: "The person has not signed in to \(server). Ask them to sign in: Tools, then \(server), then Sign in.")
        }
    }
}

/// Moves JSON-RPC messages, as JSON text, to and from one MCP server. What a message means is
/// decided by the core (`ImpCore`'s `mcp…` functions), never here.
public protocol MCPTransport: Sendable {
    /// Messages from the server (responses, requests, notifications). Finishes when the link ends.
    var incoming: AsyncStream<String> { get }
    func start() async throws
    func send(_ message: String) async throws
    /// Whether the client may ask for the stateless revision (`server/discover`). A child process gets
    /// the handshake: a server that does not know `server/discover` may never answer it.
    var offersStateless: Bool { get }
    /// The revision to send with every message from now on, or nil to forget it and any session.
    func speak(protocolVersion: String?)
    func close() async
    /// Why the link ended, if the server said (a stdio server's stderr). Nil while it's fine.
    var lastWords: String? { get }
}

extension MCPTransport {
    public var offersStateless: Bool { false }
    public func speak(protocolVersion: String?) {}
    public var lastWords: String? { nil }
}

/// Builds the transport a config asks for.
func makeTransport(for config: MCPServerConfig, auth: MCPAuthStore? = nil, session: URLSession = .shared) throws -> any MCPTransport {
    switch config.transport {
    case .stdio:
        guard !config.command.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw MCPError.badConfig(String(localized: "No command set for \(config.name)."))
        }
        #if os(macOS)
        return StdioTransport(command: config.command, arguments: config.arguments, environment: config.environment)
        #else
        throw MCPError.badConfig(String(localized: "\(config.name) runs a command, and only a Mac can do that."))
        #endif
    case .http:
        guard let url = URL(string: config.url.trimmingCharacters(in: .whitespaces)),
              ["http", "https"].contains(url.scheme), url.host != nil else {
            throw MCPError.badConfig(String(localized: "Bad URL for \(config.name)."))
        }
        return HTTPTransport(url: url, headers: config.headers, session: session, auth: auth)
    }
}
