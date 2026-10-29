import Foundation

public enum APIError: LocalizedError, Equatable, Sendable {
    case missingKey
    case keyDenied(service: String)
    case noService(String)
    case noModel
    case badURL(String)
    case http(status: Int, message: String)
    case emptyResponse(String)

    public var errorDescription: String? {
        switch self {
        case .missingKey: String(localized: "No API key yet. Add one in All Imps › Services.")
        case .keyDenied(let service):
            String(localized: "I wasn't allowed to read the \(service) key from your Keychain. Ask again and choose Allow, or paste the key in All Imps › Services.")
        case .noService(let what): String(localized: "No AI service picked for \(what). Pick one on its Brain tab.")
        case .noModel: String(localized: "No model picked yet. Pick one on the Brain tab.")
        case .badURL(let s): String(localized: "That base URL looks cursed: \(s)")
        case .http(let status, let message):
            switch status {
            case 401, 403: String(localized: "The API key bounced off my horns (\(status)). \(message)")
            case 402: String(localized: "Out of credits (402). Imps work for gold. \(message)")
            case 429: String(localized: "Too many requests (429). Even imps need a breather.")
            default: String(localized: "The API said \(status): \(message)")
            }
        case .emptyResponse(let what): String(localized: "The model returned no \(what).")
        }
    }
}

/// Minimal OpenAI-compatible client (chat and the model list). Works with OpenRouter,
/// OpenAI and most compatible gateways. An empty key is allowed (local servers). No
/// Authorization header is sent then.
public struct OpenAIClient: Sendable {
    public var baseURL: URL
    public var apiKey: String
    public var session: URLSession

    public init(baseURL: String, apiKey: String, session: URLSession = .shared) throws {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed.hasSuffix("/") ? String(trimmed.dropLast()) : trimmed),
              let scheme = url.scheme, ["http", "https"].contains(scheme), url.host != nil
        else { throw APIError.badURL(baseURL) }
        self.baseURL = url
        self.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        self.session = session
    }

    // MARK: Chat

    /// One chat-completions round trip. An empty `tools` list omits the `tools` key.
    public func chat(model: String, messages: [ChatMessage], tools: [ToolSpec] = []) async throws -> ChatReply {
        var body: [String: Any] = ["model": model, "messages": messages.map(\.json)]
        if !tools.isEmpty { body["tools"] = tools.map(\.json) }
        let json = try await postJSON("chat/completions", body: body, timeout: 90)
        guard let reply = Self.chatReply(from: json) else { throw APIError.emptyResponse("text") }
        return reply
    }

    /// The same round trip, streamed: `onText` hears the reply's text so far as it arrives (only
    /// text: tool calls come back whole at the end). Servers that ignore `stream` still work.
    public func chatStream(model: String, messages: [ChatMessage], tools: [ToolSpec] = [],
                           onText: @Sendable (String) async -> Void) async throws -> ChatReply {
        var body: [String: Any] = ["model": model, "messages": messages.map(\.json), "stream": true]
        if !tools.isEmpty { body["tools"] = tools.map(\.json) }
        let request = try makeRequest("chat/completions", body: body, timeout: 90)
        let (bytes, response) = try await session.bytes(for: request)
        let streamed = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type")?.contains("event-stream") ?? false
        guard streamed, (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true else {
            // An error, or a plain JSON reply from a server that doesn't stream.
            var data = Data()
            for try await byte in bytes { data.append(byte) }
            try Self.check(response, data: data)
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw APIError.emptyResponse("JSON") }
            if let err = json["error"] as? [String: Any] {
                throw APIError.http(status: (err["code"] as? Int) ?? 500, message: (err["message"] as? String) ?? String(localized: "Unknown error"))
            }
            guard let reply = Self.chatReply(from: json) else { throw APIError.emptyResponse("text") }
            if !reply.text.isEmpty { await onText(reply.text) }
            return reply
        }
        var stream = ChatStreamAccumulator()
        for try await line in bytes.lines {
            try Task.checkCancellation()
            if try stream.feed(line: line) { await onText(stream.text) }
            if stream.isDone { break }
        }
        let reply = stream.reply
        guard !reply.text.isEmpty || !reply.toolCalls.isEmpty else { throw APIError.emptyResponse("text") }
        return reply
    }

    /// Text plus tool calls of the first choice. Nil when it has neither.
    static func chatReply(from json: [String: Any]) -> ChatReply? {
        let text = chatText(from: json) ?? ""
        var calls: [ToolCall] = []
        if let choices = json["choices"] as? [[String: Any]],
           let message = choices.first?["message"] as? [String: Any],
           let raw = message["tool_calls"] as? [[String: Any]] {
            for (i, call) in raw.enumerated() {
                guard let fn = call["function"] as? [String: Any], let name = fn["name"] as? String else { continue }
                var args = "{}"
                if let s = fn["arguments"] as? String, !s.isEmpty { args = s }
                else if let o = fn["arguments"], JSONSerialization.isValidJSONObject(o),
                        let d = try? JSONSerialization.data(withJSONObject: o) { args = String(decoding: d, as: UTF8.self) }
                calls.append(ToolCall(id: (call["id"] as? String) ?? "call_\(i)", name: name, arguments: args))
            }
        }
        return text.isEmpty && calls.isEmpty ? nil : ChatReply(text: text, toolCalls: calls)
    }

    static func chatText(from json: [String: Any]) -> String? {
        guard let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any] else { return nil }
        if let s = message["content"] as? String { return s.trimmingCharacters(in: .whitespacesAndNewlines) }
        if let parts = message["content"] as? [[String: Any]] {
            return parts.compactMap { $0["text"] as? String }.joined().trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }

    // MARK: Models

    /// Model IDs from `GET /models`.
    public func models() async throws -> [String] {
        var request = URLRequest(url: baseURL.appendingPathComponent("models"), timeoutInterval: 30)
        authorize(&request)
        let (data, response) = try await session.data(for: request)
        try Self.check(response, data: data)
        return Self.modelIDs(from: data)
    }

    static func modelIDs(from data: Data) -> [String] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = json["data"] as? [[String: Any]] else { return [] }
        return Array(Set(list.compactMap { $0["id"] as? String })).sorted()
    }

    // MARK: Plumbing

    private func authorize(_ request: inout URLRequest) {
        if !apiKey.isEmpty { request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
    }

    private func postJSON(_ path: String, body: [String: Any], timeout: TimeInterval) async throws -> [String: Any] {
        let (data, _) = try await post(path, body: body, timeout: timeout)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw APIError.emptyResponse("JSON")
        }
        // Some gateways return 200 with an error object.
        if let err = json["error"] as? [String: Any] {
            throw APIError.http(status: (err["code"] as? Int) ?? 500, message: (err["message"] as? String) ?? String(localized: "Unknown error"))
        }
        return json
    }

    private func post(_ path: String, body: [String: Any], timeout: TimeInterval) async throws -> (Data, URLResponse) {
        let (data, response) = try await session.data(for: try makeRequest(path, body: body, timeout: timeout))
        try Self.check(response, data: data)
        return (data, response)
    }

    private func makeRequest(_ path: String, body: [String: Any], timeout: TimeInterval) throws -> URLRequest {
        var request = URLRequest(url: baseURL.appendingPathComponent(path), timeoutInterval: timeout)
        request.httpMethod = "POST"
        authorize(&request)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    static func check(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard !(200..<300).contains(http.statusCode) else { return }
        throw APIError.http(status: http.statusCode, message: errorMessage(from: data))
    }

    static func errorMessage(from data: Data) -> String {
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let err = json["error"] as? [String: Any], let msg = err["message"] as? String {
                if let meta = err["metadata"] as? [String: Any], let raw = meta["raw"] as? String, !raw.isEmpty {
                    return "\(msg) — \(raw.prefix(300))"
                }
                return msg
            }
            if let msg = json["message"] as? String { return msg }
        }
        return String(decoding: data.prefix(300), as: UTF8.self)
    }
}
