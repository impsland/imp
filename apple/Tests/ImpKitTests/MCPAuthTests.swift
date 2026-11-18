import Foundation
import Testing
import ImpCore
@testable import ImpKit

/// Answers requests from a closure and keeps them (own stub: suites run in parallel).
final class AuthStub: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest, String) -> (Int, [String: String], String))?
    nonisolated(unsafe) static var seen: [(request: URLRequest, body: String)] = []
    static let lock = NSLock()

    static func reset(_ h: @escaping (URLRequest, String) -> (Int, [String: String], String)) {
        lock.withLock { handler = h; seen = [] }
    }
    static var requests: [(request: URLRequest, body: String)] { lock.withLock { seen } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        var body = request.httpBody ?? Data()
        if body.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let n = stream.read(&buffer, maxLength: buffer.count)
                if n <= 0 { break }
                body.append(buffer, count: n)
            }
        }
        let text = String(decoding: body, as: UTF8.self)
        let h = Self.lock.withLock { () -> ((URLRequest, String) -> (Int, [String: String], String))? in
            Self.seen.append((request, text)); return Self.handler
        }
        let (status, headers, reply) = h?(request, text) ?? (500, [:], "")
        let data = Data(reply.utf8)
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                                       headerFields: headers.merging(["Content-Length": String(data.count)]) { a, _ in a })!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
}

/// A secret store that notes what was done to it.
final class RecordingBackend: SecretBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]
    private(set) var touched = 0
    func read(_ account: String) -> String? { lock.withLock { touched += 1; return values[account] } }
    func write(_ value: String, account: String) -> Bool {
        lock.withLock { touched += 1; values[account] = value.isEmpty ? nil : value }
        return true
    }
    func accounts(withPrefix prefix: String) -> [String] { lock.withLock { touched += 1; return values.keys.filter { $0.hasPrefix(prefix) } } }
}

struct FakePresenter: MCPSignInPresenter {
    var cancel = false
    func present(_ authorizeURL: URL, callbackScheme: String) async throws -> URL {
        if cancel { throw MCPSignInError.cancelled }
        #expect(callbackScheme == "app.imp")
        let state = URLComponents(url: authorizeURL, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "state" }?.value ?? ""
        return URL(string: "app.imp:/oauth?code=abc&state=\(state)")!
    }
}

private let mcpURL = "https://mcp.example.com/mcp"

private func session() -> URLSession {
    let c = URLSessionConfiguration.ephemeral
    c.protocolClasses = [AuthStub.self]
    return URLSession(configuration: c)
}

private func tempStore(keychain: RecordingBackend = RecordingBackend()) -> (MCPAuthStore, KeyFile) {
    let file = KeyFile(url: FileManager.default.temporaryDirectory.appendingPathComponent("imp-auth-\(UUID().uuidString)/keys.json"))
    return (MCPAuthStore(file: file, keychain: { Issue.record("the Keychain was reached"); return keychain }), file)
}

private func auth(token: String = "AT", expires: UInt64? = nil, refresh: String? = "RT") -> McpAuth {
    McpAuth(issuer: "https://auth.example.com", tokenEndpoint: "https://auth.example.com/token", clientId: "cid",
            redirectUri: "app.imp:/oauth", accessToken: token, refreshToken: refresh, expiresAt: expires, scope: nil)
}

private let farFuture = UInt64(Date().timeIntervalSince1970) + 86_400

@Suite(.serialized) struct MCPAuthTests {
    private func transport(_ store: MCPAuthStore) -> HTTPTransport {
        HTTPTransport(url: URL(string: mcpURL)!, headers: [:], session: session(), auth: store)
    }

    private let challenge = [#"WWW-Authenticate"#: #"Bearer resource_metadata="https://mcp.example.com/.well-known/oauth-protected-resource", scope="read""#]

    @Test func a401WithoutASignInNeedsOne() async throws {
        let (store, _) = tempStore()
        AuthStub.reset { _, _ in (401, challenge, "") }
        do {
            try await transport(store).send(#"{"id":1,"method":"initialize"}"#)
            Issue.record("expected a sign-in error")
        } catch MCPError.needsSignIn(let url, let parsed) {
            #expect(url == mcpURL)
            #expect(parsed?.resourceMetadata == "https://mcp.example.com/.well-known/oauth-protected-resource")
            #expect(parsed?.scope == "read")
        }
        #expect(AuthStub.requests.count == 1, "no sign-in stored: no retry")
        #expect(AuthStub.requests[0].request.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test func aStoredSignInAddsTheBearerHeader() async throws {
        let (store, _) = tempStore()
        store.save(auth(expires: farFuture), for: mcpURL)
        AuthStub.reset { _, _ in (202, [:], "") }
        try await transport(store).send(#"{"method":"notifications/initialized"}"#)
        #expect(AuthStub.requests.count == 1)
        #expect(AuthStub.requests[0].request.value(forHTTPHeaderField: "Authorization") == "Bearer AT")
    }

    @Test func anExpiredTokenIsRefreshedFirst() async throws {
        let (store, _) = tempStore()
        store.save(auth(expires: 1), for: mcpURL)
        AuthStub.reset { request, body in
            if request.url?.path == "/token" {
                return (200, [:], #"{"access_token":"NEW","refresh_token":"RT2","expires_in":3600,"token_type":"Bearer"}"#)
            }
            return (202, [:], "")
        }
        try await transport(store).send(#"{"method":"x"}"#)
        let seen = AuthStub.requests
        #expect(seen.count == 2)
        #expect(seen[0].body.contains("grant_type=refresh_token") && seen[0].body.contains("refresh_token=RT"))
        #expect(seen[1].request.value(forHTTPHeaderField: "Authorization") == "Bearer NEW")
        #expect(store.auth(for: mcpURL)?.refreshToken == "RT2")
    }

    @Test func a401RefreshesAndRetriesOnce() async throws {
        let (store, _) = tempStore()
        store.save(auth(expires: farFuture), for: mcpURL)
        AuthStub.reset { request, _ in
            if request.url?.path == "/token" { return (200, [:], #"{"access_token":"NEW","expires_in":3600}"#) }
            return request.value(forHTTPHeaderField: "Authorization") == "Bearer NEW" ? (202, [:], "") : (401, challenge, "")
        }
        try await transport(store).send(#"{"method":"x"}"#)
        #expect(AuthStub.requests.count == 3, "request, refresh, retry")
        #expect(store.auth(for: mcpURL)?.accessToken == "NEW")
        #expect(store.auth(for: mcpURL)?.refreshToken == "RT", "a refresh token that was not rotated is kept")
    }

    @Test func aDeadRefreshTokenDropsTheSignIn() async throws {
        let (store, _) = tempStore()
        store.save(auth(expires: farFuture), for: mcpURL)
        AuthStub.reset { request, _ in
            request.url?.path == "/token" ? (400, [:], #"{"error":"invalid_grant"}"#) : (401, challenge, "")
        }
        do {
            try await transport(store).send(#"{"method":"x"}"#)
            Issue.record("expected a sign-in error")
        } catch MCPError.needsSignIn {}
        #expect(store.auth(for: mcpURL) == nil)
    }

    @Test func aPersonsOwnAuthorizationHeaderIsLeftAlone() async throws {
        let (store, _) = tempStore()
        store.save(auth(expires: farFuture), for: mcpURL)
        AuthStub.reset { _, _ in (202, [:], "") }
        let t = HTTPTransport(url: URL(string: mcpURL)!, headers: ["Authorization": "Bearer mine"], session: session(), auth: store)
        try await t.send(#"{"method":"x"}"#)
        #expect(AuthStub.requests[0].request.value(forHTTPHeaderField: "Authorization") == "Bearer mine")
    }

    // MARK: Sign-in driver

    private func serverStub() {
        AuthStub.reset { request, body in
            switch request.url?.absoluteString ?? "" {
            case mcpURL: return (401, challenge, "")
            case "https://mcp.example.com/.well-known/oauth-protected-resource":
                return (200, [:], #"{"resource":"\#(mcpURL)","authorization_servers":["https://auth.example.com"],"scopes_supported":["read"]}"#)
            case "https://auth.example.com/.well-known/oauth-authorization-server":
                return (200, [:], #"{"issuer":"https://auth.example.com","authorization_endpoint":"https://auth.example.com/authorize","token_endpoint":"https://auth.example.com/token","registration_endpoint":"https://auth.example.com/register","code_challenge_methods_supported":["S256"]}"#)
            case "https://auth.example.com/register": return (201, [:], #"{"client_id":"cid-1"}"#)
            case "https://auth.example.com/token":
                return (200, [:], #"{"access_token":"AT","refresh_token":"RT","expires_in":3600,"token_type":"Bearer"}"#)
            default: return (404, [:], "")
            }
        }
    }

    @Test func signingInStoresTheTokenInTheFileAndNotTheKeychain() async throws {
        let keychain = RecordingBackend()
        let (store, file) = tempStore(keychain: keychain)
        serverStub()
        let result = try await MCPSignIn(store: store, presenter: FakePresenter(), session: session()).signIn(to: mcpURL)
        #expect(result.accessToken == "AT" && result.clientId == "cid-1" && result.redirectUri == "app.imp:/oauth")
        #expect(store.auth(for: mcpURL)?.refreshToken == "RT")
        #expect(file.all().keys.contains("mcp.auth.\(mcpURL)"), "in the app-private file")
        #expect(file.all().keys.contains("mcp.client.https://auth.example.com"))
        #expect(keychain.touched == 0, "the Keychain is opt-in")
        let token = try #require(AuthStub.requests.first { $0.request.url?.path == "/token" })
        #expect(token.body.contains("code=abc") && token.body.contains("code_verifier="))
    }

    @Test func cancellingLeavesNothingStored() async throws {
        let (store, file) = tempStore()
        serverStub()
        do {
            try await MCPSignIn(store: store, presenter: FakePresenter(cancel: true), session: session()).signIn(to: mcpURL)
            Issue.record("expected cancellation")
        } catch MCPSignInError.cancelled {}
        #expect(store.auth(for: mcpURL) == nil && file.all().keys.allSatisfy { !$0.hasPrefix("mcp.auth.") })
    }

    @Test func signingOutForgetsAndRevokes() async throws {
        let (store, _) = tempStore()
        store.save(auth(expires: farFuture), for: mcpURL)
        AuthStub.reset { request, _ in
            if request.url?.path == "/.well-known/oauth-authorization-server" {
                return (200, [:], #"{"revocation_endpoint":"https://auth.example.com/revoke"}"#)
            }
            return (200, [:], "")
        }
        await MCPSignIn(store: store, presenter: FakePresenter(), session: session()).signOut(of: mcpURL)
        #expect(store.auth(for: mcpURL) == nil)
        #expect(AuthStub.requests.filter { $0.request.url?.path == "/revoke" }.count == 2)
    }

    // MARK: Where tokens live

    @Test func theDefaultStoreNeverReachesTheKeychain() throws {
        let keychain = RecordingBackend()
        let (store, file) = tempStore(keychain: keychain)
        #expect(!store.inKeychain)
        store.save(auth(), for: mcpURL)
        store.setClientID("cid", issuer: "https://auth.example.com")
        #expect(store.auth(for: mcpURL)?.accessToken == "AT" && store.hasAuth(for: mcpURL))
        #expect(store.clientID(issuer: "https://auth.example.com") == "cid")
        store.setInKeychain(false)
        store.forget(mcpURL)
        #expect(store.auth(for: mcpURL) == nil)
        #expect(keychain.touched == 0)
        _ = file
    }

    @Test func theToggleMovesTokensToTheKeychainAndBack() throws {
        let keychain = RecordingBackend()
        let file = KeyFile(url: FileManager.default.temporaryDirectory.appendingPathComponent("imp-auth-\(UUID().uuidString)/keys.json"))
        let store = MCPAuthStore(file: file, keychain: { keychain })
        store.save(auth(), for: mcpURL)
        store.setInKeychain(true)
        #expect(file.all().isEmpty, "moved out of the file")
        #expect(keychain.accounts(withPrefix: "mcp.auth.") == ["mcp.auth.\(mcpURL)"])
        #expect(store.auth(for: mcpURL)?.accessToken == "AT")
        store.setInKeychain(false)
        #expect(keychain.accounts(withPrefix: "mcp.").isEmpty)
        #expect(file.all().keys.contains("mcp.auth.\(mcpURL)"))
    }
}
