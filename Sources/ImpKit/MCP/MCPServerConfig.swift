import Foundation

/// One MCP server Imp can use tools from: a local process (stdio) or a remote endpoint (HTTP).
public struct MCPServerConfig: Codable, Hashable, Sendable, Identifiable {
    public enum Transport: String, Codable, CaseIterable, Sendable, Identifiable {
        case stdio, http
        public var id: String { rawValue }
    }

    public var id = UUID()
    public var name: String
    public var isEnabled = true
    public var transport: Transport
    /// stdio: executable (resolved through the login shell's PATH) and its arguments.
    public var command = ""
    public var arguments: [String] = []
    public var environment: [String: String] = [:]
    /// http: Streamable HTTP endpoint and extra headers (e.g. Authorization).
    public var url = ""
    public var headers: [String: String] = [:]

    public init(name: String, transport: Transport, command: String = "", arguments: [String] = [],
                environment: [String: String] = [:], url: String = "", headers: [String: String] = [:]) {
        self.name = name; self.transport = transport; self.command = command; self.arguments = arguments
        self.environment = environment; self.url = url; self.headers = headers
    }
}
