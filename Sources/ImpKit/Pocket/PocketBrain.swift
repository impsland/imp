import Foundation

/// What a pocket Imp can reach besides its own thinking. The app provides it for each ask.
public struct PocketTalk: Sendable {
    /// The names of the Imps it may message (other pocket Imps, and Imps on the Mac when connected).
    public var others: [String]
    /// Delivers a message to the Imp called `to` and returns its answer. Throws why it couldn't.
    public var send: (@Sendable (_ to: String, _ text: String) async throws -> String)?
    /// The animations it may play, by name.
    public var animations: [String]
    /// Plays animations, in order (at most four at a time).
    public var play: (@Sendable (_ names: [String]) async -> Void)?

    public init(others: [String] = [], send: (@Sendable (String, String) async throws -> String)? = nil,
                animations: [String] = [], play: (@Sendable ([String]) async -> Void)? = nil) {
        self.others = others; self.send = send; self.animations = animations; self.play = play
    }
}

/// How one ask came out: the turn for the chat and what the Imp now remembers of it.
public struct PocketAnswer: Sendable, Equatable {
    public var turn: ChatTurn
    /// Nil when it failed (nothing is remembered of a failed turn).
    public var memory: ChatMemory?
    /// The Imp it was talking with, when another Imp asked (`PocketImp.record` files it in a chat of its own).
    public var peer: UUID?

    public var linkTurn: LinkTurn { LinkTurn(turn) }
}

/// Runs one ask for a pocket Imp: its service (streaming), its HTTP tool servers and the two tools
/// of its own, `imp_message` and `imp_play_animations`. Needs nothing from the Mac.
public struct PocketBrain: Sendable {
    public let secrets: PocketSecrets
    private let session: URLSession

    public init(secrets: PocketSecrets, session: URLSession = .shared) {
        self.secrets = secrets; self.session = session
    }

    /// Asks `imp` something and returns the finished turn. `sender` is the Imp that asked, if one did
    /// (not you): its turn is filed in a chat of its own and the Imp doesn't get to message anyone
    /// back (two Imps can't keep messaging each other forever). `onWork` hears what it's doing as it
    /// goes and, at the end, nil. A service that fails gives a failed turn. Cancelling the task (the
    /// stop button) throws `CancellationError`, and nothing is kept.
    public func ask(_ text: String, of imp: PocketImp, from sender: ChatTurn.Sender? = nil, talk: PocketTalk = PocketTalk(),
                    onWork: @escaping @Sendable (LinkWork?) async -> Void = { _ in }) async throws -> PocketAnswer {
        let hub = MCPHub()
        let run = Run(request: text, from: sender?.name, onWork: onWork)
        let outcome: Result<(reply: String, memory: ChatMemory), Error>
        do {
            try imp.validate()
            let configs = imp.servers.map { server in
                var config = MCPServerConfig(name: server.name, transport: .http, url: server.url)
                config.id = server.id
                if let header = server.header, let value = secrets.get(.header(server.id), imp: imp.id), !value.isEmpty {
                    config.headers = [header: value]
                }
                return config
            }
            await hub.update(configs)
            var tools: [ToolProvider] = []
            if !configs.isEmpty { tools.append(hub) }
            tools.append(PocketTools(talk: sender == nil ? talk : PocketTalk(animations: talk.animations, play: talk.play)))
            let client = try OpenAIClient(baseURL: imp.brain.baseURL, apiKey: secrets.get(.apiKey, imp: imp.id) ?? "", session: session)
            let agent = Agent(client: client, model: imp.brain.model, tools: ToolSet(tools))
            let turn = sender.map { Briefing.message(from: $0.name, text, place: "in the user's troupe") } ?? .user(text)
            let memory = imp.memory(with: sender?.id)
            let system = [imp.personality, Briefing.pocket].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }.joined(separator: "\n\n")
            let context = memory.context(system: system, turn: turn, exchanges: PocketImp.exchangesSent)
            await run.start()
            let (reply, transcript) = try await agent.run(context, stream: true) { await run.hear($0) }
            var remembered = memory
            remembered.remember(Array(transcript.dropFirst(context.count - 1)))
            outcome = .success((reply, remembered))
        } catch {
            outcome = .failure(error)
        }
        await hub.update([])
        await onWork(nil)
        switch outcome {
        case .success(let (reply, memory)):
            let turn = ChatTurn(request: text, reply: reply, steps: await run.steps, via: sender == nil ? .typed : .imp, sender: sender)
            return PocketAnswer(turn: turn, memory: memory, peer: sender?.id)
        case .failure(let error):
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            let turn = ChatTurn(request: text, reply: error.localizedDescription, failed: true, steps: await run.steps,
                                via: sender == nil ? .typed : .imp, sender: sender)
            return PocketAnswer(turn: turn, memory: nil, peer: sender?.id)
        }
    }

    /// What the Imp is doing, gathered from the agent's events.
    private actor Run {
        let request: String
        let from: String?
        let onWork: @Sendable (LinkWork?) async -> Void
        private(set) var steps: [ChatTurn.Step] = []
        private var partial = ""

        init(request: String, from: String?, onWork: @escaping @Sendable (LinkWork?) async -> Void) {
            self.request = request; self.from = from; self.onWork = onWork
        }

        func start() async { await report() }

        func hear(_ event: AgentEvent) async {
            switch event {
            case .text(let text):
                partial = text
            case .toolStarted(let name, let arguments):
                let label = ToolLabel(tool: name, arguments: arguments)
                steps.append(ChatTurn.Step(icon: label.icon, title: label.title, request: label.request, response: nil, failed: false))
                partial = ""
            case .toolFinished(_, let ok, let result):
                if let i = steps.lastIndex(where: { $0.response == nil }) {
                    steps[i].response = result
                    steps[i].failed = !ok
                }
            }
            await report()
        }

        private func report() async {
            let status = steps.last { $0.response == nil }?.title
            await onWork(LinkWork(request: request, status: status, partial: partial, from: from))
        }
    }
}

/// A pocket Imp's own tools.
struct PocketTools: ToolProvider {
    let talk: PocketTalk

    func tools() async -> [ToolSpec] {
        var specs: [ToolSpec] = []
        if talk.play != nil, !talk.animations.isEmpty { specs.append(OwnTools.playSpec(animations: talk.animations)) }
        if talk.send != nil, !talk.others.isEmpty {
            var spec = OwnTools.messageSpec(imps: talk.others)
            spec.description = "Send a message to another of the user's Imps (on their Mac or in their pocket) and get its answer. Keep it short and friendly."
            specs.append(spec)
        }
        return specs
    }

    func call(_ name: String, arguments: String) async throws -> String {
        let args = (try? JSONValue(jsonString: arguments.isEmpty ? "{}" : arguments)) ?? [:]
        switch name {
        case OwnTools.play:
            let names = args["names"]?.array?.compactMap(\.string) ?? args["name"]?.string.map { [$0] } ?? []
            guard let play = talk.play, !names.isEmpty else { throw ToolArgumentError("Name the animations in `names`.") }
            let known = names.prefix(4).compactMap { wanted in
                talk.animations.first { $0.caseInsensitiveCompare(wanted.trimmingCharacters(in: .whitespacesAndNewlines)) == .orderedSame }
            }
            guard !known.isEmpty else { throw ToolArgumentError("None of those can play: \(names.joined(separator: ", ")).") }
            await play(known)
            return "Playing: \(known.joined(separator: ", "))."
        case OwnTools.message:
            guard let to = args["to"]?.string, let text = args["text"]?.string, !text.isEmpty else {
                throw ToolArgumentError("Say who `to` and the `text`.")
            }
            guard let send = talk.send, let other = talk.others.first(where: { $0.caseInsensitiveCompare(to) == .orderedSame }) else {
                throw ToolArgumentError("\(to) isn't somewhere you can reach.")
            }
            return "\(other) says: \(try await send(other, text))"
        default:
            throw ToolArgumentError("Unknown tool \(name).")
        }
    }
}
