// Live API (opt-in): IMP_LIVE_TESTS=1 swift test --filter Live

import Foundation
import NaturalLanguage
import Testing
@testable import ImpKit

/// The live tests' endpoint, from `./.env` (`OPENAI_BASE_URL`, `OPENAI_API_KEY`, `OPENAI_MODEL`, all required).
enum LiveEnv {
    static var values: [String: String]? {
        guard ProcessInfo.processInfo.environment["IMP_LIVE_TESTS"] == "1" else { return nil }
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../.env")
        guard let s = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        var out: [String: String] = [:]
        for raw in s.split(whereSeparator: \.isNewline) {
            var line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#") || line.isEmpty { continue }
            if line.hasPrefix("export ") { line.removeFirst(7) }
            guard let eq = line.firstIndex(of: "=") else { continue }
            var value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if let hash = value.range(of: " #") { value = String(value[..<hash.lowerBound]).trimmingCharacters(in: .whitespaces) }
            value = value.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            out[line[..<eq].trimmingCharacters(in: .whitespaces)] = value
        }
        return out
    }
    static func client() throws -> (client: OpenAIClient, model: String, base: String, key: String) {
        let v = values ?? [:]
        let base = v["OPENAI_BASE_URL"] ?? "", key = v["OPENAI_API_KEY"] ?? ""
        return (try OpenAIClient(baseURL: base, apiKey: key), v["OPENAI_MODEL"] ?? "", base, key)
    }
}

@Suite(.enabled(if: LiveEnv.values != nil), .serialized) struct LiveTests {
    /// A clipboard shortcut as the model sees it: the instruction, then the copied text.
    @Test func shortcutBriefingIsFollowed() async throws {
        let live = try LiveEnv.client()
        let turn = Briefing.shortcut("Translate this into English. Reply with the translation only.", clip: .text("Привет, как дела?"))
        let en = try await live.client.chat(model: live.model, messages: [.system(Persona.imp), turn]).text
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(en)
        #expect(recognizer.dominantLanguage == .english, "got: \(en)")
    }

    /// The whole loop with a real model: it streams, and does the job with a real shell command.
    @Test func streamsAndUsesTheShell() async throws {
        let live = try LiveEnv.client()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("imp-live-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "42 imps live here".write(to: dir.appendingPathComponent("secret.txt"), atomically: true, encoding: .utf8)
        let env = ShellTool.environment(name: "Imp", directory: dir, baseURL: live.base, apiKey: live.key, model: live.model)
        let calls = LiveCalls()
        let agent = Agent(client: live.client, model: live.model, tools: ShellTool(directory: dir, environment: env, timeout: 20))
        let (reply, _) = try await agent.run([.system(Persona.imp), .user("How many imps live here, according to secret.txt in your folder?")],
                                             stream: true) { event in
            switch event {
            case .text: await calls.streamed()
            case .toolStarted(let name, _): await calls.used(name)
            case .toolFinished: break
            }
        }
        #expect(reply.contains("42"), "got: \(reply)")
        #expect(await calls.tools.contains(ShellTool.name))
        #expect(await calls.textEvents >= 1)
        print("live reply: \(reply) | tools: \(await calls.tools)")
    }
}

@Suite(.enabled(if: LiveEnv.values != nil), .serialized) struct LiveToolTests {
    /// The AI presets (dtst) start with their own address, key and model and list their tools.
    @Test(arguments: [("@dtst/img", "generate_image"), ("@dtst/txt", "generate_text"), ("@dtst/tts", "generate_speech")])
    func dtstServersStart(package: String, tool: String) async throws {
        let live = try LiveEnv.client()
        let server = MCPServerConfig(name: package, transport: .stdio, command: "npx", arguments: ["-y", package],
                                     environment: ["OPENAI_BASE_URL": live.base, "OPENAI_API_KEY": live.key, "OPENAI_MODEL": live.model])
        let status = await MCPHub().test(server)
        guard case .ready(_, let names) = status else { Issue.record("not ready: \(status)"); return }
        #expect(names.contains(tool), "tools: \(names)")
    }
}

private actor LiveCalls {
    var tools: [String] = []
    var textEvents = 0
    func used(_ name: String) { tools.append(name) }
    func streamed() { textEvents += 1 }
}

/// Chats with a real model: what it's sent of earlier turns, and recaps.
@Suite(.enabled(if: LiveEnv.values != nil), .serialized) struct LiveChatTests {
    /// The bug report's case: a tool made a file in an earlier turn. With tool calls in the chat,
    /// asking to show it again reuses the file instead of running the tool once more.
    @Test func remembersWhatToolsMadeAcrossTurns() async throws {
        let live = try LiveEnv.client()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("imp-live-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let env = ShellTool.environment(name: "Fizz", directory: dir, baseURL: live.base, apiKey: live.key, model: live.model)
        let agent = Agent(client: live.client, model: live.model, tools: ShellTool(directory: dir, environment: env, timeout: 20))
        var profile = ImpProfile(name: "Fizz", hue: 0, favoriteHue: 0.5, personality: Persona.newcomer(named: "Fizz"))
        profile.instructions = Briefing.display.replacingOccurrences(of: Briefing.workspaceToken, with: dir.path)
        var memory = ChatMemory()

        let first = Briefing.message("Create a text file with a short affirmation for me (pick any file name), using a command.")
        let (_, made) = try await agent.run(memory.context(system: profile.systemPrompt, turn: first))
        memory.remember(Array(made.dropFirst()))           // all but the system prompt
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { !$0.hasPrefix(".") }
        #expect(files.count == 1, "files: \(files)")
        #expect(memory.messages.contains { $0.role == "tool" }, "the tool call and result are remembered")

        let calls = LiveCalls()
        let second = Briefing.message("Which file did you save it in? Just tell me, don't run anything again.")
        let (reply, _) = try await agent.run(memory.context(system: profile.systemPrompt, turn: second)) { event in
            if case .toolStarted(let name, _) = event { await calls.used(name) }
        }
        #expect(files.first.map { reply.contains($0) } == true, "got: \(reply)")
        let reran = await calls.tools
        #expect(reran.isEmpty, "ran again: \(reran)")
        print("live tool memory: \(files) | \(reply)")
    }

    /// A long, real-world chat recapped: the facts survive, the chat carries on from the recap.
    @Test func recapKeepsWhatMattersAndTheChatCarriesOn() async throws {
        let live = try LiveEnv.client()
        let system = "You are Fizz, a helpful desk assistant. Reply briefly."
        var memory = ChatMemory()
        let chat: [(String, String)] = [
            ("Привет! Я планирую поездку в Лиссабон с 12 по 16 ноября, бюджет 900 евро.", "Отлично! Лиссабон в ноябре мягкий, около 17°C. Чем помочь?"),
            ("Я вегетарианка и не ем грибы. Посоветуй район для жилья.", "Попробуй Принсипи-Реал: тихо, рядом рестораны с вегетарианским меню."),
        ]
        for (ask, answer) in chat { memory.remember([.user(ask), .assistant(answer)]) }
        let call = ToolCall(id: "call_9", name: "shell", arguments: #"{"command":"echo 'День 1: Алфама' > ~/lisbon-plan.md"}"#)
        memory.remember([.user("Сохрани план первого дня в файл."), .assistant(nil, toolCalls: [call]),
                         .tool(id: "call_9", content: "exit 0"), .assistant("Сохранила план в ~/lisbon-plan.md.")])
        memory.remember([.user("Спасибо! А какая погода будет?"), .assistant("Около 15–18°C, возможен дождь: возьми зонт.")])

        let summary = try await live.client.chat(model: live.model, messages: Recap.request(memory, name: "Fizz")).text
        print("live recap:\n\(summary)")
        for fact in ["Лиссабон", "900", "lisbon-plan.md"] { #expect(summary.contains(fact), "missing \(fact)") }
        #expect(summary.count < 2_000)

        memory.recapped(summary)
        #expect(memory.exchangeCount == 1 && memory.recap != nil)
        let context = memory.context(system: system, turn: .user("Напомни мой бюджет и где я храню план? Одной фразой."))
        let reply = try await live.client.chat(model: live.model, messages: context).text
        print("live after recap: \(reply)")
        #expect(reply.contains("900") && reply.contains("lisbon-plan"), "got: \(reply)")
    }
}
