import Foundation

/// Supplies tools to the model and executes them.
public protocol ToolProvider: Sendable {
    func tools() async -> [ToolSpec]
    func call(_ name: String, arguments: String) async throws -> String
}

/// Progress of a run, for showing what the model is doing.
public enum AgentEvent: Equatable, Sendable {
    /// The reply's text so far (streaming). Text that came before tool calls is superseded by them.
    case text(String)
    /// A tool call starts: its name and raw JSON arguments.
    case toolStarted(String, arguments: String)
    /// A tool call ends: its name, whether it worked, and what the model reads back.
    case toolFinished(String, ok: Bool, result: String)
}

/// Chat loop that lets the model call tools until it answers with text.
public struct Agent: Sendable {
    public var client: OpenAIClient
    public var model: String
    public var tools: ToolProvider?
    public var maxSteps = 16

    public init(client: OpenAIClient, model: String, tools: ToolProvider? = nil, maxSteps: Int = 16) {
        self.client = client; self.model = model; self.tools = tools; self.maxSteps = maxSteps
    }

    /// Runs the loop. `onEvent` hears when each tool starts and finishes and, with `stream`, the
    /// text as it arrives. Returns the final text and the full transcript (input plus new turns).
    public func run(_ messages: [ChatMessage], stream: Bool = false,
                    onEvent: @Sendable (AgentEvent) async -> Void = { _ in }) async throws
        -> (reply: String, transcript: [ChatMessage]) {
        var transcript = messages
        let specs = await tools?.tools() ?? []
        for _ in 0..<(specs.isEmpty ? 1 : maxSteps) {
            try Task.checkCancellation()
            let reply = try await ask(transcript, tools: specs, stream: stream, onEvent: onEvent)
            guard !reply.toolCalls.isEmpty, let tools else {
                transcript.append(.assistant(reply.text))
                return (reply.text, transcript)
            }
            transcript.append(.assistant(reply.text.isEmpty ? nil : reply.text, toolCalls: reply.toolCalls))
            for call in reply.toolCalls {
                try Task.checkCancellation()
                await onEvent(.toolStarted(call.name, arguments: call.arguments))
                let result: String
                do { result = try await tools.call(call.name, arguments: call.arguments) }
                catch is CancellationError { throw CancellationError() }
                catch { result = "Error: \(error.localizedDescription)" }
                await onEvent(.toolFinished(call.name, ok: !result.hasPrefix("Error:"), result: result))
                transcript.append(.tool(id: call.id, content: result))
            }
        }
        // Out of steps: force a plain answer.
        try Task.checkCancellation()
        let final = try await ask(transcript, tools: [], stream: stream, onEvent: onEvent)
        transcript.append(.assistant(final.text))
        return (final.text, transcript)
    }

    private func ask(_ messages: [ChatMessage], tools: [ToolSpec], stream: Bool,
                     onEvent: @Sendable (AgentEvent) async -> Void) async throws -> ChatReply {
        guard stream else { return try await client.chat(model: model, messages: messages, tools: tools) }
        return try await client.chatStream(model: model, messages: messages, tools: tools) { text in await onEvent(.text(text)) }
    }
}
