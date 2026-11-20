import Foundation
import ImpCore

/// Assembles a streamed chat-completions reply (server-sent events) from its lines: text arrives
/// in pieces, tool calls in fragments keyed by index. The core reads the lines, this keeps its state.
public struct ChatStreamAccumulator: Sendable {
    private let core = ImpCore.ChatStream()

    public init() {}

    public var text: String { core.text() }
    /// All the reasoning so far, for showing (never for sending back).
    public var reasoning: String { core.reasoning() }
    public var isDone: Bool { core.isDone() }

    /// Feeds one line of the stream. Returns true when it added text (read `reasoning` after every line).
    @discardableResult
    public mutating func feed(line: String) throws -> Bool {
        do {
            return try core.feedLine(line: line)
        } catch let error as ChatStreamError {
            throw APIError(error)
        }
    }

    /// The whole reply so far.
    public var reply: ChatReply {
        let r = core.reply()
        return ChatReply(text: r.text, toolCalls: r.toolCalls.map { ToolCall(id: $0.id, name: $0.name, arguments: $0.arguments) }, reasoning: r.reasoning)
    }
}

extension APIError {
    /// An error the core found in a service's answer.
    init(_ error: ChatStreamError) {
        switch error {
        case .Http(let status, let message): self = .http(status: Int(status), message: message)
        case .Empty(let what): self = .emptyResponse(what)
        case .Other(let message): self = .http(status: 500, message: message)
        }
    }
}
