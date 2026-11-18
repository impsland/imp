import Foundation
import ImpCore

/// Adds the stored sign-in to the requests for one MCP server and keeps it fresh. The rules (when
/// to refresh, what the answers mean) are the core's.
public final class MCPAuthorizer: Sendable {
    public let serverURL: String
    private let store: MCPAuthStore
    private let session: URLSession
    private let now: @Sendable () -> UInt64

    public init(serverURL: String, store: MCPAuthStore, session: URLSession = .shared,
                now: @escaping @Sendable () -> UInt64 = { UInt64(Date().timeIntervalSince1970) }) {
        self.serverURL = serverURL; self.store = store; self.session = session; self.now = now
    }

    /// The `Authorization` header to send, refreshing first when the token is about to expire.
    /// Nil when the person is not signed in to this server.
    public func header() async -> McpHeader? {
        guard var auth = store.auth(for: serverURL) else { return nil }
        if mcpAuthNeedsRefresh(auth: auth, now: now()) {
            auth = (await refresh(auth)) ?? auth
        }
        return mcpAuthHeader(auth: auth)
    }

    /// Refreshes the stored sign-in (after a 401). False when there is none or it could not be
    /// refreshed (a dead refresh token drops the sign-in).
    @discardableResult
    public func refreshStored() async -> Bool {
        guard let auth = store.auth(for: serverURL) else { return false }
        return await refresh(auth) != nil
    }

    private func refresh(_ auth: McpAuth) async -> McpAuth? {
        guard let refreshToken = auth.refreshToken, let endpoint = URL(string: auth.tokenEndpoint) else {
            // An expired token without a refresh token cannot be renewed.
            if let at = auth.expiresAt, at <= now() { store.forget(serverURL) }
            return nil
        }
        var r = URLRequest(url: endpoint, timeoutInterval: 30)
        r.httpMethod = "POST"
        r.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        r.httpBody = Data(mcpTokenRequestRefresh(clientId: auth.clientId, refreshToken: refreshToken, mcpUrl: serverURL).utf8)
        guard let (data, response) = try? await session.data(for: r), let http = response as? HTTPURLResponse else { return nil }
        let body = String(decoding: data, as: UTF8.self)
        do {
            let grant = try mcpParseTokenResponse(status: UInt16(clamping: http.statusCode), body: body, now: now())
            let renewed = mcpAuthRefreshed(auth: auth, grant: grant)
            store.save(renewed, for: serverURL)
            return renewed
        } catch {
            if mcpIsInvalidGrant(body: body) { store.forget(serverURL) }
            return nil
        }
    }
}
