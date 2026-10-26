import Foundation

public enum MCPError: LocalizedError, Sendable {
    case rpc(code: Int, message: String)
    case timeout(String)
    case closed
    case badConfig(String)
    case http(Int, String)

    public var errorDescription: String? {
        switch self {
        case .rpc(_, let m): m
        case .timeout(let what): "MCP request timed out (\(what))."
        case .closed: "The MCP server closed the connection."
        case .badConfig(let m): m
        case .http(let status, let m): "MCP server answered HTTP \(status). \(m)"
        }
    }
}

/// Moves JSON-RPC messages to and from one MCP server.
public protocol MCPTransport: Sendable {
    /// Messages from the server (responses, requests, notifications). Finishes when the link ends.
    var incoming: AsyncStream<JSONValue> { get }
    func start() async throws
    func send(_ message: JSONValue) async throws
    /// Called once `initialize` succeeded with the negotiated protocol version.
    func initialized(protocolVersion: String)
    func close() async
}

extension MCPTransport {
    public func initialized(protocolVersion: String) {}
}

/// Builds the transport a config asks for.
func makeTransport(for config: MCPServerConfig) throws -> any MCPTransport {
    switch config.transport {
    case .stdio:
        guard !config.command.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw MCPError.badConfig("No command set for \(config.name).")
        }
        return StdioTransport(command: config.command, arguments: config.arguments, environment: config.environment)
    case .http:
        guard let url = URL(string: config.url.trimmingCharacters(in: .whitespaces)),
              ["http", "https"].contains(url.scheme), url.host != nil else {
            throw MCPError.badConfig("Bad URL for \(config.name).")
        }
        return HTTPTransport(url: url, headers: config.headers)
    }
}

func encodeLine(_ message: JSONValue) throws -> Data { try JSONEncoder().encode(message) }
