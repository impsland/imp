import Foundation
import ImpCore

/// Shows the authorization page to the person and returns the address it came back to. The apps
/// implement it with `ASWebAuthenticationSession`. Throws `MCPSignInError.cancelled` when the
/// person closes the sheet.
public protocol MCPSignInPresenter: Sendable {
    func present(_ authorizeURL: URL, callbackScheme: String) async throws -> URL
}

public enum MCPSignInError: LocalizedError, Sendable, Equatable {
    case cancelled
    case failed(String)
    /// Nobody is there to see the sheet (the app is in the background): do not open it.
    case notAttended

    public var errorDescription: String? {
        switch self {
        case .cancelled: String(localized: "Sign-in was cancelled.")
        case .failed(let m): m
        case .notAttended: String(localized: "Open Imp to sign in.")
        }
    }
}

/// Signs in to an MCP server that asks for it (MCP authorization, OAuth 2.1), with no code that is
/// specific to a server. The rules and the request bodies are the core's (`mcp…` in `ImpCore`,
/// the numbered flow is at the top of engine/ffi/src/mcp_auth.rs); this makes the requests.
public struct MCPSignIn: Sendable {
    /// The redirect address Imp registers (a private-use scheme, RFC 8252).
    public static let redirectURI = "app.imp:/oauth"
    public static let callbackScheme = "app.imp"

    let store: MCPAuthStore
    let presenter: any MCPSignInPresenter
    let session: URLSession

    public init(store: MCPAuthStore = .standard, presenter: any MCPSignInPresenter, session: URLSession = .shared) {
        self.store = store; self.presenter = presenter; self.session = session
    }

    /// Runs the whole sign-in for the server at `url` and stores the result. `challenge` is what
    /// the server's 401 said, if known; without it the server is asked once.
    @discardableResult
    public func signIn(to url: String, challenge: McpChallenge? = nil) async throws -> McpAuth {
        var challenge = challenge
        if challenge == nil { challenge = try await probe(url) }
        // 2. The resource, then its authorization server.
        let info = try await resourceInfo(url, challenge: challenge)
        guard let issuer = info.authorizationServers.first else {
            throw MCPSignInError.failed(String(localized: "The server does not say who signs people in."))
        }
        let server = try await authServer(issuer)
        // 3. A client id for this issuer, registered once.
        let clientID = try await clientID(for: server)
        // 4. The person signs in.
        let pkce = mcpPkceNew()
        let state = mcpRandomState()
        let scope = mcpChooseScope(challenge: challenge?.scope, supported: info.scopesSupported)
        let authorize = mcpAuthorizeUrl(server: server, clientId: clientID, redirectUri: Self.redirectURI,
                                        codeChallenge: pkce.challenge, state: state, scope: scope, mcpUrl: url)
        guard let authorizeURL = URL(string: authorize) else { throw MCPSignInError.failed(String(localized: "The sign-in address is not valid.")) }
        let callback = try await presenter.present(authorizeURL, callbackScheme: Self.callbackScheme)
        let code = try wording { try mcpParseCallback(callback: callback.absoluteString, expectedState: state) }
        // 5. The code becomes tokens.
        let body = mcpTokenRequestCode(clientId: clientID, code: code, redirectUri: Self.redirectURI, verifier: pkce.verifier, mcpUrl: url)
        let (status, text) = try await send(server.tokenEndpoint, form: body)
        let grant = try wording { try mcpParseTokenResponse(status: status, body: text, now: UInt64(Date().timeIntervalSince1970)) }
        let auth = mcpAuthNew(server: server, clientId: clientID, redirectUri: Self.redirectURI, grant: grant)
        guard store.save(auth, for: url) else {
            throw MCPSignInError.failed(String(localized: "The sign-in could not be saved."))
        }
        return auth
    }

    /// Forgets the sign-in for `url`. Revokes the token first if the server has a revocation
    /// endpoint (best effort: whatever fails is ignored).
    public func signOut(of url: String) async {
        guard let auth = store.auth(for: url) else { return }
        store.forget(url)
        guard let endpoint = await revocationEndpoint(issuer: auth.issuer) else { return }
        for token in [auth.refreshToken, auth.accessToken].compactMap({ $0 }) {
            let body = "token=\(Self.form(token))&client_id=\(Self.form(auth.clientId))"
            _ = try? await send(endpoint, form: body)
        }
    }

    // MARK: Steps

    /// What the server answers to an unauthenticated `initialize`.
    private func probe(_ url: String) async throws -> McpChallenge? {
        guard let u = URL(string: url) else { throw MCPSignInError.failed(String(localized: "Bad URL.")) }
        var r = URLRequest(url: u, timeoutInterval: 30)
        r.httpMethod = "POST"
        for h in mcpPostHeaders(session: nil, protocolVersion: nil) { r.setValue(h.value, forHTTPHeaderField: h.name) }
        r.httpBody = Data(mcpInitializeRequest(id: 1).utf8)
        guard let (_, response) = try? await session.data(for: r), let http = response as? HTTPURLResponse else { return nil }
        return http.value(forHTTPHeaderField: "WWW-Authenticate").flatMap { mcpParseChallenge(header: $0) }
    }

    private func resourceInfo(_ url: String, challenge: McpChallenge?) async throws -> McpResourceInfo {
        for address in mcpResourceMetadataUrls(mcpUrl: url, fromChallenge: challenge?.resourceMetadata) {
            if let text = await body(address) { return try wording { try mcpParseResourceMetadata(body: text, mcpUrl: url) } }
        }
        throw MCPSignInError.failed(String(localized: "The server does not say how to sign in."))
    }

    private func authServer(_ issuer: String) async throws -> McpAuthServer {
        for address in mcpAuthServerMetadataUrls(issuer: issuer) {
            if let text = await body(address) { return try wording { try mcpParseAuthServer(body: text, issuer: issuer) } }
        }
        throw MCPSignInError.failed(String(localized: "The sign-in service does not answer."))
    }

    private func clientID(for server: McpAuthServer) async throws -> String {
        if let known = store.clientID(issuer: server.issuer) { return known }
        guard let endpoint = server.registrationEndpoint else {
            throw MCPSignInError.failed(String(localized: "The sign-in service does not let Imp register."))
        }
        let body = mcpRegistrationBody(redirectUris: [Self.redirectURI])
        let (status, text) = try await send(endpoint, body: body, type: "application/json")
        let id = try wording { try mcpParseRegistration(status: status, body: text) }
        store.setClientID(id, issuer: server.issuer)
        return id
    }

    /// The `revocation_endpoint` of the issuer's metadata, if it has one.
    private func revocationEndpoint(issuer: String) async -> String? {
        for address in mcpAuthServerMetadataUrls(issuer: issuer) {
            guard let text = await body(address),
                  let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else { continue }
            return object["revocation_endpoint"] as? String
        }
        return nil
    }

    // MARK: Requests

    /// The body of a GET that answered 200.
    private func body(_ address: String) async -> String? {
        guard let (status, text) = try? await get(address), status == 200 else { return nil }
        return text
    }

    private func get(_ address: String) async throws -> (UInt16, String) {
        guard let u = URL(string: address) else { throw MCPSignInError.failed(String(localized: "Bad URL.")) }
        var r = URLRequest(url: u, timeoutInterval: 30)
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        return try await run(r)
    }

    private func send(_ address: String, form: String) async throws -> (UInt16, String) {
        try await send(address, body: form, type: "application/x-www-form-urlencoded")
    }

    private func send(_ address: String, body: String, type: String) async throws -> (UInt16, String) {
        guard let u = URL(string: address) else { throw MCPSignInError.failed(String(localized: "Bad URL.")) }
        var r = URLRequest(url: u, timeoutInterval: 30)
        r.httpMethod = "POST"
        r.setValue(type, forHTTPHeaderField: "Content-Type")
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        r.httpBody = Data(body.utf8)
        return try await run(r)
    }

    private func run(_ r: URLRequest) async throws -> (UInt16, String) {
        do {
            let (data, response) = try await session.data(for: r)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            return (UInt16(clamping: status), String(decoding: data, as: UTF8.self))
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw MCPSignInError.failed(error.localizedDescription)
        }
    }

    private static func form(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")) ?? s
    }

    /// Core errors carry a sentence; show that.
    private func wording<T>(_ body: () throws -> T) throws -> T {
        do { return try body() }
        catch McpAuthError.Failed(let message) { throw MCPSignInError.failed(message) }
        catch McpProtocolError.Failed(let message) { throw MCPSignInError.failed(message) }
    }
}
