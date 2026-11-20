import Foundation
import ImpCore

/// A place that keeps small secrets by account name: `KeyFile` on the iPhone, a double in tests.
public protocol SecretBackend: Sendable {
    func read(_ account: String) -> String?
    /// Saves a value (empty removes it). Returns whether it worked.
    @discardableResult func write(_ value: String, account: String) -> Bool
    func accounts(withPrefix prefix: String) -> [String]
}

extension KeyFile: SecretBackend {
    public func accounts(withPrefix prefix: String) -> [String] { all().keys.filter { $0.hasPrefix(prefix) } }
}

/// Where the sign-ins of tool servers are kept. On the Mac it is `auth.json` of the shared configuration
/// (`SharedConfigStore.mcpAuth`). On the iPhone it is a private file (`FileMCPAuth`).
public protocol MCPAuthBackend: Sendable {
    func auth(for serverURL: String) -> McpAuth?
    func hasAuth(for serverURL: String) -> Bool
    func save(_ auth: McpAuth, for serverURL: String) -> Bool
    func forget(_ serverURL: String)
    func clientID(issuer: String) -> String?
    func setClientID(_ id: String, issuer: String)
}

/// Sign-ins in a `SecretBackend` (the iPhone's app-private file).
public struct FileMCPAuth: MCPAuthBackend {
    static let authPrefix = "mcp.auth."
    static let clientPrefix = "mcp.client."
    private let file: any SecretBackend

    public init(file: any SecretBackend) { self.file = file }

    public func auth(for serverURL: String) -> McpAuth? {
        guard let text = file.read(Self.authPrefix + serverURL),
              let stored = try? JSONDecoder().decode(StoredAuth.self, from: Data(text.utf8)) else { return nil }
        return stored.auth
    }

    public func hasAuth(for serverURL: String) -> Bool {
        file.accounts(withPrefix: Self.authPrefix + serverURL).contains(Self.authPrefix + serverURL)
    }

    public func save(_ auth: McpAuth, for serverURL: String) -> Bool {
        guard let data = try? JSONEncoder().encode(StoredAuth(auth)) else { return false }
        return file.write(String(decoding: data, as: UTF8.self), account: Self.authPrefix + serverURL)
    }

    public func forget(_ serverURL: String) { file.write("", account: Self.authPrefix + serverURL) }
    public func clientID(issuer: String) -> String? { file.read(Self.clientPrefix + issuer) }
    public func setClientID(_ id: String, issuer: String) { file.write(id, account: Self.clientPrefix + issuer) }
}

/// A design render's tool server sign-ins: none, and nothing is kept.
struct NoMCPAuth: MCPAuthBackend {
    func auth(for serverURL: String) -> McpAuth? { nil }
    func hasAuth(for serverURL: String) -> Bool { false }
    func save(_ auth: McpAuth, for serverURL: String) -> Bool { false }
    func forget(_ serverURL: String) {}
    func clientID(issuer: String) -> String? { nil }
    func setClientID(_ id: String, issuer: String) {}
}

/// What a signed-in MCP server leaves: tokens (secret), kept by a backend.
public final class MCPAuthStore: @unchecked Sendable {
    /// The store the iPhone app uses: the private file in its folder. The Mac passes its own (`SharedConfigStore.mcpAuth`).
    public static let standard = MCPAuthStore(backend: FileMCPAuth(file: KeyFile()))

    /// Signed in to nothing, and nothing is kept.
    public static var empty: MCPAuthStore { MCPAuthStore(backend: NoMCPAuth()) }

    private let backend: any MCPAuthBackend

    public init(backend: any MCPAuthBackend) { self.backend = backend }

    public func auth(for serverURL: String) -> McpAuth? { backend.auth(for: serverURL) }

    /// Whether a sign-in is saved.
    public func hasAuth(for serverURL: String) -> Bool { backend.hasAuth(for: serverURL) }

    @discardableResult
    public func save(_ auth: McpAuth, for serverURL: String) -> Bool { backend.save(auth, for: serverURL) }

    public func forget(_ serverURL: String) { backend.forget(serverURL) }

    /// The client id registered with an authorization server (not a secret, kept alongside).
    public func clientID(issuer: String) -> String? { backend.clientID(issuer: issuer) }
    public func setClientID(_ id: String, issuer: String) { backend.setClientID(id, issuer: issuer) }
}

/// `McpAuth` as JSON.
struct StoredAuth: Codable {
    var issuer, tokenEndpoint, clientId, redirectUri, accessToken: String
    var refreshToken: String?
    var expiresAt: UInt64?
    var scope: String?

    init(_ a: McpAuth) {
        issuer = a.issuer; tokenEndpoint = a.tokenEndpoint; clientId = a.clientId; redirectUri = a.redirectUri
        accessToken = a.accessToken; refreshToken = a.refreshToken; expiresAt = a.expiresAt; scope = a.scope
    }

    var auth: McpAuth {
        McpAuth(issuer: issuer, tokenEndpoint: tokenEndpoint, clientId: clientId, redirectUri: redirectUri,
                accessToken: accessToken, refreshToken: refreshToken, expiresAt: expiresAt, scope: scope)
    }
}
