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
