import Foundation
#if os(iOS)
import UIKit
#endif
import ImpCore

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
    /// What each of `others` says it is good at, for the message tool's description.
    public var profiles: [ImpCore.TroupeTargetProfile]
    /// Sends a message without waiting: returns the receipt at once, the answer comes later as a turn of its own.
    /// Nil: every message waits.
    public var later: (@Sendable (_ to: String, _ text: String) async throws -> String)?
    /// The page behind the Imps in the room: reads it, and sets it (nil: the plain one). Nil: no background tools.
    public var background: Background?

    public struct Background: Sendable {
        public var read: @Sendable () async -> String
        public var write: @Sendable (_ html: String?) async -> Void
        public init(read: @escaping @Sendable () async -> String, write: @escaping @Sendable (String?) async -> Void) {
            self.read = read; self.write = write
        }
    }

    public init(others: [String] = [], send: (@Sendable (String, String) async throws -> String)? = nil,
                animations: [String] = [], play: (@Sendable ([String]) async -> Void)? = nil,
                profiles: [ImpCore.TroupeTargetProfile] = [], later: (@Sendable (String, String) async throws -> String)? = nil,
                background: Background? = nil) {
        self.others = others; self.send = send; self.animations = animations; self.play = play
        self.profiles = profiles; self.later = later; self.background = background
    }
}

/// How one ask came out: the turn for the chat and what the Imp now remembers of it.
public struct PocketAnswer: Sendable, Equatable {
    public var turn: ChatTurn
    /// Nil when it failed (nothing is remembered of a failed turn).
    public var memory: ChatMemory?
    /// The Imp it was talking with, when another Imp asked (`PocketImp.record` files it in a chat of its own).
    public var peer: UUID?

    public var linkTurn: LinkTurn { LinkTurn(local: turn) }
}

/// Runs one ask for a pocket Imp: its service (streaming), its HTTP tool servers and the two tools
/// of its own, `imp_message` and `imp_play_animations`. Needs nothing from the Mac.
public struct PocketBrain: Sendable {
    public let secrets: PocketSecrets
    private let session: URLSession
    /// How long a request may take and how it is retried.
    public let limits: RequestLimits

    public init(secrets: PocketSecrets, session: URLSession = .shared, limits: RequestLimits = .standard) {
        self.secrets = secrets; self.session = session; self.limits = limits
    }

    /// What a server's sign-in stand-in tool does here. A request can arrive while nobody is looking at
    /// the phone, so the sheet opens only when the app is in the foreground. Otherwise the model is told
    /// to ask the person to open Imp.
    static let signIn: (@Sendable (MCPServerConfig) async throws -> Void)? = {
        #if os(iOS)
        return { server in
            guard await MainActor.run(body: { UIApplication.shared.applicationState == .active }) else { throw MCPSignInError.notAttended }
            let presenter = await MainActor.run { WebAuthPresenter() }
            try await MCPSignIn(presenter: presenter).signIn(to: server.url.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        #else
        return nil
        #endif
    }()

    /// Asks `imp` something and returns the finished turn. `sender` is the Imp that asked, if one did
    /// (not you): its turn is filed in a chat of its own and the Imp doesn't get to message anyone
    /// back (two Imps can't keep messaging each other forever). `onWork` hears what it's doing as it
    /// goes and, at the end, nil. A service that fails gives a failed turn. Cancelling the task (the
    /// stop button) throws `CancellationError`, and nothing is kept. Without `tools` it is a plain
    /// conversation: no tool server is called and the Imp has no tools of its own (for a request that
    /// doesn't come from the owner's own device, see `docs/connecting/link.md`). `limitedTo` is that
    /// case with names: the device asking and this one. The Imp has no tools and is told why. `turnID`: the id the
    /// turn is filed under, the question's id when an Imp on another device asked (see `AskedTalks`).
    /// `answered`: this turn is the answer to a message the Imp sent without waiting. `event` is what the model
    /// reads, `text` what the chat shows, `from` the Imp that answered. It is filed in the chat with you.
    /// `library`: its skills are listed in the system text and read with `use_skill`. `how`: a custom command's
    /// front matter: the model for this message only (the model's name on the Imp's own service), and a subtask
    /// answers without the chat's memory and is not remembered.
    public func ask(_ text: String, of imp: PocketImp, from sender: ChatTurn.Sender? = nil, talk: PocketTalk = PocketTalk(), tools: Bool = true,
                    limitedTo stranger: (device: String, home: String)? = nil, turnID: UUID? = nil,
                    answered: (event: String, from: ChatTurn.Sender)? = nil, media: [MediaFile] = [],
                    library: AgentLibrary? = nil, how: CommandSettings? = nil,
                    onWork: @escaping @Sendable (LinkWork?) async -> Void = { _ in }) async throws -> PocketAnswer {
        let allowed = tools && stranger == nil
        let hub = MCPHub()
        let run = Run(request: text, from: sender?.name, onWork: onWork)
        let outcome: Result<(reply: String, memory: ChatMemory), Error>
        do {
            try imp.validate()
            let configs = (allowed ? imp.servers : []).map { server in
                var config = MCPServerConfig(name: server.name, transport: .http, url: server.url)
                config.id = server.id
                config.headers = secrets.headerValues(of: server, imp: imp.id)
                return config
            }
            await hub.setSignIn(Self.signIn)
            await hub.update(configs)
            var tools: [ToolProvider] = []
            if !configs.isEmpty { tools.append(hub) }
            if allowed { tools.append(PocketTools(talk: sender == nil ? talk : PocketTalk(animations: talk.animations, play: talk.play))) }
            // The skills, unless the Imp has `use_skill` switched off.
            let skills = allowed && !(imp.toolsOff ?? []).contains(ToolRegistry.ownID(.skills, tool: OwnTools.useSkill)) ? library : nil
            if let skillTools = skills?.skillTools { tools.append(skillTools) }
            let client = try OpenAIClient(baseURL: imp.brain.baseURL, apiKey: secrets.get(.apiKey, imp: imp.id) ?? "", session: session)
            let model = try how?.model.map { try modelRefParse(text: $0).model } ?? imp.brain.model
            let agent = Agent(client: client, model: model, tools: ToolSet(tools, selection: ToolSelection(toolsOff: Set(imp.toolsOff ?? []), text: imp.toolText ?? [:])), limits: limits)
            let turn = answered.map { .user($0.event) } ?? sender.map { Briefing.message(from: $0.name, text, place: "in the user's troupe") } ?? Briefing.message(text, media: media)
            let memory = how?.subtask == true ? ChatMemory() : imp.memory(with: sender?.id)
            let system = [imp.personality, Briefing.pocket, skills?.skillsPrompt ?? "", stranger.map { Briefing.untrusted(device: $0.device, home: $0.home) } ?? ""].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
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
            let turn = ChatTurn(id: turnID ?? UUID(), request: text, reply: reply, steps: await run.steps, via: answered != nil ? .answer : sender == nil ? .typed : .imp, sender: answered?.from ?? sender)
            return PocketAnswer(turn: turn, memory: how?.subtask == true ? nil : memory, peer: sender?.id)
        case .failure(let error):
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            let turn = ChatTurn(id: turnID ?? UUID(), request: text, reply: error.localizedDescription, failed: true, steps: await run.steps,
                                via: answered != nil ? .answer : sender == nil ? .typed : .imp, sender: answered?.from ?? sender)
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
        /// The model is thinking (its words stay here: a visiting Imp is told only that it thinks, and later how long).
        private var thinking = false
        private var reasoning = ""
        /// "Retrying 2 of 3" while a request is tried again.
        private var retry: String?

        init(request: String, from: String?, onWork: @escaping @Sendable (LinkWork?) async -> Void) {
            self.request = request; self.from = from; self.onWork = onWork
        }

        func start() async { await report() }

        func hear(_ event: AgentEvent) async {
            switch event {
            case .text(let text):
                partial = text
                retry = nil
            case .retrying(let notice):
                retry = notice.text
            case .reasoning(let text):
                thinking = true
                reasoning = text
                retry = nil
            case .thought(let thought, let seconds):
                thinking = false
                reasoning = ""
                steps.append(.thought(thought, seconds: seconds))
            case .toolStarted(let name, let arguments):
                let label = ToolLabel(tool: name, arguments: arguments)
                steps.append(ChatTurn.Step(icon: label.icon, title: label.title, request: label.request, response: nil, failed: false))
                partial = ""
                retry = nil
            case .toolFinished(_, let ok, let result):
                if let i = steps.lastIndex(where: { $0.response == nil }) {
                    steps[i].response = result
                    steps[i].failed = !ok
                }
            case .toolRefused(_, let reason):
                if let i = steps.lastIndex(where: { $0.response == nil }) {
                    steps[i].response = reason
                    steps[i].failed = true
                }
            }
            await report()
        }

        private func report() async {
            let status = retry ?? (thinking ? ChatTurn.Step.thinkingTitle : nil) ?? steps.last { $0.response == nil }?.title
            await onWork(LinkWork(request: request, status: status, partial: partial, from: from, reasoning: thinking ? reasoning : ""))
        }
    }
}

/// A pocket Imp's own tools.
struct PocketTools: ToolProvider {
    let talk: PocketTalk

    private static let place = "the room on the iPhone"

    func tools() async -> [ToolSpec] {
        var specs: [ToolSpec] = []
        if talk.play != nil, !talk.animations.isEmpty { specs.append(OwnTools.playSpec(animations: talk.animations)) }
        if talk.send != nil, !talk.others.isEmpty {
            specs.append(OwnTools.messageSpec(imps: talk.others, desktop: false, profiles: talk.profiles, waiting: .decides))
        }
        if talk.background != nil { specs.append(contentsOf: OwnTools.backgroundSpecs(where: Self.place)) }
        return specs
    }

    func catalog() async -> [CatalogTool] {
        let roster = talk.send != nil && !talk.others.isEmpty
            ? OwnTools.messageParts(imps: talk.others, desktop: false, profiles: talk.profiles, waiting: .decides).roster : ""
        return OwnTools.catalog(await tools(), animations: talk.animations, roster: roster, place: Self.place)
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
            // The phone has no setting for it: the Imp chooses with `wait` (`TalkWaiting.decides`).
            if !TalkWaiting.decides.waits(asked: args["wait"]?.bool), let later = talk.later { return try await later(other, text) }
            return "\(other) says: \(try await send(other, text))"
        case OwnTools.showBackground:
            guard let background = talk.background else { throw ToolArgumentError("Unknown tool \(name).") }
            return RoomBackground.shown(await background.read())
        case OwnTools.setBackground:
            guard let background = talk.background else { throw ToolArgumentError("Unknown tool \(name).") }
            if args["reset"]?.bool == true {
                await background.write(nil)
                return "The background is the plain one again."
            }
            let html = args["html"]?.string ?? ""
            if let problem = RoomBackground.problem(html) { throw ToolArgumentError(problem) }
            await background.write(html)
            return "The background is set: it shows behind every Imp in the room now."
        default:
            throw ToolArgumentError("Unknown tool \(name).")
        }
    }
}
