import Foundation
import Testing
@testable import ImpKit

/// Keeps secrets in memory, for tests only.
final class MemorySecrets: PocketSecrets, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]
    func get(_ slot: PocketSlot, imp: UUID) -> String? { lock.withLock { values[slot.account(imp: imp)] } }
    func set(_ value: String, _ slot: PocketSlot, imp: UUID) { lock.withLock { values[slot.account(imp: imp)] = value } }
    func remove(_ slot: PocketSlot, imp: UUID) { lock.withLock { values[slot.account(imp: imp)] = nil } }
}

private func pocketImp(chats: [Chat] = []) -> (PocketImp, MemorySecrets) {
    let notes = PocketServer(name: "Notes", url: "https://notes.example.com/mcp", header: "Authorization")
    let imp = PocketImp(name: "Pocket Pip", hue: 0.4, scale: 1.2, traits: ImpTraits(lids: 0.3),
                        personality: "You are Pip, sly and brief.",
                        brain: PocketService(baseURL: "https://llm.example.com/v1", model: "tiny-1"),
                        servers: [notes], chats: chats)
    let secrets = MemorySecrets()
    secrets.set("sk-very-secret", .apiKey, imp: imp.id)
    secrets.set("Bearer header-secret", .header(notes.id), imp: imp.id)
    return (imp, secrets)
}

private func chat(_ turns: Int, size: Int = 40, title: String = "Chat") -> Chat {
    let filler = String(repeating: "x", count: size)
    let list = (0..<turns).map { ChatTurn(date: Date(timeIntervalSince1970: 1_700_000_000 + Double($0)), request: "q\($0) \(filler)", reply: "a\($0) \(filler)") }
    let memory = ChatMemory(messages: (0..<turns).flatMap { [ChatMessage.user("q\($0) \(filler)"), ChatMessage.assistant("a\($0) \(filler)")] })
    return Chat(title: title, turns: list, memory: memory)
}

@Suite struct PocketImpTests {
    @Test func httpsAnywhereAndHttpOnlyOnYourNetwork() throws {
        for ok in ["https://api.openai.com/v1", "http://localhost:11434/v1", "http://mac.local:8080", "http://10.1.2.3/mcp",
                   "http://172.16.0.9/x", "http://172.31.255.1", "http://192.168.1.20:1234/v1", "http://127.0.0.1:9"] {
            try PocketImp.check(url: ok)
        }
        for bad in ["http://api.openai.com/v1", "http://172.32.0.1", "http://172.15.0.1", "http://192.169.0.1", "http://11.0.0.1",
                    "http://10.0.0.256", "http://evil.local.example.com", "ftp://x.local", "file:///etc/passwd", "https://", "nope", "",
                    "https://user:pw@example.com", "https://example.com/mcp?key=abc", "https://example.com/#x"] {
            #expect(throws: PocketError.self, "\(bad)") { try PocketImp.check(url: bad) }
        }
    }

    @Test func nameAndBrainAreChecked() throws {
        var (imp, _) = pocketImp()
        try imp.validate()
        imp.name = "  "
        #expect(throws: PocketError.badName) { try imp.validate() }
        imp.name = String(repeating: "n", count: 41)
        #expect(throws: PocketError.badName) { try imp.validate() }
        imp.name = String(repeating: "n", count: 40)
        try imp.validate()
        imp.brain.model = ""
        #expect(throws: PocketError.noBrain) { try imp.validate() }
        imp.brain = PocketService(baseURL: "http://example.com", model: "m")
        #expect(throws: PocketError.self) { try imp.validate() }
        imp.brain = PocketService(baseURL: "https://example.com", model: "m")
        imp.servers[0].url = "http://example.com/mcp"
        #expect(throws: PocketError.self) { try imp.validate() }
    }

    @Test func isCodableAndHoldsNoSecrets() throws {
        let (imp, _) = pocketImp(chats: [chat(2)])
        let data = try JSONEncoder().encode(imp)
        #expect(try JSONDecoder().decode(PocketImp.self, from: data) == imp)
        let text = String(decoding: data, as: UTF8.self)
        #expect(!text.contains("secret"))
    }

    @Test func recordsTurnsIntoChatsAndKeepsPeersApart() {
        var (imp, _) = pocketImp()
        #expect(imp.current == nil)
        let first = PocketAnswer(turn: ChatTurn(request: "hi", reply: "hello"), memory: ChatMemory(messages: [.user("hi"), .assistant("hello")]), peer: nil)
        imp.record(first)
        let peer = UUID()
        imp.record(PocketAnswer(turn: ChatTurn(request: "psst", reply: "ok", via: .imp, sender: .init(id: peer, name: "Mo", hue: 0.2)),
                                memory: nil, peer: peer))
        #expect(imp.chats.count == 2)
        #expect(imp.current?.title == "hi")
        #expect(imp.turns().map(\.request) == ["hi"])
        #expect(imp.memory(with: nil).messages.count == 2)
        imp.newChat()
        imp.newChat()
        #expect(imp.chats.count == 3)
        #expect(imp.turns().isEmpty)
        for i in 0..<(PocketImp.maxTurns + 5) { imp.record(PocketAnswer(turn: ChatTurn(request: "q\(i)"), memory: nil, peer: nil)) }
        #expect(imp.current?.turns.count == PocketImp.maxTurns)
        #expect(imp.current?.turns.last?.request == "q\(PocketImp.maxTurns + 4)")
    }
}

@Suite struct PocketHandoverTests {
    private func adopt(_ request: LinkRequest) throws -> (kit: String, secrets: LinkSecrets) {
        guard case .adopt(_, let kit, let secrets, _, _, _) = request else { throw PocketError.notOnePocketImp }
        return (kit, secrets)
    }

    @Test func kitHoldsTheImpAndItsChatsButNoSecrets() throws {
        let (imp, store) = pocketImp(chats: [chat(3, title: "Old"), chat(2, title: "New")])
        let request = try imp.adoption(secrets: store, exit: .left, height: 0.3, speed: 900)
        let (kit, secrets) = try adopt(request)
        #expect(!kit.contains("sk-very-secret"))
        #expect(!kit.contains("header-secret"))
        #expect(secrets.apiKey == "sk-very-secret")
        #expect(secrets.headers == ["Notes": ["Authorization": "Bearer header-secret"]])

        let parsed = try Kit.parse(kit, limit: LinkProtocol.maxFrame)
        let read = try #require(parsed.imps.first)
        #expect(parsed.imps.count == 1)
        #expect(read.name == "Pocket Pip")
        #expect(read.personality == "You are Pip, sly and brief.")
        #expect(read.traits == imp.traits)
        #expect(read.scale == 1.2)
        #expect(read.brain == KitBrain(model: "tiny-1", serviceName: "llm.example.com", baseURL: "https://llm.example.com/v1"))
        #expect(read.chats.map(\.title).sorted() == ["New", "Old"])
        #expect(read.chats.first { $0.title == "Old" }?.turns.map(\.request).first?.hasPrefix("q0") == true)
        #expect(read.chats.first { $0.title == "Old" }?.memory.messages.count == 6)
        #expect(parsed.servers.map(\.url) == ["https://notes.example.com/mcp"])
        #expect(parsed.servers.first?.headers == ["Authorization": ""])
    }

    @Test func aMacTakesItInAsAnOrdinaryImpWithItsId() throws {
        let (imp, store) = pocketImp(chats: [chat(2)])
        let (kit, secrets) = try adopt(imp.adoption(secrets: store, exit: .right, height: 0.5, speed: 0))
        var prefs = ImpPreferences()
        prefs.imps = [ImpProfile.imp, ImpProfile(name: "Pocket Pip", hue: 0.1, favoriteHue: 0.6, personality: "x")]
        let adoption = try prefs.adopt(kit: kit, as: imp.id, secrets: secrets)

        let profile = try #require(prefs.imps.first { $0.id == imp.id })
        #expect(adoption.imp.id == imp.id)
        #expect(profile.name == "Pocket Pip 2")
        #expect(profile.hue == 0.4 && profile.scale == 1.2 && profile.traits == imp.traits)
        #expect(profile.personality == imp.personality)
        #expect(!profile.isActive)
        #expect(adoption.imp.chats.count == 1 && adoption.imp.chats[0].turns.count == 2)
        #expect(adoption.apiKey == "sk-very-secret")

        let service = try #require(prefs.ai.service(atAddress: "https://llm.example.com/v1"))
        #expect(adoption.service == service.id)
        #expect(profile.brain == Brain(service: service.id, model: ""))
        #expect(service.model == "tiny-1")
        let server = try #require(prefs.mcpServers.first)
        #expect(server.transport == .http && server.headers == ["Authorization": "Bearer header-secret"])
        #expect(profile.servers == [server.id])
        #expect(!(try JSONEncoder().encode(prefs.ai)).contains(Data("sk-very".utf8)))
    }

    @Test func anImpWithNoBrainMovesAndFollowsTheMacsDefault() throws {
        var (imp, store) = pocketImp()
        imp.brain = PocketService()
        #expect(throws: PocketError.noBrain) { try imp.validate() }
        let (kit, secrets) = try adopt(imp.adoption(secrets: store, exit: .left, height: 0.5, speed: 0))
        #expect(secrets.apiKey == nil)                  // a key without a service goes nowhere
        #expect(try Kit.parse(kit, limit: LinkProtocol.maxFrame).imps.first?.brain == nil)
        var prefs = ImpPreferences()
        let mine = Service(name: "Mine", baseURL: "https://mine.example/v1", model: "m")
        prefs.ai.add(mine)
        let adoption = try prefs.adopt(kit: kit, as: imp.id, secrets: secrets)
        #expect(prefs.ai.services == [mine])
        #expect(adoption.service == nil && adoption.apiKey == nil)
        let profile = try #require(prefs.imps.first { $0.id == imp.id })
        #expect(prefs.ai.service(in: profile.brain)?.id == mine.id)
    }

    @Test func aModelWithoutAnAddressDoesNotMove() throws {
        var (imp, store) = pocketImp()
        imp.brain = PocketService(baseURL: " ", model: "phone-model")
        #expect(throws: PocketError.noBrain) { try imp.validate() }
        let (kit, _) = try adopt(imp.adoption(secrets: store, exit: .left, height: 0.5, speed: 0))
        #expect(try Kit.parse(kit, limit: LinkProtocol.maxFrame).imps.first?.brain == nil)
    }

    @Test func aServiceMovesUnderItsOwnName() throws {
        var (imp, store) = pocketImp()
        imp.brain = PocketService(baseURL: "https://openrouter.ai/api/v1", model: "openai/gpt-6-luna")
        var (kit, secrets) = try adopt(imp.adoption(secrets: store, exit: .left, height: 0.5, speed: 0))
        var prefs = ImpPreferences()
        _ = try prefs.adopt(kit: kit, as: imp.id, secrets: secrets)
        #expect(prefs.ai.services.map(\.name) == ["OpenRouter"])
        imp.id = UUID()
        imp.brain = PocketService(baseURL: "http://studio.local:1234/v1", model: "qwen", name: "Studio")
        (kit, secrets) = try adopt(imp.adoption(secrets: store, exit: .left, height: 0.5, speed: 0))
        _ = try prefs.adopt(kit: kit, as: imp.id, secrets: secrets)
        #expect(prefs.ai.services.map(\.name) == ["OpenRouter", "Studio"])
    }

    @Test func olderPocketImpsLoadWithoutAServiceName() throws {
        let old = #"{"baseURL":"https://x.example/v1","model":"m"}"#
        let service = try JSONDecoder().decode(PocketService.self, from: Data(old.utf8))
        #expect(service.name == nil && service.label == "x.example")
        #expect(PocketService().isEmpty && !service.isEmpty)
    }

    @Test func reusesServicesAndServersTheMacHas() throws {
        let (imp, store) = pocketImp()
        let (kit, secrets) = try adopt(imp.adoption(secrets: store, exit: .left, height: 0, speed: 0))
        var prefs = ImpPreferences()
        let mine = Service(name: "Mine", baseURL: "https://LLM.example.com/v1/", model: "big")
        prefs.ai.add(mine)
        let library = MCPServerConfig(name: "Notes (mine)", transport: .http, url: "https://notes.example.com/mcp", headers: ["Authorization": "mine"])
        prefs.mcpServers = [library]
        let adoption = try prefs.adopt(kit: kit, as: imp.id, secrets: secrets)
        #expect(prefs.ai.services == [mine])
        #expect(adoption.service == mine.id)
        #expect(prefs.imps.first { $0.id == imp.id }?.brain == Brain(service: mine.id, model: "tiny-1"))
        #expect(prefs.mcpServers == [library])
        #expect(prefs.imps.first { $0.id == imp.id }?.servers == [library.id])
    }

    @Test func refusesWhatIsNotOnePocketImp() throws {
        let (imp, store) = pocketImp()
        let (kit, secrets) = try adopt(imp.adoption(secrets: store, exit: .left, height: 0, speed: 0))
        var prefs = ImpPreferences()
        prefs.imps = [ImpProfile(id: imp.id, name: "Other", hue: 0.1, favoriteHue: 0.6, personality: "")]
        #expect(throws: PocketError.alreadyHere) { try prefs.adopt(kit: kit, as: imp.id, secrets: secrets) }
        prefs.imps = []
        #expect(throws: PocketError.self) { try prefs.adopt(kit: #"{"imp":2,"imps":[{"name":"A"},{"name":"B"}]}"#, as: UUID(), secrets: LinkSecrets()) }
        #expect(throws: PocketError.self) {
            try prefs.adopt(kit: #"{"imp":2,"imps":[{"name":"A","mcpServers":["x"]}],"mcpServers":{"x":{"command":"rm","args":["-rf","/"]}}}"#,
                            as: UUID(), secrets: LinkSecrets())
        }
        #expect(throws: PocketError.self) {
            try prefs.adopt(kit: #"{"imp":2,"imps":[{"name":"A","brain":{"service":{"baseURL":"http://example.com/v1"}}}]}"#,
                            as: UUID(), secrets: LinkSecrets())
        }
        #expect(prefs.imps.isEmpty && prefs.mcpServers.isEmpty)
    }

    @Test func anythingBeyondAPocketImpIsIgnored() throws {
        let kit = #"{"imp":3,"imps":[{"name":"A","tools":{"computer":true,"den":true},"shell":true,"instructions":"hack","exchangesSent":1,"triggers":[{"name":"t","when":{"kind":"start"}}],"animations":[{"name":"wave","beats":[{"duration":1}]}]}]}"#
        var prefs = ImpPreferences()
        let stock = prefs.shortcuts
        let id = UUID()
        let adoption = try prefs.adopt(kit: kit, as: id, secrets: LinkSecrets(apiKey: "  "))
        #expect(adoption.apiKey == nil)
        let profile = try #require(prefs.imps.first)
        #expect(!profile.uses(.computer) && !profile.uses(.den))
        #expect(profile.instructions == nil && profile.exchangesSent == nil)
        #expect(prefs.shortcuts == stock && profile.animations.isEmpty)
    }

    @Test func dropsTheOldestChatsToFitAFrame() throws {
        // Three chats of about 2 MB each: only the newest can travel.
        let big = (0..<3).map { chat(20, size: 40_000, title: "Chat \($0)") }
        let (imp, store) = pocketImp(chats: big)
        let request = try imp.adoption(secrets: store, exit: .left, height: 0, speed: 0)
        #expect(try LinkFrame.encode(request).count <= LinkProtocol.maxFrame + 4)
        let (kit, _) = try adopt(request)
        let titles = try Kit.parse(kit, limit: LinkProtocol.maxFrame).imps[0].chats.map(\.title)
        #expect(titles.last == "Chat 2")
        #expect(!titles.contains("Chat 0"))
    }

    @Test func halvesAHugeChatThatStandsAlone() throws {
        let (imp, store) = pocketImp(chats: [chat(60, size: 60_000)])
        let request = try imp.adoption(secrets: store, exit: .left, height: 0, speed: 0)
        let (kit, _) = try adopt(request)
        let chat = try #require(Kit.parse(kit, limit: LinkProtocol.maxFrame).imps[0].chats.first)
        #expect(chat.turns.count < 60 && chat.turns.last?.request.hasPrefix("q59") == true)
    }

    @Test func linkMessagesRoundTrip() throws {
        let imp = LinkImp(id: UUID(), name: "Pip", hue: 0.3, scale: 1, traits: .plain)
        let id = UUID()
        let secrets = LinkSecrets(apiKey: "k", headers: ["Notes": ["Authorization": "v"]])
        for r: LinkRequest in [.troupe([imp]), .troupe([]),
                               .adopt(imp: id, kit: #"{"imp":2}"#, secrets: secrets, exit: .right, height: 0.4, speed: 1200),
                               .adopt(imp: id, kit: "", secrets: LinkSecrets(), exit: .left, height: 0, speed: 0),
                               .message(id: id, from: imp.id, to: UUID(), text: "hello 🧡"),
                               .answered(id: id, text: "nope", failed: true)] {
            var framer = LinkFrame()
            let body = try #require(try framer.feed(LinkFrame.encode(r)).first)
            #expect(LinkFrame.decode(LinkRequest.self, body) == r)
        }
        for u: LinkUpdate in [.adopted(imp: id), .answer(id: id, text: "hi", failed: false), .answer(id: id, text: "busy", failed: true),
                              .ask(id: id, from: imp, to: UUID(), text: "ping"), .refused(imp: id, reason: "no")] {
            var framer = LinkFrame()
            let body = try #require(try framer.feed(LinkFrame.encode(u)).first)
            #expect(LinkFrame.decode(LinkUpdate.self, body) == u)
        }
    }
}

// MARK: - The brain

/// Serves canned chat-completions replies and keeps the request bodies. A body of "hang" never answers.
final class PocketStub: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var replies: [String] = []
    nonisolated(unsafe) static var bodies: [[String: Any]] = []
    nonisolated(unsafe) static var auth: [String?] = []
    static let lock = NSLock()

    static func reset(_ replies: [String]) {
        lock.withLock { self.replies = replies; bodies = []; auth = [] }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var data = Data()
        if let stream = request.httpBodyStream {
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let n = stream.read(&buffer, maxLength: buffer.count)
                if n <= 0 { break }
                data.append(buffer, count: n)
            }
            stream.close()
        }
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let body = Self.lock.withLock { () -> String in
            Self.bodies.append(json)
            Self.auth.append(request.value(forHTTPHeaderField: "Authorization"))
            return Self.replies.isEmpty ? "{}" : Self.replies.removeFirst()
        }
        if body == "hang" { return }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private actor WorkLog {
    private(set) var all: [LinkWork?] = []
    func add(_ work: LinkWork?) { all.append(work) }
}

private actor Sent {
    private(set) var messages: [[String]] = []
    private(set) var played: [[String]] = []
    func message(_ to: String, _ text: String) { messages.append([to, text]) }
    func play(_ names: [String]) { played.append(names) }
}

@Suite(.serialized) struct PocketBrainTests {
    private func brain(_ store: MemorySecrets, replies: [String]) -> PocketBrain {
        PocketStub.reset(replies)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [PocketStub.self]
        return PocketBrain(secrets: store, session: URLSession(configuration: config))
    }

    private func toolCall(_ name: String, _ arguments: String) -> String {
        let escaped = arguments.replacingOccurrences(of: "\"", with: "\\\"")
        return #"{"choices":[{"message":{"content":null,"tool_calls":[{"id":"c1","type":"function","function":{"name":"\#(name)","arguments":"\#(escaped)"}}]}}]}"#
    }
    private func text(_ s: String) -> String { #"{"choices":[{"message":{"content":"\#(s)"}}]}"# }
    private func toolNames(_ body: [String: Any]) -> [String] {
        ((body["tools"] as? [[String: Any]]) ?? []).compactMap { ($0["function"] as? [String: Any])?["name"] as? String }
    }

    @Test func answersAndRemembers() async throws {
        let (imp, store) = pocketImp()
        let b = brain(store, replies: [text("Hi there!"), text("Again!")])
        let log = WorkLog()
        let answer = try await b.ask("Hello", of: imp) { await log.add($0) }
        #expect(answer.turn.reply == "Hi there!" && !answer.turn.failed && answer.turn.via == .typed)
        #expect(answer.linkTurn.reply == "Hi there!")
        #expect(await log.all.last! == nil)
        #expect(await log.all.first! != nil)
        #expect(PocketStub.auth.first == "Bearer sk-very-secret")
        let system = try #require((PocketStub.bodies[0]["messages"] as? [[String: Any]])?.first?["content"] as? String)
        #expect(system.contains("sly and brief") && system.contains("iPhone"))

        var imp2 = imp
        imp2.record(answer)
        _ = try await b.ask("And?", of: imp2)
        let roles = (PocketStub.bodies[1]["messages"] as? [[String: Any]])?.compactMap { $0["role"] as? String }
        #expect(roles == ["system", "user", "assistant", "user"])
    }

    @Test func callsImpMessageAndPlaysAnimations() async throws {
        let (imp, store) = pocketImp()
        let b = brain(store, replies: [toolCall("imp_message", #"{"to":"mo","text":"how are you?"}"#),
                                       toolCall("imp_play_animations", #"{"names":["smile","bogus"]}"#),
                                       text("Mo is fine.")])
        let sent = Sent()
        let talk = PocketTalk(others: ["Mo", "Lu"], send: { to, text in await sent.message(to, text); return "all good" },
                              animations: ["smile", "wow"], play: { await sent.play($0) })
        let log = WorkLog()
        let answer = try await b.ask("Check on Mo", of: imp, talk: talk) { await log.add($0) }
        #expect(answer.turn.reply == "Mo is fine.")
        #expect(await sent.messages == [["Mo", "how are you?"]])
        #expect(await sent.played == [["smile"]])
        #expect(answer.turn.steps.count == 2)
        #expect(answer.turn.steps[0].response == "Mo says: all good" && !answer.turn.steps[0].failed)
        #expect(Set(toolNames(PocketStub.bodies[0])) == ["imp_message", "imp_play_animations"])
        #expect(await log.all.compactMap { $0?.status }.contains(answer.turn.steps[0].title))
        #expect(answer.memory?.messages.map(\.role) == ["user", "assistant", "tool", "assistant", "tool", "assistant"])
    }

    @Test func unknownImpsAndFailedSendsComeBackAsToolErrors() async throws {
        let (imp, store) = pocketImp()
        let b = brain(store, replies: [toolCall("imp_message", #"{"to":"Zed","text":"hi"}"#),
                                       toolCall("imp_message", #"{"to":"Mo","text":"hi"}"#), text("Couldn't reach them.")])
        struct Down: LocalizedError { var errorDescription: String? { "Mo's iPhone went away." } }
        let talk = PocketTalk(others: ["Mo"], send: { _, _ in throw Down() })
        let answer = try await b.ask("Hi", of: imp, talk: talk)
        #expect(answer.turn.steps.map(\.failed) == [true, true])
        #expect(answer.turn.steps[1].response == "Error: Mo's iPhone went away.")
        #expect(!answer.turn.failed)
    }

    @Test func anImpAnsweringAnotherDoesNotGetToMessage() async throws {
        let (imp, store) = pocketImp()
        let b = brain(store, replies: [text("Fine, thanks.")])
        let peer = ChatTurn.Sender(id: UUID(), name: "Mo", hue: 0.7)
        let talk = PocketTalk(others: ["Mo"], send: { _, _ in "x" }, animations: ["smile"], play: { _ in })
        var imp2 = imp
        let answer = try await b.ask("How are you?", of: imp2, from: peer, talk: talk)
        #expect(toolNames(PocketStub.bodies[0]) == ["imp_play_animations"])
        let user = (PocketStub.bodies[0]["messages"] as? [[String: Any]])?.last?["content"] as? String
        #expect(user?.contains("Message from Mo") == true)
        #expect(answer.turn.via == .imp && answer.turn.sender == peer && answer.peer == peer.id)
        imp2.record(answer)
        #expect(imp2.current == nil && imp2.chats.first?.peer == peer.id)
        #expect(imp2.turns().isEmpty)
    }

    @Test func failuresBecomeFailedTurns() async throws {
        var (imp, store) = pocketImp()
        let b = brain(store, replies: [#"{"error":{"message":"bad key","code":401}}"#])
        let answer = try await b.ask("Hi", of: imp)
        #expect(answer.turn.failed && answer.memory == nil)
        #expect(!answer.turn.reply.isEmpty)
        imp.brain.baseURL = "http://example.com/v1"
        let refused = try await b.ask("Hi", of: imp)
        #expect(refused.turn.failed)
    }

    @Test func stopCancels() async throws {
        let (imp, store) = pocketImp()
        let b = brain(store, replies: ["hang"])
        let log = WorkLog()
        let task = Task { try await b.ask("Hi", of: imp) { await log.add($0) } }
        try await Task.sleep(for: .milliseconds(300))
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await log.all.last! == nil)
    }
}
