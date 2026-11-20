import Foundation
import ImpCore
import Testing
import ImpKit
@testable import Imp

/// An Imp's permissions in its bubble: a call the rules `ask` about waits for the person's answer, which the Imp's model
/// holds (one question at a time). Shared configuration in folders of their own, a stub model behind the Imp.
@MainActor @Suite(.serialized) struct PermissionPromptTests {
    @MainActor private struct World {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("imp-prompt-\(UUID().uuidString)")
        let suite = "app.imp.tests.\(UUID().uuidString)"
        let app: AppModel
        let imp: ImpModel
        var marker: URL { Workspace.directory(for: imp.id).appendingPathComponent("marker") }
        var agentFile: URL { root.appendingPathComponent(".agents/agents/\(app.config!.agentName(for: imp.id)!).md") }

        init(server: StubModelServer, rule: String) throws {
            let configDir = root.appendingPathComponent(".config/imp")
            app = AppModel(persist: true, config: SharedConfigStore(configDir: configDir, homeDir: root), defaults: UserDefaults(suiteName: suite)!)
            _ = app.addImp()
            app.prefs.imps[0].name = "Pip"
            app.prefs.imps[0].personality = "You are Pip."
            app.prefs.imps[0].isActive = true
            app.prefs.ai.add(Service(name: "Stub", baseURL: server.baseURL, model: "stub"))
            app.assistant.configure(ai: app.prefs.ai, servers: [])
            app.flushSave()
            let paths = ConfigPaths(configDir: configDir.path, homeDir: root.path)
            try configUpdateAgent(paths: paths, name: app.config!.agentName(for: app.prefs.imps[0].id)!,
                                  patchJson: #"{"permissions":[{"action":"shell","resource":"touch *","effect":"\#(rule)"}]}"#)
            app.reloadConfiguration(force: true)
            imp = app.imps[0]
        }

        func remove() {
            try? FileManager.default.removeItem(at: root)
            UserDefaults().removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: Workspace.directory(for: imp.id))
        }
    }

    private func server() throws -> StubModelServer {
        try StubModelServer { r in
            r.last.role == "tool" ? .text("done") : .calls([("shell", #"{"command":"touch marker"}"#)])
        }
    }

    private func until(_ seconds: Double = 30, _ done: () -> Bool) async {
        let end = Date().addingTimeInterval(seconds)
        while !done(), Date() < end { try? await Task.sleep(for: .milliseconds(20)) }
    }

    private func finish(_ w: World) async { await until { !w.imp.isBusy } }

    @Test func askedInTheBubbleAndAllowedOnce() async throws {
        let stub = try server(); try await stub.start(); defer { stub.stop() }
        let w = try World(server: stub, rule: "ask"); defer { w.remove() }
        w.imp.ask("go")
        await until { w.imp.prompt != nil }
        #expect(w.imp.prompt == Bubble.Prompt(action: "shell", resource: "touch marker"))
        #expect(w.imp.bubble?.permission == w.imp.prompt, "the bubble shows it, so it is measured with it")
        #expect(!FileManager.default.fileExists(atPath: w.marker.path), "nothing ran while it waits")
        w.imp.answerPermission(.once)
        await finish(w)
        #expect(FileManager.default.fileExists(atPath: w.marker.path))
        #expect(w.imp.prompt == nil && w.imp.bubble?.permission == nil)
        #expect(!((try? String(contentsOf: w.agentFile, encoding: .utf8)) ?? "").contains("touch marker"), "once writes nothing")
    }

    @Test func denyShowsAsARefusedStep() async throws {
        let stub = try server(); try await stub.start(); defer { stub.stop() }
        let w = try World(server: stub, rule: "ask"); defer { w.remove() }
        w.imp.ask("go")
        await until { w.imp.prompt != nil }
        w.imp.answerPermission(.deny)
        await finish(w)
        #expect(!FileManager.default.fileExists(atPath: w.marker.path))
        let step = w.imp.bubble?.steps.first
        #expect(step?.state == .failed && step?.response?.contains("Not allowed by your permissions: shell touch marker") == true)
    }

    @Test func alwaysWritesTheRuleAndItSurvivesTheApp() async throws {
        let stub = try server(); try await stub.start(); defer { stub.stop() }
        let w = try World(server: stub, rule: "ask"); defer { w.remove() }
        w.imp.ask("go")
        await until { w.imp.prompt != nil }
        w.imp.answerPermission(.always)
        await finish(w)
        #expect(FileManager.default.fileExists(atPath: w.marker.path))
        #expect(try String(contentsOf: w.agentFile, encoding: .utf8).contains("touch marker"))
        w.app.flushSave()
        #expect(try String(contentsOf: w.agentFile, encoding: .utf8).contains("touch marker"), "the app saving does not drop it")
    }

    @Test func stoppingWhileAskingRefusesAndClearsTheQuestion() async throws {
        let stub = try server(); try await stub.start(); defer { stub.stop() }
        let w = try World(server: stub, rule: "ask"); defer { w.remove() }
        w.imp.ask("go")
        await until { w.imp.prompt != nil }
        w.imp.cancel()
        await finish(w)
        await until { w.imp.prompt == nil && w.imp.desk.current == nil }
        #expect(w.imp.prompt == nil && w.imp.desk.count == 0)
        #expect(!FileManager.default.fileExists(atPath: w.marker.path))
    }

    @Test func anImpAnsweringAnotherDeviceHasNobodyToAsk() async throws {
        let stub = try server(); try await stub.start(); defer { stub.stop() }
        let w = try World(server: stub, rule: "ask"); defer { w.remove() }
        w.imp.ask("go", askedFrom: AskOrigin(device: UUID(), name: "Phone", trusted: true))
        await until { w.imp.isBusy }
        await finish(w)
        #expect(w.imp.prompt == nil, "nobody was asked")
        #expect(!FileManager.default.fileExists(atPath: w.marker.path))
        let step = w.imp.bubble?.steps.first
        #expect(step?.state == .failed && step?.response?.contains("Not allowed by your permissions: shell touch marker") == true)
    }

    @Test func aDenyRuleRefusesWithoutAsking() async throws {
        let stub = try server(); try await stub.start(); defer { stub.stop() }
        let w = try World(server: stub, rule: "deny"); defer { w.remove() }
        w.imp.ask("go")
        await until { w.imp.isBusy }
        await finish(w)
        #expect(w.imp.prompt == nil && !FileManager.default.fileExists(atPath: w.marker.path))
        #expect(w.imp.bubble?.steps.first?.state == .failed)
    }
}
