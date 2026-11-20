import Foundation
import ImpCore
import Testing
@testable import ImpKit

/// The permissions at work in the Mac's agent loop (`docs/architecture/configuration.md`, "Permissions"): every tool
/// call is checked by the core against the Imp's rules before it runs. Folders of their own, never the person's.
@Suite(.serialized) struct PermissionGateTests {
    private struct Home {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("imp-gate-\(UUID().uuidString)")
        var config: URL { root.appendingPathComponent(".config/imp") }
        var agentFile: URL { root.appendingPathComponent(".agents/agents/pip.md") }
        var marker: URL { root.appendingPathComponent("marker") }
        func store() -> SharedConfigStore { SharedConfigStore(configDir: config, homeDir: root) }

        init(permissions: [(String, String, String)]) throws {
            try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: agentFile.deletingLastPathComponent(), withIntermediateDirectories: true)
            let rules = permissions.map { #"{"action":"\#($0.0)","resource":"\#($0.1)","effect":"\#($0.2)"}"# }.joined(separator: ",")
            try #"{"mcp":{"files":{"type":"local","command":["true"]}},"permissions":[\#(rules)]}"#
                .write(to: config.appendingPathComponent("imp.json"), atomically: true, encoding: .utf8)
            try "---\nmode: primary\n---\n\nYou are Pip.\n".write(to: agentFile, atomically: true, encoding: .utf8)
        }

        func remove() { try? FileManager.default.removeItem(at: root) }
        var agentText: String { (try? String(contentsOf: agentFile, encoding: .utf8)) ?? "" }
    }

    /// An MCP tool of the server `files`, which counts how often it ran.
    private actor Files: ToolProvider {
        private(set) var runs = 0
        func tools() async -> [ToolSpec] { [ToolSpec(name: "files_write_file", description: "Write")] }
        func catalog() async -> [CatalogTool] {
            await tools().map { CatalogTool(entry: ToolEntry(id: "mcp.files.write_file", name: $0.name, group: "files", title: "write_file"), spec: $0) }
        }
        func call(_ name: String, arguments: String) async throws -> String { runs += 1; return "written" }
    }

    /// Answers every question the same way and keeps them.
    private final class Asker: PermissionAsking, @unchecked Sendable {
        private let lock = NSLock()
        private var asked: [PermissionQuestion] = []
        let answer: PermissionAnswer
        init(_ answer: PermissionAnswer) { self.answer = answer }
        var questions: [PermissionQuestion] { lock.withLock { asked } }
        func ask(_ question: PermissionQuestion) async -> PermissionAnswer {
            lock.withLock { asked.append(question) }
            return answer
        }
    }

    private actor Events {
        private(set) var all: [AgentEvent] = []
        func add(_ e: AgentEvent) { all.append(e) }
    }

    private func reply(_ tool: String, _ arguments: String) -> String {
        let escaped = arguments.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return #"{"choices":[{"message":{"content":null,"tool_calls":[{"id":"c","type":"function","function":{"name":"\#(tool)","arguments":"\#(escaped)"}}]}}]}"#
    }
    private let done = #"{"choices":[{"message":{"content":"done"}}]}"#

    private func run(_ tools: ToolProvider, gate: ToolGate, call: String, arguments: String,
                     events: Events = Events()) async throws -> (reply: String, transcript: [ChatMessage], events: [AgentEvent]) {
        let base = StubProtocol.serve([reply(call, arguments), done])
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        let client = try OpenAIClient(baseURL: base, apiKey: "k", session: URLSession(configuration: config))
        let agent = Agent(client: client, model: "m", tools: tools, gate: gate)
        let (text, transcript) = try await agent.run([.user("go")]) { await events.add($0) }
        return (text, transcript, await events.all)
    }

    private func gate(_ home: Home, asker: PermissionAsking?, remembered: @escaping @Sendable () async -> Void = {}) -> ToolGate {
        ToolGate(imp: "Pip", agent: "pip", store: home.store(), asker: asker, unattended: "this test has nobody", remembered: remembered)
    }

    private func shell(_ home: Home) -> ShellTool { ShellTool(directory: home.root) }
    private let touch = #"{"command":"touch marker"}"#

    // MARK: deny

    @Test func aDenyRuleBlocksAShellCommand() async throws {
        let home = try Home(permissions: [("shell", "touch *", "deny")])
        defer { home.remove() }
        let asker = Asker(.once)
        let r = try await run(shell(home), gate: gate(home, asker: asker), call: "shell", arguments: touch)
        #expect(!FileManager.default.fileExists(atPath: home.marker.path), "the command did not run")
        #expect(r.transcript.first { $0.role == "tool" }?.content?.contains("Not allowed by your permissions: shell touch marker") == true)
        #expect(r.events.contains { if case .toolRefused("shell", _) = $0 { true } else { false } })
        #expect(!r.events.contains { if case .toolFinished = $0 { true } else { false } })
        #expect(asker.questions.isEmpty, "a deny is not asked about")
    }

    @Test func aDenyRuleBlocksAnMCPTool() async throws {
        let home = try Home(permissions: [("mcp", "files/*", "deny")])
        defer { home.remove() }
        let files = Files()
        let r = try await run(files, gate: gate(home, asker: Asker(.once)), call: "files_write_file", arguments: "{}")
        #expect(await files.runs == 0)
        #expect(r.transcript.first { $0.role == "tool" }?.content?.contains("Not allowed by your permissions: mcp files/write_file") == true)
        #expect(r.reply == "done")
    }

    @Test func aCallNoRuleMentionsRuns() async throws {
        let home = try Home(permissions: [("shell", "rm *", "deny")])
        defer { home.remove() }
        _ = try await run(shell(home), gate: gate(home, asker: nil), call: "shell", arguments: touch)
        #expect(FileManager.default.fileExists(atPath: home.marker.path))
    }

    // MARK: ask

    @Test func allowOnceRunsAndWritesNothing() async throws {
        let home = try Home(permissions: [("shell", "touch *", "ask")])
        defer { home.remove() }
        let before = home.agentText
        let asker = Asker(.once)
        _ = try await run(shell(home), gate: gate(home, asker: asker), call: "shell", arguments: touch)
        #expect(FileManager.default.fileExists(atPath: home.marker.path))
        #expect(asker.questions == [PermissionQuestion(imp: "Pip", action: "shell", resource: "touch marker")])
        #expect(home.agentText == before)
    }

    @Test func alwaysRunsWritesTheRuleAndTellsTheApp() async throws {
        let home = try Home(permissions: [("shell", "touch *", "ask")])
        defer { home.remove() }
        let told = Told()
        _ = try await run(shell(home), gate: gate(home, asker: Asker(.always), remembered: { await told.add() }),
                          call: "shell", arguments: touch)
        #expect(FileManager.default.fileExists(atPath: home.marker.path))
        #expect(home.agentText.contains("touch marker") && home.agentText.contains("allow"), "the rule is in the agent file")
        #expect(await told.count == 1)
        // The next call is allowed without asking.
        let verdict = home.store().gate(agent: "pip", toolID: nil, name: "shell", arguments: touch)
        #expect(verdict.effect == .allow)
    }

    @Test func denyRefusesWithTheAnswer() async throws {
        let home = try Home(permissions: [("shell", "touch *", "ask")])
        defer { home.remove() }
        let r = try await run(shell(home), gate: gate(home, asker: Asker(.deny)), call: "shell", arguments: touch)
        #expect(!FileManager.default.fileExists(atPath: home.marker.path))
        #expect(r.transcript.first { $0.role == "tool" }?.content?.contains("Not allowed by your permissions: shell touch marker. The person chose Deny.") == true)
        #expect(r.events.contains { if case .toolRefused("shell", _) = $0 { true } else { false } })
    }

    @Test func stoppingWhileAskingRefuses() async throws {
        let home = try Home(permissions: [("shell", "touch *", "ask")])
        defer { home.remove() }
        let desk = await PermissionDesk()
        let g = gate(home, asker: desk)
        let task = Task { try await run(shell(home), gate: g, call: "shell", arguments: touch) }
        while await desk.current == nil { try await Task.sleep(for: .milliseconds(10)) }
        #expect(await desk.current?.resource == "touch marker")
        task.cancel()
        _ = try? await task.value
        #expect(!FileManager.default.fileExists(atPath: home.marker.path))
        let (left, waiting) = await (desk.current, desk.count)
        #expect(left == nil && waiting == 0, "nothing is left waiting")
    }

    @Test func nobodyToAskCountsAsDeny() async throws {
        let home = try Home(permissions: [("shell", "touch *", "ask"), ("mcp", "files/*", "ask")])
        defer { home.remove() }
        // Answering another device, or visiting: no asker.
        let r = try await run(shell(home), gate: gate(home, asker: nil), call: "shell", arguments: touch)
        #expect(!FileManager.default.fileExists(atPath: home.marker.path))
        let result = try #require(r.transcript.first { $0.role == "tool" }?.content)
        #expect(result.contains("Not allowed by your permissions: shell touch marker") && result.contains("this test has nobody"))
        let files = Files()
        _ = try await run(files, gate: gate(home, asker: nil), call: "files_write_file", arguments: "{}")
        #expect(await files.runs == 0)
    }

    // MARK: the desk

    @Test @MainActor func aSecondQuestionQueuesBehindTheFirst() async throws {
        let desk = PermissionDesk()
        var changes = 0
        desk.onChange = { changes += 1 }
        let first = Task { await desk.ask(PermissionQuestion(imp: "Pip", action: "shell", resource: "one")) }
        while desk.current == nil { try await Task.sleep(for: .milliseconds(5)) }
        let second = Task { await desk.ask(PermissionQuestion(imp: "Pip", action: "shell", resource: "two")) }
        while desk.count < 2 { try await Task.sleep(for: .milliseconds(5)) }
        #expect(desk.current?.resource == "one")
        desk.answer(.once)
        #expect(await first.value == .once)
        #expect(desk.current?.resource == "two", "the next one is open once the first is answered")
        desk.answer(.always)
        #expect(await second.value == .always)
        #expect(desk.current == nil && changes == 3, "told when the open question changed: opened, next one, none")
    }

    @Test @MainActor func cancellingAQueuedQuestionDeniesOnlyIt() async throws {
        let desk = PermissionDesk()
        let first = Task { await desk.ask(PermissionQuestion(imp: "Pip", action: "shell", resource: "one")) }
        while desk.current == nil { try await Task.sleep(for: .milliseconds(5)) }
        let second = Task { await desk.ask(PermissionQuestion(imp: "Pip", action: "shell", resource: "two")) }
        while desk.count < 2 { try await Task.sleep(for: .milliseconds(5)) }
        second.cancel()
        #expect(await second.value == .deny)
        #expect(desk.current?.resource == "one" && desk.count == 1)
        desk.denyAll()
        #expect(await first.value == .deny)
    }

    // MARK: the core's vectors

    private nonisolated(unsafe) static let vectors: [String: Any] = {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("spec/fixtures/config/vectors.json")
        return (try? JSONSerialization.jsonObject(with: Data(contentsOf: url))) as? [String: Any] ?? [:]
    }()

    @Test func theCoreClassifiesAsTheVectorsSay() throws {
        let cases = try #require(Self.vectors["gate"] as? [[String: Any]])
        #expect(!cases.isEmpty)
        for c in cases {
            let call = permissionClassify(toolId: c["tool_id"] as? String, toolName: c["tool"] as! String,
                                          argumentsJson: c["arguments"] as? String ?? "", servers: c["servers"] as? [String] ?? [])
            #expect(call.action == c["action"] as? String && call.resource == c["resource"] as? String, "\(c["name"] ?? "")")
        }
    }

    @Test func theCoreDecidesAsTheVectorsSay() throws {
        let cases = try #require(Self.vectors["gate_decide"] as? [[String: Any]])
        #expect(!cases.isEmpty)
        for c in cases {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("imp-vector-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: root) }
            let config = root.appendingPathComponent(".config/imp")
            try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
            let servers = Dictionary(uniqueKeysWithValues: (c["servers"] as? [String] ?? []).map { ($0, ["type": "local", "command": ["true"]] as [String: Any]) })
            let body: [String: Any] = ["mcp": servers, "permissions": c["rules"] as? [[String: Any]] ?? []]
            try JSONSerialization.data(withJSONObject: body).write(to: config.appendingPathComponent("imp.json"))
            // The vector's home is the folder `~` means in its rules.
            let paths = ConfigPaths(configDir: config.path, homeDir: c["home"] as? String ?? root.path)
            let verdict = configGate(paths: paths, agent: "pip", toolId: c["tool_id"] as? String, toolName: c["tool"] as! String,
                                     argumentsJson: c["arguments"] as? String ?? "")
            let expected = try #require(c["effect"] as? String)
            let got = switch verdict.effect { case .allow: "allow"; case .ask: "ask"; case .deny: "deny" }
            #expect(got == expected, "\(c["name"] ?? "")")
        }
    }
}

private actor Told {
    private(set) var count = 0
    func add() { count += 1 }
}
