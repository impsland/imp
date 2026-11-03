import Foundation

/// Supplies tools to the model and executes them.
public protocol ToolProvider: Sendable {
    func tools() async -> [ToolSpec]
    func call(_ name: String, arguments: String) async throws -> String
    /// Like `call`, but a tool may hand back pictures too (a screenshot). The default wraps `call`.
    func run(_ name: String, arguments: String) async throws -> ToolOutput
    /// The tools with their registry entries, which is what a selection is applied to (`ToolSet`).
    /// The default looks each tool up among the built-in ones.
    func catalog() async -> [CatalogTool]
}

extension ToolProvider {
    public func run(_ name: String, arguments: String) async throws -> ToolOutput {
        ToolOutput(try await call(name, arguments: arguments))
    }

    public func catalog() async -> [CatalogTool] {
        await tools().map { CatalogTool(entry: ToolRegistry.entry(named: $0.name), spec: $0) }
    }
}

/// What a tool returns: the text the model reads, and pictures it should look at.
public struct ToolOutput: Equatable, Sendable {
    public var text: String
    public var images: [EncodedImage]
    public init(_ text: String, images: [EncodedImage] = []) { self.text = text; self.images = images }
}

/// Progress of a run, for showing what the model is doing.
public enum AgentEvent: Equatable, Sendable {
    /// The reply's text so far (streaming). Text that came before tool calls is superseded by them.
    case text(String)
    /// A tool call starts: its name and raw JSON arguments.
    case toolStarted(String, arguments: String)
    /// A tool call ends: its name, whether it worked, and what the model reads back.
    case toolFinished(String, ok: Bool, result: String)
    /// A request failed for a passing reason and is about to be tried again.
    case retrying(RetryNotice)
}

/// Chat loop that lets the model call tools until it answers with text.
public struct Agent: Sendable {
    public var client: OpenAIClient
    public var model: String
    public var tools: ToolProvider?
    public var maxSteps = 16
    /// How long one request may take and how it is retried.
    public var limits: RequestLimits
    /// Waits between retries. Tests swap it so they don't wait.
    public var sleep: @Sendable (TimeInterval) async throws -> Void
    /// Counts the time a request may take. Tests swap it too.
    public var deadlineSleep: @Sendable (TimeInterval) async throws -> Void

    public init(client: OpenAIClient, model: String, tools: ToolProvider? = nil, maxSteps: Int = 16,
                limits: RequestLimits = .standard, sleep: @escaping @Sendable (TimeInterval) async throws -> Void = RetryPolicy.pause,
                deadlineSleep: @escaping @Sendable (TimeInterval) async throws -> Void = RetryPolicy.pause) {
        self.client = client; self.model = model; self.tools = tools; self.maxSteps = maxSteps
        self.limits = limits.clamped; self.sleep = sleep; self.deadlineSleep = deadlineSleep
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
            var pictured: [String] = []
            var pictures: [EncodedImage] = []
            for call in reply.toolCalls {
                try Task.checkCancellation()
                await onEvent(.toolStarted(call.name, arguments: call.arguments))
                let output: ToolOutput
                do { output = try await tools.run(call.name, arguments: call.arguments) }
                catch is CancellationError { throw CancellationError() }
                catch { output = ToolOutput("Error: \(error.localizedDescription)") }
                let result = output.text
                await onEvent(.toolFinished(call.name, ok: !result.hasPrefix("Error:"), result: result))
                transcript.append(.tool(id: call.id, content: result))
                if !output.images.isEmpty { pictured.append(call.name); pictures += output.images }
            }
            // Tool messages can't carry pictures across providers: they follow as one user message.
            if !pictures.isEmpty { transcript.append(.attachment(pictures, from: pictured)) }
        }
        // Out of steps: force a plain answer.
        try Task.checkCancellation()
        let final = try await ask(transcript, tools: [], stream: stream, onEvent: onEvent)
        transcript.append(.assistant(final.text))
        return (final.text, transcript)
    }

    /// Whether a try already showed some of the answer: a retry would show it twice.
    private actor Shown {
        private(set) var any = false
        func mark() { any = true }
    }

    /// One model request, every one the loop makes: bounded in time and retried when the network
    /// hiccups (unless the answer already started streaming in).
    private func ask(_ messages: [ChatMessage], tools: [ToolSpec], stream: Bool,
                     onEvent: @Sendable (AgentEvent) async -> Void) async throws -> ChatReply {
        let limits = limits, sleep = sleep, deadlineSleep = deadlineSleep, client = client, model = model
        return try await withoutActuallyEscaping(onEvent) { emit in
            let shown = Shown()
            return try await limits.policy.run(sleep: sleep, canRetry: { await !shown.any },
                                               onRetry: { await emit(.retrying($0)) }) {
                try await RequestDeadline.run(seconds: limits.timeoutSeconds, sleep: deadlineSleep) {
                    guard stream else { return try await client.chat(model: model, messages: messages, tools: tools) }
                    return try await client.chatStream(model: model, messages: messages, tools: tools) { text in
                        if !text.isEmpty { await shown.mark() }
                        await emit(.text(text))
                    }
                }
            }
        }
    }
}
