import Foundation

/// Talks to the Den (see `server/PROTOCOL.md`, "Den API v1"). It only ever speaks to the server the
/// user chose (`ImpServer.den`): addresses are built from that base and checked names, never from
/// text the model or the Den hands back. No cookies, no redirects, short timeouts, and every answer
/// is cut off at a size limit.
public struct DenClient: Sendable {
    /// The most a JSON answer may be. A kit is held to `Kit.maxBytes`.
    public static let maxAnswerBytes = 1_048_576
    public static let timeout: TimeInterval = 15

    public let base: URL
    private let session: URLSession

    /// A private session: nothing is stored or shared with other requests.
    public static func configuration() -> URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout * 2
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCache = nil
        config.waitsForConnectivity = false
        return config
    }

    public init(server: ImpServer, configuration: URLSessionConfiguration = DenClient.configuration()) {
        base = server.den
        session = URLSession(configuration: configuration)
    }

    // MARK: Addresses

    /// Where an item is shown on the web.
    public func page(of item: DenItemID) -> URL { url(["i", item.handle, item.slug]) }

    /// Where an item's kit is downloaded from (what `imp://add?url=` takes).
    public func kitURL(of item: DenItemID) -> URL { url(["v1", "items", item.handle, item.slug, "kit.json"]) }

    private func url(_ path: [String], query: [URLQueryItem] = []) -> URL {
        var parts = URLComponents(url: base, resolvingAgainstBaseURL: false)!
        parts.path = "/" + path.joined(separator: "/")
        parts.queryItems = query.isEmpty ? nil : query
        return parts.url!
    }

    // MARK: Accounts

    /// A fresh challenge to solve before making an account.
    public func challenge() async throws -> AltchaChallenge {
        try await send(get(url(["v1", "challenge"])))
    }

    /// Makes an account. `altcha` is `Altcha.payload(…)`.
    public func createAccount(handle: String, altcha: String) async throws -> DenNewAccount {
        try await send(request(url(["v1", "accounts"]), method: "POST", body: ["handle": .string(handle), "altcha": .string(altcha)]))
    }

    public func account(_ handle: String) async throws -> DenAccount {
        guard DenName.isValid(handle, range: 3...32) else { throw DenError.unreadable }
        return try await send(get(url(["v1", "accounts", handle])))
    }

    // MARK: Items

    public func items(_ query: DenQuery) async throws -> DenPage {
        var items: [URLQueryItem] = []
        for (name, value) in [("q", query.text), ("kind", query.kind), ("tag", query.tag), ("sort", query.sort), ("cursor", query.cursor)] {
            if let value, !value.isEmpty { items.append(URLQueryItem(name: name, value: value)) }
        }
        items.append(URLQueryItem(name: "limit", value: String(min(max(query.limit, 1), 50))))
        return try await send(get(url(["v1", "items"], query: items)))
    }

    public func item(_ id: DenItemID) async throws -> DenItem {
        try await send(get(url(["v1", "items", id.handle, id.slug])))
    }

    /// The kit's JSON text, at most `Kit.maxBytes`.
    public func kit(_ id: DenItemID) async throws -> String {
        let data = try await fetch(get(kitURL(of: id)), limit: Kit.maxBytes)
        guard let text = String(data: data, encoding: .utf8) else { throw DenError.unreadable }
        return text
    }

    /// Shares a kit as `id`, or updates it. Returns whether it's new.
    @discardableResult
    public func put(_ id: DenItemID, summary: String, tags: [String], kit: String, token: String) async throws -> Bool {
        guard kit.utf8.count <= Kit.maxBytes, let kitJSON = try? JSONValue(jsonString: kit) else { throw DenError.tooLarge }
        let body: JSONValue = ["summary": .string(summary), "tags": .array(tags.map { .string($0) }), "kit": kitJSON]
        let (_, response) = try await fetchWithResponse(request(url(["v1", "items", id.handle, id.slug]), method: "PUT", body: body, token: token),
                                                        limit: Self.maxAnswerBytes)
        return response.statusCode == 201
    }

    public func delete(_ id: DenItemID, token: String) async throws {
        _ = try await fetch(request(url(["v1", "items", id.handle, id.slug]), method: "DELETE", token: token), limit: Self.maxAnswerBytes)
    }

    /// Counts one install of an item.
    public func countInstall(_ id: DenItemID) async throws {
        _ = try await fetch(request(url(["v1", "items", id.handle, id.slug, "installs"]), method: "POST"), limit: Self.maxAnswerBytes)
    }

    // MARK: Requests

    private func get(_ url: URL) -> URLRequest { request(url, method: "GET") }

    private func request(_ url: URL, method: String, body: JSONValue? = nil, token: String? = nil) -> URLRequest {
        var request = URLRequest(url: url, timeoutInterval: Self.timeout)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = Data(body.jsonString.utf8)
        }
        return request
    }

    private func send<T: Decodable>(_ request: URLRequest) async throws -> T {
        let data = try await fetch(request, limit: Self.maxAnswerBytes)
        guard let value = try? JSONDecoder().decode(T.self, from: data) else { throw DenError.unreadable }
        return value
    }

    private func fetch(_ request: URLRequest, limit: Int) async throws -> Data {
        try await fetchWithResponse(request, limit: limit).0
    }

    /// The answer's body, read no further than `limit`. Anything but a 2xx becomes a `DenError`.
    private func fetchWithResponse(_ request: URLRequest, limit: Int) async throws -> (Data, HTTPURLResponse) {
        let (bytes, response) = try await session.bytes(for: request, delegate: NoRedirects())
        guard let http = response as? HTTPURLResponse else { throw DenError.unreadable }
        let ok = (200..<300).contains(http.statusCode)
        let cap = ok ? limit : 16_384
        if ok, response.expectedContentLength > Int64(limit) { throw DenError.tooLarge }
        var data = Data()
        for try await byte in bytes {
            data.append(byte)
            if data.count > cap {
                if ok { throw DenError.tooLarge }
                break
            }
        }
        guard ok else { throw DenError.read(status: http.statusCode, body: data, retryAfter: http.value(forHTTPHeaderField: "Retry-After")) }
        return (data, http)
    }

    /// The Den answers where it lives. A redirect is an answer from somewhere else, so it isn't followed.
    private final class NoRedirects: NSObject, URLSessionTaskDelegate, Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }
}
