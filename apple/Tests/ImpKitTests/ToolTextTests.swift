import Foundation
import ImpCore
import Testing
@testable import ImpKit

/// What a person writes over a tool's name and description (`ToolText`): offered as written, run and gated as the tool itself.
@Suite(.serialized) struct ToolTextTests {
    private actor Tools: ToolProvider {
        private(set) var ran: [String] = []
        func tools() async -> [ToolSpec] { await catalog().map(\.spec) }
        func catalog() async -> [CatalogTool] {
            [CatalogTool(entry: ToolEntry(id: "own.personality.imp_message", name: "imp_message", group: "own.personality"),
                         spec: ToolSpec(name: "imp_message", description: "Message Mo, Bo. Roster: Mo, Bo", inputSchema: ["type": "object"]),
                         fills: ["imps": "Mo, Bo"]),
             CatalogTool(entry: ToolEntry(id: "own.personality.imp_open_file", name: "imp_open_file", group: "own.personality"),
                         spec: ToolSpec(name: "imp_open_file", description: "Open", inputSchema: ["type": "object"]))]
        }
        func call(_ name: String, arguments: String) async throws -> String { ran.append(name); return "ran \(name)" }
    }

    private actor Heard {
        private(set) var all: [AgentEvent] = []
        func add(_ e: AgentEvent) { all.append(e) }
    }

    @Test func aDescriptionIsOfferedWithItsPlaceholdersFilled() async {
        let id = "own.personality.imp_message"
        let set = ToolSet([Tools()], selection: ToolSelection(text: [id: ToolText(description: "Talk to {imps}. {other} {animations}!")]))
        #expect(await set.tools().first?.description == "Talk to Mo, Bo. {other} !")
        let rows = await set.textRows()
        #expect(rows.map(\.id) == [id, "own.personality.imp_open_file"])
        #expect(rows[0].placeholders == ["imps"] && rows[0].defaultName == "imp_message")
        #expect(rows[0].defaultDescription == "Message {imps}. Roster: {imps}")
        #expect(rows[0].text?.description != nil && rows[1].text == nil)
    }

    @Test func theRosterAndTheAnimationsAreWhatTheOwnToolsFill() async throws {
        let message = ToolRegistry.ownID(.personality, tool: "imp_message"), play = ToolRegistry.ownID(.animations, tool: "imp_play_animations")
        let imps = ["Mo", "Bo"]
        let specs = OwnTools.specs([.personality, .animations], animations: ["Wave", "Spin"], imps: imps, browser: false)
        let roster = OwnTools.messageParts(imps: imps).roster
        let catalog = OwnTools.catalog(specs, animations: ["Wave", "Spin"], roster: roster, place: "here")
        struct Fixed: ToolProvider {
            let items: [CatalogTool]
            func tools() async -> [ToolSpec] { items.map(\.spec) }
            func catalog() async -> [CatalogTool] { items }
            func call(_ name: String, arguments: String) async throws -> String { name }
        }
        let text = [message: ToolText(description: "Ask: {imps}"), play: ToolText(name: "act", description: "Play {animations}")]
        let set = ToolSet([Fixed(items: catalog)], selection: ToolSelection(text: text))
        let offered = await set.tools()
        #expect(offered.first { $0.name == "imp_message" }?.description == "Ask: \(roster)")
        #expect(offered.first { $0.name == "act" }?.description == "Play Wave, Spin")
        let rows = await set.textRows()
        #expect(rows.first { $0.id == message }?.placeholders == ["imps"] && rows.first { $0.id == play }?.placeholders == ["animations"])
        #expect(try await set.call("act", arguments: "{}") == "imp_play_animations")
    }

    @Test func aRenamedToolRunsAsItself() async throws {
        let tools = Tools()
        let id = "own.personality.imp_message"
        let set = ToolSet([tools], selection: ToolSelection(text: [id: ToolText(name: "ask_friend")]))
        #expect(await set.tools().map(\.name) == ["ask_friend", "imp_open_file"])
        #expect(try await set.call("ask_friend", arguments: "{}") == "ran imp_message")
        #expect(await tools.ran == ["imp_message"])
        await #expect(throws: MCPError.self) { try await set.call("imp_message", arguments: "{}") }
    }

    @Test func aNameThatIsNotAllowedOrTakenIsIgnored() async {
        let text = ["own.personality.imp_message": ToolText(name: "not ok"),
                    "own.personality.imp_open_file": ToolText(name: "imp_message")]
        let set = ToolSet([Tools()], selection: ToolSelection(text: text))
        #expect(await set.tools().map(\.name) == ["imp_message", "imp_open_file"])
        #expect(ToolText.isValid(name: "ask-friend_2") && !ToolText.isValid(name: "a b") && !ToolText.isValid(name: ""))
    }

    @Test func aRenamedToolIsGatedUnderItsOwnName() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("imp-text-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let config = root.appendingPathComponent(".config/imp")
        let agentFile = root.appendingPathComponent(".agents/agents/pip.md")
        try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: agentFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try #"{"permissions":[{"action":"personality","resource":"imp_open_file","effect":"deny"}]}"#
            .write(to: config.appendingPathComponent("imp.json"), atomically: true, encoding: .utf8)
        try "---\nmode: primary\n---\n\nYou are Pip.\n".write(to: agentFile, atomically: true, encoding: .utf8)
        let gate = ToolGate(imp: "Pip", agent: "pip", store: SharedConfigStore(configDir: config, homeDir: root), asker: nil,
                            unattended: "nobody", remembered: {})
        let tools = Tools()
        let set = ToolSet([tools], selection: ToolSelection(text: ["own.personality.imp_open_file": ToolText(name: "show_file")]))
        let body = #"{"choices":[{"message":{"content":null,"tool_calls":[{"id":"c","type":"function","function":{"name":"show_file","arguments":"{}"}}]}}]}"#
        let base = StubProtocol.serve([body, #"{"choices":[{"message":{"content":"done"}}]}"#])
        let session = URLSessionConfiguration.ephemeral
        session.protocolClasses = [StubProtocol.self]
        let client = try OpenAIClient(baseURL: base, apiKey: "k", session: URLSession(configuration: session))
        let heard = Heard()
        let (_, transcript) = try await Agent(client: client, model: "m", tools: set, gate: gate).run([.user("go")]) { await heard.add($0) }
        #expect(await tools.ran.isEmpty, "the deny rule on imp_open_file stopped show_file")
        #expect(transcript.first { $0.role == "tool" }?.content?.contains("Not allowed by your permissions: personality imp_open_file") == true)
        let events = await heard.all
        #expect(events.contains { if case .toolRefused("imp_open_file", _) = $0 { true } else { false } }, "events use the real name")
    }

    @Test func aProfileCarriesItIntoItsSelectionAndAKit() {
        var imp = ImpProfile(name: "Dot", hue: 0, favoriteHue: 0, personality: "")
        imp.toolText = ["own.a.b": ToolText(name: "x"), "own.a.c": ToolText()]
        #expect(imp.toolText.keys.sorted() == ["own.a.b"], "an empty override is not kept")
        #expect(imp.toolSelection.text == imp.toolText)
        let json = (try? JSONEncoder().encode(ToolSelection(text: imp.toolText))).flatMap { try? JSONDecoder().decode(ToolSelection.self, from: $0) }
        #expect(json?.text == imp.toolText)
    }
}
