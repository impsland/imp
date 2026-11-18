import Foundation
import ImpCore

/// A place that keeps small secrets by account name. `KeyFile` is one (the default), the Keychain
/// the other (opt-in); tests give a double that records what was touched.
public protocol SecretBackend: Sendable {
    func read(_ account: String) -> String?
    /// Saves a value (empty removes it). Returns whether it worked.
    @discardableResult func write(_ value: String, account: String) -> Bool
    func accounts(withPrefix prefix: String) -> [String]
}

extension KeyFile: SecretBackend {
    public func accounts(withPrefix prefix: String) -> [String] { all().keys.filter { $0.hasPrefix(prefix) } }
}

/// The login Keychain as a `SecretBackend`. Only used when the person turned "Keep keys in the
/// Keychain" on; nothing constructs it by default.
public struct KeychainBackend: SecretBackend {
    public init() {}
    public func read(_ account: String) -> String? { (try? Keychain.read(account)) ?? nil }
    public func write(_ value: String, account: String) -> Bool {
        Keychain.write(value, account: account) || (value.isEmpty && !Keychain.contains(account))
    }
    public func accounts(withPrefix prefix: String) -> [String] { Keychain.accounts(withPrefix: prefix) }
}

/// What a signed-in MCP server leaves: tokens (secret) kept like the API keys. In the app-private
/// `KeyFile` unless `inKeychain` is on, and then in the Keychain. The Keychain backend is created
/// only on demand, so the default path never reaches it.
public final class MCPAuthStore: @unchecked Sendable {
    /// The store the apps share. The Mac sets `inKeychain` from the preference.
    public static let standard = MCPAuthStore(file: KeyFile(url: URL.applicationSupportDirectory.appendingPathComponent("Imp/keys.json")))

    static let authPrefix = "mcp.auth."
    static let clientPrefix = "mcp.client."

    private let file: any SecretBackend
    private let makeKeychain: @Sendable () -> any SecretBackend
    private let lock = NSLock()
    private var keychainOn = false
    private var keychainBackend: (any SecretBackend)?

    public init(file: any SecretBackend, keychain: @escaping @Sendable () -> any SecretBackend = { KeychainBackend() }) {
        self.file = file; self.makeKeychain = keychain
    }

    public var inKeychain: Bool { lock.withLock { keychainOn } }

    /// Where reads and writes go now.
    private var backend: any SecretBackend {
        lock.withLock {
            guard keychainOn else { return file }
            if keychainBackend == nil { keychainBackend = makeKeychain() }
            return keychainBackend!
        }
    }

    /// Switches where tokens are kept and moves the saved ones across (nothing is touched when it
    /// is unchanged, and the Keychain is not reached unless one side is the Keychain).
    public func setInKeychain(_ on: Bool) {
        guard on != inKeychain else { return }
        let old = backend
        lock.withLock { keychainOn = on }
        let new = backend
        for prefix in [Self.authPrefix, Self.clientPrefix] {
            for account in old.accounts(withPrefix: prefix) {
                guard let value = old.read(account) else { continue }
                if new.write(value, account: account) { old.write("", account: account) }
            }
        }
    }

    public func auth(for serverURL: String) -> McpAuth? {
        guard let text = backend.read(Self.authPrefix + serverURL),
              let stored = try? JSONDecoder().decode(StoredAuth.self, from: Data(text.utf8)) else { return nil }
        return stored.auth
    }

    /// Whether a sign-in is saved, without reading the token (so the Keychain never asks).
    public func hasAuth(for serverURL: String) -> Bool {
        backend.accounts(withPrefix: Self.authPrefix + serverURL).contains(Self.authPrefix + serverURL)
    }

    @discardableResult
    public func save(_ auth: McpAuth, for serverURL: String) -> Bool {
        guard let data = try? JSONEncoder().encode(StoredAuth(auth)) else { return false }
        return backend.write(String(decoding: data, as: UTF8.self), account: Self.authPrefix + serverURL)
    }

    public func forget(_ serverURL: String) { backend.write("", account: Self.authPrefix + serverURL) }

    /// The client id registered with an authorization server (not a secret, kept alongside).
    public func clientID(issuer: String) -> String? { backend.read(Self.clientPrefix + issuer) }
    public func setClientID(_ id: String, issuer: String) { backend.write(id, account: Self.clientPrefix + issuer) }
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
