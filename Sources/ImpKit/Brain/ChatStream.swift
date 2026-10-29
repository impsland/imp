import Foundation

/// Assembles a streamed chat-completions reply (server-sent events) from its lines: text arrives
/// in pieces, tool calls in fragments keyed by index. Pure, so it's easy to test.
public struct ChatStreamAccumulator: Sendable {
    public private(set) var text = ""
    public private(set) var isDone = false
    private var calls: [Int: (id: String?, name: String, arguments: String)] = [:]

    public init() {}

    /// Feeds one line of the stream. Returns true when it added text.
    @discardableResult
    public mutating func feed(line: String) throws -> Bool {
        let line = line.trimmingCharacters(in: .whitespaces)
        guard line.hasPrefix("data:") else { return false }          // comments, event names, blank lines
        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
        if payload == "[DONE]" { isDone = true; return false }
        guard let data = payload.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        if let err = json["error"] as? [String: Any] {
            throw APIError.http(status: (err["code"] as? Int) ?? 500, message: (err["message"] as? String) ?? String(localized: "Unknown error"))
        }
        guard let choice = (json["choices"] as? [[String: Any]])?.first,
              let delta = choice["delta"] as? [String: Any] else { return false }
        var added = false
        if let piece = delta["content"] as? String, !piece.isEmpty {
            text += piece
            added = true
        }
        for (n, raw) in ((delta["tool_calls"] as? [[String: Any]]) ?? []).enumerated() {
            let i = (raw["index"] as? Int) ?? n
            var call = calls[i] ?? (nil, "", "")
            if let id = raw["id"] as? String, !id.isEmpty { call.id = id }
            if let fn = raw["function"] as? [String: Any] {
                if let name = fn["name"] as? String { call.name += name }
                if let args = fn["arguments"] as? String { call.arguments += args }
            }
            calls[i] = call
        }
        return added
    }

    /// The whole reply so far.
    public var reply: ChatReply {
        let toolCalls = calls.keys.sorted().compactMap { i -> ToolCall? in
            guard let c = calls[i], !c.name.isEmpty else { return nil }
            return ToolCall(id: c.id ?? "call_\(i)", name: c.name, arguments: c.arguments.isEmpty ? "{}" : c.arguments)
        }
        return ChatReply(text: text.trimmingCharacters(in: .whitespacesAndNewlines), toolCalls: toolCalls)
    }
}
