import Foundation
import ImpCore
import Testing
import ImpKit
@testable import Imp

/// The Mac app and the core (which `imp` uses) on the same files: what one writes the other reads, in
/// folders and a preferences domain of their own (never the person's real ones).
@MainActor @Suite struct SharedConfigAppTests {
    @MainActor private struct Sandbox {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("imp-app-config-\(UUID().uuidString)")
        let suite = "app.imp.tests.\(UUID().uuidString)"
        var configDir: URL { root.appendingPathComponent(".config/imp") }
        var paths: ConfigPaths { ConfigPaths(configDir: configDir.path, homeDir: root.path) }
        func agent(_ name: String) -> URL { root.appendingPathComponent(".agents/agents/\(name).md") }
        var defaults: UserDefaults { UserDefaults(suiteName: suite)! }
        func store() -> SharedConfigStore { SharedConfigStore(configDir: configDir, homeDir: root) }
        func app() -> AppModel { AppModel(persist: true, config: store(), defaults: defaults) }
        /// What the core reads now, as the terminal app would.
        func coreRead() -> ImpPreferences { SharedMapping.read(SharedSnapshot(configLoad(paths: paths))).prefs }
        func remove() {
            try? FileManager.default.removeItem(at: root)
            UserDefaults().removePersistentDomain(forName: suite)
        }
    }

    @Test func whatTheCoreWroteIsInTheApp() throws {
        let box = Sandbox()
        defer { box.remove() }
        try configUpdate(paths: box.paths, patchJson: #"{"model":"studio/qwen","providers":{"studio":{"name":"Studio","options":{"baseURL":"http://localhost:1234/v1"}}},"talk":{"windowMinutes":15}}"#)
        try configUpdateAgent(paths: box.paths, name: "Zed", patchJson: #"{"mode":"primary","description":"From imp","body":"You are Zed."}"#)
        let app = box.app()
        #expect(app.prefs.imps.map(\.name) == ["Zed"] && app.prefs.imps[0].about == "From imp" && app.prefs.imps[0].personality == "You are Zed.")
        #expect(app.prefs.ai.services.map(\.name) == ["Studio"] && app.prefs.ai.model() == "qwen" && app.prefs.talkWindowMinutes == 15)
    }

    @Test func whatTheAppSavedIsWhatTheCoreReads() throws {
        let box = Sandbox()
        defer { box.remove() }
        let app = box.app()
        #expect(app.prefs.imps.isEmpty, "a first run has no Imps and an empty configuration is fine")
        let id = app.addImp()
        app.prefs.imps[0].about = "From the app"
        app.prefs.ai.add(Service(name: "Studio", baseURL: "http://localhost:1234/v1", model: "qwen"))
        app.prefs.talkWindowMinutes = 30
        app.flushSave()
        let read = box.coreRead()
        #expect(read.imps.count == 1 && read.imps[0].id == id && read.imps[0].about == "From the app")
        #expect(read.ai.services.map(\.name) == ["Studio"] && read.ai.services[0].model == "qwen" && read.talkWindowMinutes == 30)
        #expect(read == box.coreRead(), "reading twice gives the same")
        // And a second app on the same files sees the same.
        #expect(box.app().prefs.imps.map(\.id) == [id])
    }

    @Test func toolTextIsSharedAndShapesTheMacsTools() async throws {
        let box = Sandbox()
        defer { box.remove() }
        let app = box.app()
        let first = app.addImp()
        _ = app.addImp()
        let at = try #require(app.prefs.imps.firstIndex { $0.id == first })
        let message = ToolRegistry.ownID(.personality, tool: "imp_message"), show = ToolRegistry.ownID(.look, tool: "imp_show_background")
        app.prefs.imps[at].toolText = [message: ToolText(name: "ask_friend", description: "Ask one of {imps} (in {place}: {animations})"),
                                      show: ToolText(name: "look_behind", description: "Read the page in {place}")]
        app.flushSave()
        #expect(box.coreRead().imps.first { $0.id == first }?.toolText == app.prefs.imps[at].toolText, "the terminal's agent file has it")
        let agent = try String(contentsOf: box.agent(app.prefs.imps[at].name), encoding: .utf8)
        #expect(agent.contains("ask_friend"), "\(agent)")
        let profile = try #require(app.profile(first))
        let set = ToolSet([ImpTools(host: OwnToolHost(app: app, imp: first, messaging: true))], selection: profile.toolSelection)
        let specs = await set.tools()
        #expect(specs.first { $0.name == "look_behind" }?.description == "Read the page in the home window on the Mac")
        #expect(!specs.contains { $0.name == "imp_show_background" })
        #expect(try await set.call("look_behind", arguments: "{}") == RoomBackground.shown(app.prefs.background))
        let rows = await set.textRows()
        #expect(rows.first { $0.id == show }?.defaultDescription.contains("{place}") == true)
    }

    @Test func aNewServiceKeepsTheKeyTypedForIt() throws {
        let box = Sandbox()
        defer { box.remove() }
        let app = box.app()
        let service = Service(name: "Cloud", baseURL: "https://api.example.com/v1", model: "m")
        #expect(app.addService(service, key: "sk-new"), "the service is written before its key")
        #expect(app.assistant.hasKey(service.id))
        // Read from auth.json, where `imp` finds it too.
        #expect(app.config?.key(for: service.id) == "sk-new")
        #expect(box.coreRead().ai.services.map(\.name) == ["Cloud"])
    }

    @Test func theFirstRunKeepsTheKeyOfANewBrain() throws {
        let box = Sandbox()
        defer { box.remove() }
        let app = box.app()
        let profile = app.prefs.nextImp()
        let brain = FirstRunBrain(name: "Cloud", baseURL: "https://api.example.com/v1", model: "m", key: "sk-first", isLocal: false)
        let id = try app.adoptFirstRunBrain(brain, for: .newImp(profile))
        #expect(app.isReady(id))
        let service = try #require(app.prefs.ai.brain.service)
        #expect(app.config?.key(for: service) == "sk-first")
    }

    @Test func anAgentFileEditedByTheTerminalAppearsAfterTheCheck() throws {
        let box = Sandbox()
        defer { box.remove() }
        try configUpdateAgent(paths: box.paths, name: "Zed", patchJson: #"{"mode":"primary","description":"Before","body":"You are Zed."}"#)
        let app = box.app()
        app.reloadConfiguration()
        #expect(app.prefs.imps[0].about == "Before", "nothing changed: nothing is read again")
        try "---\nmode: primary\ndescription: Edited in an editor\n---\nYou are Zed, edited.\n".write(to: box.agent("Zed"), atomically: true, encoding: .utf8)
        #expect(app.config?.changedOutside() == true)
        app.reloadConfiguration()
        #expect(app.prefs.imps[0].about == "Edited in an editor" && app.prefs.imps[0].personality.hasPrefix("You are Zed, edited."))
        #expect(app.config?.changedOutside() == false)
    }

    @Test func aChangeFromOutsideDoesNotUndoAnEditNotYetWritten() throws {
        let box = Sandbox()
        defer { box.remove() }
        try configUpdateAgent(paths: box.paths, name: "Ann", patchJson: #"{"mode":"primary","body":"You are Ann."}"#)
        try configUpdateAgent(paths: box.paths, name: "Bob", patchJson: #"{"mode":"primary","body":"You are Bob."}"#)
        let app = box.app()
        let ann = try #require(app.prefs.imps.first { $0.name == "Ann" }).id
        let bob = try #require(app.prefs.imps.first { $0.name == "Bob" }).id
        app.prefs.imps[app.prefs.imps.firstIndex { $0.id == ann }!].about = "Typed here"      // not written yet
        try configUpdateAgent(paths: box.paths, name: "Bob", patchJson: #"{"description":"Typed in the terminal"}"#)
        try configUpdate(paths: box.paths, patchJson: #"{"requests":{"retries":9}}"#)
        app.reloadConfiguration()
        #expect(app.prefs.imps.first { $0.id == ann }?.about == "Typed here")
        #expect(app.prefs.imps.first { $0.id == bob }?.about == "Typed in the terminal" && app.prefs.requests.retries == 9)
        app.flushSave()
        let read = box.coreRead()
        #expect(read.imps.first { $0.id == ann }?.about == "Typed here" && read.imps.first { $0.id == bob }?.about == "Typed in the terminal")
        #expect(read.requests.retries == 9)
    }

    @Test func screenStateStaysInThePreferencesByImpId() throws {
        let box = Sandbox()
        defer { box.remove() }
        let app = box.app()
        let id = app.addImp()
        let index = try #require(app.prefs.imps.firstIndex { $0.id == id })
        app.prefs.imps[index].origin = CGPoint(x: 7, y: 9)
        app.flushSave()
        let again = box.app()
        #expect(again.prefs.imps.first { $0.id == id }?.origin == CGPoint(x: 7, y: 9))
        #expect(!((try? String(contentsOf: box.agent(app.prefs.imps[index].name), encoding: .utf8)) ?? "").contains("origin"))
    }
}

@MainActor @Suite struct CreateImpAppTests {
    @Test func anImpMakesAnImpAndTheSharedConfigWritesIt() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("imp-create-\(UUID().uuidString)")
        let suite = "app.imp.tests.\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(at: root); UserDefaults().removePersistentDomain(forName: suite) }
        let store = SharedConfigStore(configDir: root.appendingPathComponent(".config/imp"), homeDir: root)
        let app = AppModel(persist: true, config: store, defaults: UserDefaults(suiteName: suite)!)
        let creatorID = app.addImp()
        let creator = try #require(app.profile(creatorID))
        let brain = Brain(service: UUID(), model: "qwen")
        app.prefs.imps[0].brain = brain
        app.prefs.imps[0].name = "Pip"
        let made = try app.createImp(["name": "Scout", "description": "Reviews diffs", "system_prompt": "You review code."],
                                     by: creator.id, letOut: false)
        #expect(app.prefs.imps.count == 2)
        #expect(made.brain == brain && made.about == "Reviews diffs" && made.personality == "You review code.")
        #expect(throws: ToolArgumentError.self) { try app.createImp(["name": "scout"], by: creator.id, letOut: false) }
        #expect(app.prefs.imps.count == 2)
        app.flushSave()
        let file = root.appendingPathComponent(".agents/agents/Scout.md")
        let text = try String(contentsOf: file, encoding: .utf8)
        #expect(text.contains("description: Reviews diffs") || text.contains("description: \"Reviews diffs\""))
        #expect(text.contains("You review code."))
    }
}
