import Foundation
import ImpCore

public enum APIError: LocalizedError, Equatable, Sendable {
    case missingKey
    case keyDenied(service: String)
    case noService(String)
    case noModel
    case badURL(String)
    case http(status: Int, message: String)
    case emptyResponse(String)
    /// The Imp has no service of its own, and neither does the default brain.
    case needsBrain(imp: String)
    case timedOut(seconds: Int)

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
        case .needsBrain(let imp):
            String(localized: "\(imp) has no brain yet. Open its settings, choose the Brain tab and pick an AI service and a model.")
        case .timedOut(let seconds):
            String(localized: "No answer after \(seconds) seconds. The service may be slow or out of reach. Check its address on the Brain tab, or allow more time in Settings › Services.")
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
        try await chat(model: model, messages: messages.map(\.record), tools: tools.map(\.record))
    }

    func chat(model: String, messages: [ModelMessage], tools: [ModelTool]) async throws -> ChatReply {
        let body = try Self.requestBody(model: model, messages: messages, tools: tools, stream: false)
        let (data, _) = try await post("chat/completions", body: body, timeout: 90)
        return try Self.chatReply(from: data)
    }

    /// The same round trip, streamed: `onText` hears the reply's text so far as it arrives (only
    /// text: tool calls come back whole at the end). Servers that ignore `stream` still work.
    public func chatStream(model: String, messages: [ChatMessage], tools: [ToolSpec] = [],
                           onText: @Sendable (String) async -> Void) async throws -> ChatReply {
        try await chatStream(model: model, messages: messages.map(\.record), tools: tools.map(\.record), onText: onText)
    }

    func chatStream(model: String, messages: [ModelMessage], tools: [ModelTool],
                    onText: @Sendable (String) async -> Void) async throws -> ChatReply {
        let body = try Self.requestBody(model: model, messages: messages, tools: tools, stream: true)
        let request = try makeRequest("chat/completions", body: body, timeout: 90)
        let (bytes, response) = try await session.bytes(for: request)
        let streamed = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type")?.contains("event-stream") ?? false
        guard streamed, (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true else {
            // An error, or a plain JSON reply from a server that doesn't stream.
            var data = Data()
            for try await byte in bytes { data.append(byte) }
            try Self.check(response, data: data)
            let reply = try Self.chatReply(from: data)
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

    /// The request body, built by the core.
    static func requestBody(model: String, messages: [ModelMessage], tools: [ModelTool], stream: Bool) throws -> Data {
        do {
            return Data(try chatRequestBody(model: model, messages: messages, tools: tools, stream: stream).utf8)
        } catch let error as ChatStreamError {
            throw APIError(error)
        }
    }

    /// The reply in the body of a whole answer, read by the core. A service error in it is thrown.
    static func chatReply(from data: Data) throws -> ChatReply {
        do {
            let reply = try parseChatReply(body: String(decoding: data, as: UTF8.self))
            return ChatReply(text: reply.text, toolCalls: reply.toolCalls.map { ToolCall(id: $0.id, name: $0.name, arguments: $0.arguments) })
        } catch let error as ChatStreamError {
            throw APIError(error)
        }
    }

    // MARK: Models

    /// Model IDs from `GET /models`.
    public func models(timeout: TimeInterval = 30) async throws -> [String] {
        var request = URLRequest(url: baseURL.appendingPathComponent("models"), timeoutInterval: timeout)
        authorize(&request)
        let (data, response) = try await session.data(for: request)
        try Self.check(response, data: data)
        return Self.modelIDs(from: data)
    }

    static func modelIDs(from data: Data) -> [String] {
        parseModelIds(body: String(decoding: data, as: UTF8.self))
    }

    // MARK: Plumbing

    private func authorize(_ request: inout URLRequest) {
        if !apiKey.isEmpty { request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
    }

    private func post(_ path: String, body: Data, timeout: TimeInterval) async throws -> (Data, URLResponse) {
        let (data, response) = try await session.data(for: try makeRequest(path, body: body, timeout: timeout))
        try Self.check(response, data: data)
        return (data, response)
    }

    private func makeRequest(_ path: String, body: Data, timeout: TimeInterval) throws -> URLRequest {
        var request = URLRequest(url: baseURL.appendingPathComponent(path), timeoutInterval: timeout)
        request.httpMethod = "POST"
        authorize(&request)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        return request
    }

    static func check(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard !(200..<300).contains(http.statusCode) else { return }
        throw APIError.http(status: http.statusCode, message: errorMessage(from: data))
    }

    static func errorMessage(from data: Data) -> String {
        chatErrorMessage(body: String(decoding: data, as: UTF8.self))
    }
}
