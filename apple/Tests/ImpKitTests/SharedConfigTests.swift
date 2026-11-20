import Foundation
import ImpCore
import Testing
@testable import ImpKit

/// The Mac app's side of `docs/architecture/configuration.md`: the preferences mapped to and from the shared
/// files, through the core, in folders of their own (never the person's real ones).
private let fixtures = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("spec/fixtures/config")

private struct Home {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("imp-config-\(UUID().uuidString)")
    var config: URL { root.appendingPathComponent(".config/imp") }
    func store() -> SharedConfigStore { SharedConfigStore(configDir: config, homeDir: root) }
    var paths: ConfigPaths { ConfigPaths(configDir: config.path, homeDir: root.path) }
    func agent(_ name: String) -> URL { root.appendingPathComponent(".agents/agents/\(name).md") }

    /// A copy of the fixture home (without the project folders).
    static func fixture() throws -> Home {
        let h = Home()
        let fm = FileManager.default
        try fm.createDirectory(at: h.root, withIntermediateDirectories: true)
        for item in [".config", ".agents"] {
            try fm.copyItem(at: fixtures.appendingPathComponent("home/\(item)"), to: h.root.appendingPathComponent(item))
        }
        return h
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}

private func id(_ kind: String, _ key: String) -> UUID { SharedMapping.stableID(kind, key) }

/// Preferences with a value in every shared field, in the shape reading gives (names sorted, ids from names).
private func rich() -> ImpPreferences {
    var p = ImpPreferences()
    p.ai.services = [
        Service(id: id("provider", "cloud-ai"), name: "Cloud AI", baseURL: "https://api.example.com/v1", model: "big"),
        Service(id: id("provider", "local"), name: "Local", baseURL: "http://localhost:1234/v1", model: "qwen"),
    ]
    p.ai.brain.service = p.ai.services[0].id
    var files = MCPServerConfig(name: "files", transport: .stdio, command: "npx", arguments: ["-y", "srv", "~"], environment: ["A": "1"])
    files.id = id("mcp", "files")
    var web = MCPServerConfig(name: "web", transport: .http, url: "https://mcp.example.com/mcp", headers: ["X-Key": "k"])
    web.id = id("mcp", "web")
    web.isEnabled = false
    p.mcpServers = [files, web]
    p.shortcuts = [Shortcut(name: "Translate", hotkey: Hotkey(keyCode: 79), steps: [Step(.ask, value: "Translate into English.")])]
    p.customAnimations = [MadeAnimation(name: "Dance", beats: [AnimationBeat(duration: 1)])]
    var limits = p.requests
    limits.retries = 5
    limits.timeoutSeconds = 90
    p.requests = limits
    p.impTalk = .shared
    p.talkThreading = .recent
    p.talkWaiting = .wait
    p.talkWindowMinutes = 90
    p.hop = "hop.example.com:4677"
    var device = DeviceToolLimits()
    device.set(false, group: DeviceToolLimits.commands, on: UUID(uuidString: "11111111-1111-4111-8111-111111111111")!)
    p.deviceToolLimits = device

    var dot = ImpProfile(id: UUID(uuidString: "D0D0D0D0-0000-4000-8000-000000000001")!, name: "Dot", hue: 0.5, favoriteHue: 0.25, scale: 1.3,
                         personality: "You are Dot.\n\nBe brief.", brain: Brain(service: p.ai.services[0].id, model: "other"))
    dot.about = "Short answers"
    dot.instructions = ""
    dot.exchangesSent = 10
    dot.sendsToolCalls = false
    dot.newChatAtTokens = ImpProfile.newChatChoices.first
    dot.setUses(.look, false)
    dot.setUses(.computer, true)
    dot.setUses(tool: ToolRegistry.ownID(.personality, tool: "imp_speak"), false)
    dot.setUses(tool: ToolRegistry.mcpID(server: "files", tool: "read_file"), false)
    dot.usesShell = false
    dot.servers = [files.id]
    dot.ownAnimations = [MadeAnimation(name: "Spin", beats: [AnimationBeat(duration: 2)])]
    var traits = ImpTraits()
    traits.blush = 0.4
    dot.character = traits
    let pip = ImpProfile(id: UUID(uuidString: "1A1A1A1A-0000-4000-8000-00000000F00D")!, name: "Pip", hue: 0, favoriteHue: 0, personality: "You are Pip.")
    p.imps = [dot, pip]
    return p
}

@Suite struct SharedConfigMappingTests {
    @Test func providerIDsAreSafeAndUnique() {
        #expect(SharedMapping.providerID(for: "OpenRouter", avoiding: []) == "openrouter")
        #expect(SharedMapping.providerID(for: "My / Home #1", avoiding: []) == "my-home-1")
        #expect(SharedMapping.providerID(for: "OpenRouter", avoiding: ["openrouter"]) == "openrouter-2")
        #expect(SharedMapping.providerID(for: "OPENROUTER", avoiding: ["openrouter", "openrouter-2"]) == "openrouter-3")
        #expect(SharedMapping.providerID(for: "  ", avoiding: []) == "provider")
        #expect(SharedMapping.providerID(for: String(repeating: "a", count: 80), avoiding: []).count == 32)
    }

    @Test func agentNamesAreFileNames() {
        #expect(SharedMapping.agentName(for: "Pip 2", avoiding: []) == "Pip-2")
        #expect(SharedMapping.agentName(for: "Mochi", avoiding: ["mochi"]) == "Mochi-2", "file systems ignore case")
        #expect(SharedMapping.agentName(for: "日本", avoiding: []) == "imp")
        #expect(SharedMapping.agentName(for: "a_b-c", avoiding: []) == "a_b-c")
    }

    @Test func aHueIsAColourAndBack() {
        for hue in stride(from: 0.0, to: 1.0, by: 0.05) {
            let hex = SharedMapping.hex(forHue: hue)
            #expect(hex.count == 7 && hex.hasPrefix("#"))
            let back = try! #require(SharedMapping.hue(fromHex: hex))
            #expect(ImpProfile.hueDistance(back, hue) < 0.01, "\(hue) -> \(hex) -> \(back)")
        }
        #expect(SharedMapping.hue(fromHex: "red") == nil)
    }

    @Test func modelsAreProviderModelVariant() throws {
        let vectors = try JSONDecoder().decode(JSON.self, from: Data(contentsOf: fixtures.appendingPathComponent("vectors.json")))
        for v in try #require(vectors["model_refs"]?.array) {
            let text = try #require(v["text"]?.string)
            if v["error"]?.bool == true {
                #expect((try? modelRefParse(text: text)) == nil, "\(text)")
            } else {
                let parts = try modelRefParse(text: text)
                #expect(parts.provider == v["provider"]?.string && parts.model == v["model"]?.string && parts.variant == v["variant"]?.string)
                #expect(modelRefFormat(parts: parts) == text)
            }
        }
    }

    @Test func rulesDecideAsTheCoreVectorsSay() throws {
        let vectors = try JSONDecoder().decode(JSON.self, from: Data(contentsOf: fixtures.appendingPathComponent("vectors.json")))
        for c in try #require(vectors["decide"]?.array) {
            let rules = SharedMapping.rules(c["rules"])
            for check in c["checks"]?.array ?? [] {
                let want = check["effect"]?.string
                let got = permissionDecide(global: [], own: rules, action: check["action"]?.string ?? "", resource: check["resource"]?.string ?? "")
                #expect((got == .allow ? "allow" : got == .ask ? "ask" : "deny") == want, "\(c["name"]?.string ?? "")")
            }
        }
    }

    @Test func switchesAreTheFewestRules() {
        var imp = ImpProfile(name: "A", hue: 0, favoriteHue: 0, personality: "")
        func rules() -> [PermissionRule] {
            let agent = SharedMapping.writeAgent(imp, base: nil, global: [], servers: [], renamed: [:], providers: [:], ai: AIConfig(), isNew: true)
            return SharedMapping.rules(agent["permissions"])
        }
        #expect(rules().isEmpty, "the defaults need no rules")
        imp.setUses(.look, false)
        #expect(rules() == [PermissionRule(action: "look", resource: "*", effect: .deny)])
        imp.setUses(.computer, true)
        #expect(rules().contains(PermissionRule(action: "computer", resource: "*", effect: .allow)))
        imp.usesShell = false
        #expect(rules().contains(PermissionRule(action: "shell", resource: "*", effect: .deny)))
    }

    @Test func theFixtureHomeIsRead() throws {
        let home = try Home.fixture()
        defer { home.remove() }
        let store = home.store()
        let read = store.load()
        let p = read.prefs
        // The only thing to say is that the key `{env:OLLAMA_API_KEY}` names is not set (when it is not).
        #expect(store.diagnostics.allSatisfy { $0.contains("OLLAMA_API_KEY") }, "\(store.diagnostics)")
        // Providers come in the order of their ids (the file is a map).
        #expect(p.ai.services.map(\.name) == ["ollama", "OpenRouter"])
        #expect(p.ai.defaultService == id("provider", "openrouter") && p.ai.model() == "openai/gpt-6-luna")
        #expect(p.ai.services[0].baseURL == "https://ollama.example.com/v1")
        #expect(p.mcpServers.map(\.name) == ["den", "files"])
        #expect(p.mcpServers[1].command == "npx" && p.mcpServers[1].arguments.last == "~" && p.mcpServers[0].transport == .http)
        #expect(p.requests.timeoutSeconds == 120 && p.requests.retries == 3)
        #expect(p.hop == "hop.example.com:4677")
        // pip and review are Imps; retired is disabled, scout is a hidden subagent.
        #expect(p.imps.map(\.name) == ["pip", "review"])
        let pip = try #require(p.imps.first)
        #expect(pip.id == UUID(uuidString: "7c0e0000-0000-4000-8000-000000000001"))
        #expect(pip.about == "The first Imp" && pip.personality == "You are Pip, a small red imp.")
        #expect(pip.brain == Brain(service: id("provider", "ollama"), model: "qwen3.8"))
        #expect(!pip.uses(.triggers) && pip.uses(.look) && pip.usesShell)
        #expect(pip.exchangesSent == 20 && pip.scale == 1)
        #expect(pip.servers.count == 2, "tool servers are on for every Imp unless denied")
        #expect(SharedMapping.hex(forHue: pip.hue) != "#e0533d", "the swatch is its own; the file's colour is kept when the hue is not touched")
        #expect(p.imps[1].id == id("imp", "review") && p.imps[1].brain == nil)
        #expect(read.files[pip.id] == "pip")
    }

    @Test func everySharedFieldSurvivesTheFiles() throws {
        let home = Home()
        defer { home.remove() }
        let want = rich()
        try home.store().save(want)
        let store = home.store()
        let got = store.load().prefs
        #expect(store.diagnostics.isEmpty, "\(store.diagnostics)")
        #expect(got.ai == want.ai)
        #expect(got.mcpServers == want.mcpServers)
        #expect(got.shortcuts == want.shortcuts)
        #expect(got.animationLibrary == want.animationLibrary)
        #expect(got.requests == want.requests)
        #expect([got.impTalk, want.impTalk] == [.shared, .shared] && got.talkThreading == .recent && got.talkWaiting == .wait && got.talkWindowMinutes == 90)
        #expect(got.hop == want.hop && got.deviceToolLimits == want.deviceToolLimits)
        #expect(got.imps.count == 2)
        for (a, b) in zip(got.imps, want.imps) {
            #expect(a == b, "\(b.name)")
        }
        // Defaults are not written: a fresh file holds only what was set.
        let json = try #require(JSON(text: String(contentsOf: home.config.appendingPathComponent("imp.json"), encoding: .utf8)))
        #expect(json["model"]?.string == "cloud-ai/big" && json["imps"]?["Dot"]?["id"]?.string == "d0d0d0d0-0000-4000-8000-000000000001")
        #expect(json["providers"]?["cloud-ai"]?["name"]?.string == "Cloud AI" && json["mcp"]?["web"]?["disabled"]?.bool == true)
        let agent = try String(contentsOf: home.agent("Dot"), encoding: .utf8)
        #expect(agent.contains("mode: primary") && agent.contains("model: cloud-ai/other") && agent.contains("description: Short answers"))
    }

    @Test func savingWritesOnlyWhatChanged() throws {
        let home = try Home.fixture()
        defer { home.remove() }
        let store = home.store()
        var p = store.load().prefs
        #expect(try !store.save(p), "nothing changed: nothing is written")
        let before = try String(contentsOf: home.agent("pip"), encoding: .utf8)
        let review = try String(contentsOf: home.agent("review"), encoding: .utf8)
        p.imps[1].about = "Looks closely"
        #expect(try store.save(p))
        #expect(try String(contentsOf: home.agent("pip"), encoding: .utf8) == before, "the other Imp's file is not touched")
        #expect(try String(contentsOf: home.agent("review"), encoding: .utf8) != review)
        #expect(try !store.save(p))
        // What the file has that the app has no field for is kept.
        p.imps[0].about = "Changed"
        try store.save(p)
        let pip = try String(contentsOf: home.agent("pip"), encoding: .utf8)
        #expect(pip.contains("steps: 40") && pip.contains("X-Gateway-Tenant: engineering") && pip.contains("color: '#e0533d'") || pip.contains("color: \"#e0533d\""))
        #expect(pip.contains("description: Changed") && pip.contains("model: ollama/qwen3.8#high"), "the variant stays")
        let config = try String(contentsOf: home.config.appendingPathComponent("imp.json"), encoding: .utf8)
        #expect(config.contains("{env:OLLAMA_API_KEY}") && config.contains("X-Gateway-Tenant"), "references and unknown keys stay as written")
    }

    @Test func whatTheTerminalChangedMeanwhileStays() throws {
        let home = try Home.fixture()
        defer { home.remove() }
        let store = home.store()
        var p = store.load().prefs
        // `imp` adds a provider and changes an Imp, after the app read.
        try configUpdate(paths: home.paths, patchJson: #"{"providers":{"groq":{"options":{"baseURL":"https://groq.example.com/v1"}}},"requests":{"retries":9}}"#)
        try configUpdateAgent(paths: home.paths, name: "review", patchJson: #"{"description":"From the terminal"}"#)
        #expect(store.changedOutside())
        p.hop = "hop.other.example.com:4677"
        p.imps[0].about = "From the app"
        try store.save(p)
        let after = SharedMapping.read(SharedSnapshot(configLoad(paths: home.paths))).prefs
        #expect(after.ai.services.map(\.name).contains("groq") && after.requests.retries == 9, "the terminal's changes are kept")
        #expect(after.hop == "hop.other.example.com:4677" && after.imps[0].about == "From the app")
        #expect(after.imps[1].about == "From the terminal")
    }

    @Test func renamingAndRemovingAnImpMovesItsFiles() throws {
        let home = Home()
        defer { home.remove() }
        let store = home.store()
        try store.save(rich())
        var p = store.load().prefs
        let dot = p.imps[0].id
        p.imps[0].name = "Dotty"
        p.imps.remove(at: 1)
        #expect(try store.save(p))
        #expect(FileManager.default.fileExists(atPath: home.agent("Dotty").path) && !FileManager.default.fileExists(atPath: home.agent("Dot").path))
        #expect(!FileManager.default.fileExists(atPath: home.agent("Pip").path))
        let back = store.load().prefs
        #expect(back.imps.map(\.name) == ["Dotty"] && back.imps[0].id == dot, "the Imp keeps its id when its file is renamed")
        #expect(back.imps[0].servers == p.imps[0].servers && back.imps[0].exchangesSent == 10)
    }

    @Test func aNewImpIsAPrimaryAgentWithAnId() throws {
        let home = Home()
        defer { home.remove() }
        let store = home.store()
        var p = ImpPreferences()
        p.imps = [ImpProfile(name: "Pip 2", hue: 0.3, favoriteHue: 0.6, personality: "Hi")]
        try store.save(p)
        let text = try String(contentsOf: home.agent("Pip-2"), encoding: .utf8)
        #expect(text.contains("mode: primary") && text.hasSuffix("Hi\n"))
        let back = home.store().load().prefs
        #expect(back.imps.map(\.name) == ["Pip-2"] && back.imps[0].id == p.imps[0].id && back.imps[0].hue == 0.3 && back.imps[0].favoriteHue == 0.6)
    }

    @Test func keysAreInAuthJsonForThePersonOnly() throws {
        let home = try Home.fixture()
        defer { home.remove() }
        let store = home.store()
        store.load()
        let or = id("provider", "openrouter")
        #expect(!home.store().setKey("sk-1", for: or), "a service the store has not read is no provider yet")
        #expect(store.setKey("sk-1", for: or))
        #expect(store.hasKey(for: or) && store.key(for: or) == "sk-1")
        let mode = try FileManager.default.attributesOfItem(atPath: home.config.appendingPathComponent("auth.json").path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
        #expect(authKey(paths: home.paths, provider: "openrouter") == "sk-1", "the core finds what the app saved")
        #expect(!(try String(contentsOf: home.config.appendingPathComponent("imp.json"), encoding: .utf8)).contains("sk-1"), "keys are never in imp.json")
        #expect(store.setKey("", for: or) && !store.hasKey(for: or))
    }

    @Test func toolServerSignInsAreSharedByName() throws {
        let home = try Home.fixture()
        defer { home.remove() }
        let store = home.store()
        store.load()
        let auth = McpAuth(issuer: "https://auth.example.com", tokenEndpoint: "https://auth.example.com/token", clientId: "cid",
                           redirectUri: "app.imp:/oauth", accessToken: "AT", refreshToken: "RT", expiresAt: nil, scope: nil)
        let mcp = store.mcpAuth
        #expect(mcp.save(auth, for: "https://den.imp.land/mcp") && mcp.hasAuth(for: "https://den.imp.land/mcp"))
        #expect(try authMcpAll(paths: home.paths).map(\.server) == ["den"], "the core finds it under the server's name")
        #expect(mcp.clientID(issuer: "https://auth.example.com") == "cid")
        mcp.forget("https://den.imp.land/mcp")
        #expect(!mcp.hasAuth(for: "https://den.imp.land/mcp"))
    }

    @Test func theSkillsAndCommandsOfTheHomeAreListed() throws {
        let home = try Home.fixture()
        defer { home.remove() }
        let store = home.store()
        let library = store.library()
        #expect(library.skills.map(\.name) == ["notes"] && library.skills[0].description == "Take notes in the user's style")
        #expect(library.commands.map(\.name) == ["fix"] && library.commands[0].description == "Fix a bug")
        #expect(library.skills[0].path.hasSuffix(".agents/skills/notes/SKILL.md"))
        let pip = try #require(store.load().prefs.imps.first)
        #expect(store.agentFile(for: pip.id) == home.agent("pip"), "the Imp's file is the one `imp` reads")
    }

    @Test func whatIsLocalIsNotInTheFiles() throws {
        let home = Home()
        defer { home.remove() }
        var p = rich()
        p.appearance = .dark
        p.dictationLocale = "de-DE"
        p.imps[0].isActive = false
        p.imps[0].origin = CGPoint(x: 3, y: 4)
        p.imps[0].knowsFavorite = true
        try home.store().save(p)
        let files = try String(contentsOf: home.config.appendingPathComponent("imp.json"), encoding: .utf8) + (try String(contentsOf: home.agent("Dot"), encoding: .utf8))
        for word in ["appearance", "dark", "de-DE", "isActive", "origin", "knowsFavorite", "firstRun", "bubble"] { #expect(!files.contains(word), "\(word)") }
        var back = home.store().load().prefs
        back.apply(p.local)
        #expect(!back.imps[0].isActive && back.imps[0].origin == CGPoint(x: 3, y: 4) && back.appearance == .dark)
    }
}
