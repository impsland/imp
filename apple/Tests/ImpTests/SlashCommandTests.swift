import Foundation
import ImpCore
import Testing
import ImpKit
@testable import Imp

/// A custom command typed in an Imp's text box runs as in the `imp` chat: its text is made first (its command lines and
/// files behind the Imp's permission rules), then the Imp answers. The skills are in its system text and `use_skill` reads
/// them. Folders of their own, a stub model behind the Imp.
@MainActor @Suite(.serialized) struct SlashCommandTests {
    @MainActor private struct World {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("imp-slash-\(UUID().uuidString)")
        let suite = "app.imp.tests.\(UUID().uuidString)"
        let app: AppModel
        let imp: ImpModel

        init(server: StubModelServer, commands: [String: String] = [:], rules: String = "") throws {
            let configDir = root.appendingPathComponent(".config/imp")
            for (name, text) in commands { try Self.write(root, ".agents/commands/\(name).md", text) }
            try Self.write(root, ".agents/skills/notes/SKILL.md", "---\nname: notes\ndescription: Take notes\n---\nStep one.")
            app = KeptApps.keep(AppModel(persist: true, config: SharedConfigStore(configDir: configDir, homeDir: root), defaults: UserDefaults(suiteName: suite)!))
            _ = app.addImp()
            app.prefs.imps[0].name = "Pip"
            app.prefs.imps[0].personality = "You are Pip."
            app.prefs.imps[0].isActive = true
            app.prefs.ai.add(Service(name: "Stub", baseURL: server.baseURL, model: "stub"))
            app.assistant.configure(ai: app.prefs.ai, servers: [])
            app.flushSave()
            if !rules.isEmpty {
                let paths = ConfigPaths(configDir: configDir.path, homeDir: root.path)
                try configUpdateAgent(paths: paths, name: app.config!.agentName(for: app.prefs.imps[0].id)!, patchJson: #"{"permissions":[\#(rules)]}"#)
            }
            app.reloadConfiguration(force: true)
            imp = app.imps[0]
        }

        static func write(_ root: URL, _ path: String, _ text: String) throws {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }

        var marker: URL { Workspace.directory(for: imp.id).appendingPathComponent("marker") }

        func remove() {
            try? FileManager.default.removeItem(at: root)
            UserDefaults().removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: Workspace.directory(for: imp.id))
        }
    }

    private func until(_ seconds: Double = 30, _ done: () -> Bool) async {
        let end = Date().addingTimeInterval(seconds)
        while !done(), Date() < end { try? await Task.sleep(for: .milliseconds(20)) }
    }

    private func finish(_ w: World) async { await until { !w.imp.isBusy && w.imp.work == nil } }

    /// A model that answers "ok" and keeps what it was sent.
    private final class Sent: @unchecked Sendable {
        private let lock = NSLock()
        private var all: [StubModelServer.Request] = []
        func add(_ r: StubModelServer.Request) { lock.withLock { all.append(r) } }
        var requests: [StubModelServer.Request] { lock.withLock { all } }
    }

    private func server(_ sent: Sent) throws -> StubModelServer {
        try StubModelServer { r in sent.add(r); return .text("ok") }
    }

    @Test func theTextBoxListsTheCommandsWhileASlashIsTyped() async throws {
        let sent = Sent(); let stub = try server(sent); try await stub.start(); defer { stub.stop() }
        let w = try World(server: stub, commands: ["review": "Review $1", "run": "Run it"]); defer { w.remove() }
        w.imp.startTyping()
        #expect(w.imp.slashSuggestions(for: "/r").map(\.name) == ["review", "run"])
        #expect(w.imp.slashSuggestions(for: "/rev").map(\.name) == ["review"])
        #expect(w.imp.slashSuggestions(for: "hello").isEmpty)
        w.imp.slashClosedFor = "/rev"
        #expect(w.imp.slashSuggestions(for: "/rev").isEmpty, "closed with Esc")
        #expect(w.imp.slashSuggestions(for: "/revi").map(\.name) == ["review"], "until the line changes")
    }

    @Test func aCommandIsFilledInRunAndShownAsTyped() async throws {
        let sent = Sent(); let stub = try server(sent); try await stub.start(); defer { stub.stop() }
        let w = try World(server: stub, commands: ["say": "Say $1: !`echo hi`"]); defer { w.remove() }
        w.imp.startTyping()
        w.imp.submitTyped("/say there")
        await finish(w)
        #expect(sent.requests.last?.messages.last { $0.role == "user" }?.content.contains("Say there: hi") == true)
        #expect(w.imp.history.turns.last?.request == "/say there", "the chat shows what was typed")
        #expect(w.imp.history.turns.last?.reply == "ok")
    }

    @Test func aCommandLineThatIsNotAllowedStopsTheCommand() async throws {
        let sent = Sent(); let stub = try server(sent); try await stub.start(); defer { stub.stop() }
        let w = try World(server: stub, commands: ["mark": "!`touch marker`"],
                          rules: #"{"action":"shell","resource":"touch *","effect":"deny"}"#); defer { w.remove() }
        w.imp.startTyping()
        w.imp.submitTyped("/mark")
        await finish(w)
        #expect(!FileManager.default.fileExists(atPath: w.marker.path))
        #expect(sent.requests.isEmpty, "nothing was sent")
        #expect(w.imp.bubble?.text.contains("Not allowed by your permissions: shell touch marker") == true)
    }

    @Test func aSubtaskAnswersWithoutTheChatAndIsNotKept() async throws {
        let sent = Sent(); let stub = try server(sent); try await stub.start(); defer { stub.stop() }
        let w = try World(server: stub, commands: ["ask": "---\nsubtask: true\n---\nWhat is $1?"]); defer { w.remove() }
        w.imp.ask("first")
        await finish(w)
        let kept = w.imp.history.turns.count
        w.imp.startTyping()
        w.imp.submitTyped("/ask rust")
        await finish(w)
        let request = try #require(sent.requests.last)
        #expect(request.messages.filter { $0.role == "user" }.map(\.content).last?.contains("What is rust?") == true)
        #expect(!request.messages.contains { $0.role != "system" && $0.content.contains("first") }, "a conversation of its own")
        #expect(w.imp.history.turns.count == kept, "not kept")
        #expect(w.imp.bubble?.text == "ok", "shown")
    }

    @Test func aCommandNamingAnUnknownImpSaysSo() async throws {
        let sent = Sent(); let stub = try server(sent); try await stub.start(); defer { stub.stop() }
        let w = try World(server: stub, commands: ["to": "---\nagent: nobody\n---\nHi"]); defer { w.remove() }
        w.imp.startTyping()
        w.imp.submitTyped("/to")
        await until { w.imp.bubble?.phase == .error }
        #expect(w.imp.bubble?.text.contains("nobody") == true)
        #expect(sent.requests.isEmpty)
    }

    @Test func theSkillsAreInTheSystemTextAndTheModelReadsOne() async throws {
        let sent = Sent()
        let stub = try StubModelServer { r in
            sent.add(r)
            return r.last.role == "tool" ? .text("done") : .calls([("use_skill", #"{"name":"notes"}"#)])
        }
        try await stub.start(); defer { stub.stop() }
        let w = try World(server: stub); defer { w.remove() }
        w.imp.ask("take a note")
        await finish(w)
        let first = try #require(sent.requests.first)
        #expect(first.system.contains("- notes: Take notes"))
        #expect(sent.requests.last?.last.content.contains("Step one.") == true, "the model got the skill's text")
    }

    @Test func theSkillsGroupSwitchedOffTakesBothAway() async throws {
        let sent = Sent(); let stub = try server(sent); try await stub.start(); defer { stub.stop() }
        let w = try World(server: stub); defer { w.remove() }
        w.app.prefs.imps[0].setUses(.skills, false)
        w.app.flushSave()
        w.app.reloadConfiguration(force: true)
        w.imp.ask("hi")
        await finish(w)
        #expect(sent.requests.first?.system.contains("Skills") == false)
    }
}
