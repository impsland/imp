import Foundation
import ImpCore
import ImpKit
import Testing
@testable import Imp

/// End to end with the real terminal app: `imp` writes a configuration into folders of its own, the Mac app's
/// model reads it, changes it and saves, and `imp` (run by the script that started this test) reads the change.
///
/// Runs only when the folders are given, so `swift test` never touches a person's configuration:
///   IMP_E2E_CONFIG_HOME  the config folder `imp` wrote (imp.json, auth.json)
///   IMP_E2E_HOME         the home folder `imp` wrote the agents into (~/.agents)
///   IMP_E2E_MODEL        the model Pip is expected to use, as the app shows it (provider/model)
/// The key is checked for presence only and is never printed.
@MainActor @Suite struct CrossAppE2ETests {
    private nonisolated static let env = ProcessInfo.processInfo.environment
    nonisolated static var enabled: Bool { env["IMP_E2E_CONFIG_HOME"] != nil && env["IMP_E2E_HOME"] != nil }

    @Test(.enabled(if: CrossAppE2ETests.enabled))
    func theAppReadsWhatTheCLIWroteAndTheCLIReadsWhatTheAppSaves() throws {
        let configDir = URL(fileURLWithPath: Self.env["IMP_E2E_CONFIG_HOME"]!)
        let home = URL(fileURLWithPath: Self.env["IMP_E2E_HOME"]!)
        let expectedModel = Self.env["IMP_E2E_MODEL"] ?? "openai/gpt-6-luna"
        let suite = "app.imp.e2e.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let config = SharedConfigStore(configDir: configDir, homeDir: home)
        let app = AppModel(persist: true, config: config, defaults: defaults)

        // 1. What the CLI wrote, as the Mac app reads it.
        let pip = try #require(app.prefs.imps.first { $0.name == "Pip" }, "the app sees the Imp the CLI made")
        #expect(pip.about == "A tiny test helper", "description -> About")
        let colour = try #require(SharedMapping.hue(fromHex: "#e0533d"))
        #expect(abs(pip.hue - colour) < 0.001, "color -> hue")
        let service = try #require(app.prefs.ai.services.first { $0.name == "Live" }, "the provider is a service")
        #expect(app.prefs.ai.service(in: pip.brain)?.id == service.id, "Pip's brain is that service")
        #expect(app.prefs.ai.model(in: pip.brain) == expectedModel, "Pip's model")
        #expect(config.hasKey(for: service.id), "the key the CLI saved counts as keyed")
        #expect((config.key(for: service.id) ?? "").isEmpty == false, "the key is read from auth.json (not printed)")
        #expect(!pip.usesShell, "the shell deny rule reads as the shell switch off")
        #expect(pip.uses(.animations), "a tool group with no rule is on")
        let den = try #require(app.prefs.mcpServers.first { $0.name == "den" }, "the MCP server is in the app")
        #expect(den.transport == .http && den.url == "http://localhost:8080/mcp")
        #expect(pip.servers.contains(den.id), "Pip uses the server")
        #expect(app.prefs.requests.retries == 5, "requests.retries from `imp config set`")

        // 2. The app changes it: a new description, a second Imp, one tool group switched off, retries.
        let pipIndex = try #require(app.prefs.imps.firstIndex { $0.name == "Pip" })
        app.prefs.imps[pipIndex].about = "Edited in the Mac app"
        app.prefs.imps[pipIndex].setUses(.animations, false)
        let newcomer = app.addImp()
        let newIndex = try #require(app.prefs.imps.firstIndex { $0.id == newcomer })
        app.prefs.imps[newIndex].name = "Ada"
        app.prefs.imps[newIndex].about = "Second helper, made in the Mac app"
        app.prefs.requests.retries = 6
        app.flushSave()

        // 3. The files now hold the app's changes, and what the CLI wrote is still there.
        let again = config.load().prefs
        #expect(again.imps.first { $0.name == "Pip" }?.about == "Edited in the Mac app")
        #expect(again.imps.first { $0.name == "Ada" }?.about == "Second helper, made in the Mac app")
        #expect(again.imps.first { $0.name == "Pip" }?.uses(.animations) == false)
        #expect(again.imps.first { $0.name == "Pip" }?.usesShell == false, "the CLI's deny survives the app's save")
        #expect(again.mcpServers.contains { $0.name == "den" }, "the CLI's server survives the app's save")
        #expect(again.requests.retries == 6)
        #expect(config.hasKey(for: service.id), "the CLI's key survives the app's save")
    }
}
