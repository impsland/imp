import Foundation
import ImpCore

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
        let specs = await tools?.tools() ?? []
        let run = try ImpCore.AgentRun(messages: messages.map(\.record), tools: specs.map(\.record),
                                       maxSteps: UInt32(clamping: max(0, maxSteps)))
        while true {
            try Task.checkCancellation()
            switch run.advance() {
            case .done(let text):
                return (text, messages + run.messages().dropFirst(messages.count).map(ChatMessage.init(record:)))
            case .ask(let request, let offered):
                let reply = try await ask(request, tools: offered, stream: stream, onEvent: onEvent)
                let calls = run.reply(reply: StreamReply(
                    text: reply.text, toolCalls: reply.toolCalls.map { StreamToolCall(id: $0.id, name: $0.name, arguments: $0.arguments) }))
                guard let tools else { continue }
                // Consecutive calls of tools that may overlap (`troupe::runs_concurrently`: asking other Imps) run
                // together. Every result is handed back in the order the model asked, so the transcript keeps it.
                var index = 0
                while index < calls.count {
                    var end = index + 1
                    if ImpCore.troupeRunsConcurrently(tool: calls[index].name) {
                        while end < calls.count, ImpCore.troupeRunsConcurrently(tool: calls[end].name) { end += 1 }
                    }
                    let batch = Array(calls[index..<end])
                    index = end
                    try Task.checkCancellation()
                    for call in batch { await onEvent(.toolStarted(call.name, arguments: call.arguments)) }
                    let results = try await Self.execute(batch.map { ($0.name, $0.arguments) }, with: tools)
                    for (call, result) in zip(batch, results) {
                        let done: ToolOutcome
                        switch result {
                        case .success(let output):
                            done = run.toolResult(callId: call.id, tool: call.name, text: output.text, images: output.images.map(\.dataURL))
                        case .failure(let error):
                            done = run.toolFailed(callId: call.id, tool: call.name, message: error.localizedDescription)
                        }
                        await onEvent(.toolFinished(call.name, ok: done.ok, result: done.text))
                    }
                }
            }
        }
    }

    /// Runs one batch of calls: a single one on its own, several at once. Results come back in the order of
    /// `calls`. Cancellation of any of them cancels the rest and is thrown.
    private static func execute(_ calls: [(name: String, arguments: String)], with tools: ToolProvider) async throws
        -> [Result<ToolOutput, Error>] {
        func attempt(_ call: (name: String, arguments: String)) async -> Result<ToolOutput, Error> {
            do { return .success(try await tools.run(call.name, arguments: call.arguments)) } catch { return .failure(error) }
        }
        var results: [Result<ToolOutput, Error>]
        if calls.count == 1 {
            results = [await attempt(calls[0])]
        } else {
            results = await withTaskGroup(of: (Int, Result<ToolOutput, Error>).self) { group in
                for (i, call) in calls.enumerated() { group.addTask { (i, await attempt(call)) } }
                var done: [Int: Result<ToolOutput, Error>] = [:]
                for await (i, result) in group { done[i] = result }
                return calls.indices.map { done[$0]! }
            }
        }
        try Task.checkCancellation()
        for case .failure(let error) in results where error is CancellationError { throw CancellationError() }
        return results
    }

    /// Whether a try already showed some of the answer: a retry would show it twice.
    private actor Shown {
        private(set) var any = false
        func mark() { any = true }
    }

    /// One model request, every one the loop makes: bounded in time and retried when the network
    /// hiccups (unless the answer already started streaming in).
    private func ask(_ messages: [ModelMessage], tools: [ModelTool], stream: Bool,
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
