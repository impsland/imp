import Foundation
import Testing
@testable import ImpKit

@Suite struct TroupeTests {
    @Test func defaultsToOneRedImpWaitingInTheWindow() {
        let p = ImpPreferences()
        #expect(p.imps.count == 1)
        #expect(p.imps[0].id == ImpProfile.defaultID && p.imps[0].hue == 0 && p.imps[0].brain == nil)
        #expect(!p.imps[0].isActive)
        // It chats and has a shell, and nothing else: no borrowed tools, and no triggers but the
        // two clicks every Imp shares (one types, two open settings).
        #expect(p.shortcuts.map(\.trigger) == [.clicks(1), .clicks(2)] && p.shortcuts.allSatisfy { $0.performer == nil })
        #expect(p.imps[0].servers.isEmpty)
        #expect(p.imps[0].usesShell)
    }

    @Test func performerFallsBackWhenMissingOrDeactivated() {
        var p = ImpPreferences()
        p.imps[0].isActive = true
        let pip = ImpProfile.newcomer(joining: p.imps)
        p.imps.append(pip)
        var action = Shortcut(name: "Translate", hotkey: Hotkey(keyCode: 79), prompt: "Translate into English.")
        #expect(p.performer(of: action, fallback: ImpProfile.defaultID) == ImpProfile.defaultID)
        action.performer = pip.id
        #expect(p.performer(of: action, fallback: ImpProfile.defaultID) == pip.id)
        p.imps[1].isActive = false
        #expect(p.performer(of: action, fallback: ImpProfile.defaultID) == ImpProfile.defaultID)
        p.imps.removeLast()
        #expect(p.performer(of: action, fallback: ImpProfile.defaultID) == ImpProfile.defaultID)
    }

    @Test func onlyActivatedImpsListenAndRunServers() {
        var p = ImpPreferences()
        let server = MCPServerConfig(name: "Files", transport: .stdio, command: "npx")
        p.mcpServers = [server]
        p.imps[0].servers = [server.id]
        var translate = Shortcut(name: "Translate", hotkey: Hotkey(keyCode: 79), prompt: "Translate into English.")   // F18
        translate.performer = ImpProfile.defaultID
        p.shortcuts = [translate]
        #expect(p.liveShortcuts.isEmpty && p.liveServers.isEmpty)
        p.imps[0].isActive = true
        #expect(p.liveShortcuts.map(\.id) == [translate.id])
        #expect(p.liveServers.map(\.id) == [server.id])
        p.removeServer(server.id)
        #expect(p.mcpServers.isEmpty && p.imps[0].servers.isEmpty)
    }

    @Test func newcomersHatchRedWithTheirOwnNameAndASecretFavourite() {
        var troupe = [ImpProfile.imp]
        for _ in 0..<4 { troupe.append(.newcomer(joining: troupe)) }
        #expect(troupe.allSatisfy { $0.hue == ImpProfile.defaultHue })
        #expect(Set(troupe.map(\.name)).count == troupe.count)
        #expect(troupe.dropFirst().allSatisfy { $0.personality.contains($0.name) })
        // The first Imp loves red (and wears it). The others love a palette colour that isn't red.
        #expect(troupe[0].favoriteHue == 0 && troupe[0].isFavorite(troupe[0].hue))
        #expect(troupe.dropFirst().allSatisfy { p in
            p.favoriteHue != 0 && ImpProfile.colors.contains { $0.hue == p.favoriteHue } && !p.isFavorite(p.hue)
        })
    }

    @Test func removingAServiceFixesEveryBrain() {
        var p = ImpPreferences()
        let cloud = Service(name: "Cloud", baseURL: "https://cloud.example/v1", model: "cloud-model")
        let local = Service(name: "Local", baseURL: "http://localhost:11434/v1", model: "llama")
        p.ai.add(cloud)
        p.ai.add(local)
        var pip = ImpProfile.newcomer(joining: p.imps)
        pip.brain = Brain(service: local.id, model: "llama:70b")
        var mo = ImpProfile.newcomer(joining: p.imps + [pip])
        mo.brain = Brain(service: cloud.id, model: "cloud-big")
        p.imps += [pip, mo]
        p.removeService(local.id)
        // Pip follows the default again: its service and that service's model, not the one it picked
        // for the service that's gone (that model would only fail on another service).
        #expect(p.imps[1].brain == nil)
        #expect(p.ai.service(in: p.imps[1].brain)?.id == cloud.id)
        #expect(p.ai.model(in: p.imps[1].brain) == "cloud-model")
        #expect(p.imps[2].brain == Brain(service: cloud.id, model: "cloud-big"))
        p.removeService(cloud.id)
        #expect(p.imps.allSatisfy { $0.brain == nil })
        #expect(p.ai.service(in: p.imps[1].brain) == nil && p.ai.model(in: p.imps[1].brain).isEmpty)
    }

    @Test func removingTheDefaultResetsModelsPickedForIt() {
        var p = ImpPreferences()
        let first = Service(name: "First", baseURL: "https://first.example/v1", model: "one")
        let second = Service(name: "Second", baseURL: "https://second.example/v1", model: "two")
        p.ai.add(first)
        p.ai.add(second)
        p.ai.brain.model = "legacy-one"
        var pip = ImpProfile.newcomer(joining: p.imps)
        pip.brain = Brain(service: nil, model: "one-mini")          // the default service, its own model
        var mo = ImpProfile.newcomer(joining: p.imps + [pip])
        mo.brain = Brain(service: second.id, model: "two-mini")
        p.imps += [pip, mo]
        p.removeService(first.id)
        #expect(p.ai.defaultService == second.id)
        #expect(p.ai.brain.model.isEmpty)
        #expect(p.imps[1].brain == nil && p.ai.model(in: p.imps[1].brain) == "two")
        #expect(p.imps[2].brain == Brain(service: second.id, model: "two-mini"))
    }

    @Test func removingAnotherServiceKeepsTheDefaultsModels() {
        var p = ImpPreferences()
        let first = Service(name: "First", baseURL: "https://first.example/v1", model: "one")
        let other = Service(name: "Other", baseURL: "https://other.example/v1", model: "x")
        p.ai.add(first)
        p.ai.add(other)
        var pip = ImpProfile.newcomer(joining: p.imps)
        pip.brain = Brain(service: nil, model: "one-mini")
        p.imps.append(pip)
        p.removeService(other.id)
        #expect(p.imps[1].brain == Brain(service: nil, model: "one-mini"))
    }

    @Test func troupeRoundTrips() throws {
        var p = ImpPreferences()
        var pip = ImpProfile.newcomer(joining: p.imps)
        pip.usesShell = false
        p.imps.append(pip)
        var action = Shortcut(name: "Translate", hotkey: Hotkey(keyCode: 79), prompt: "Translate into English.")
        action.performer = pip.id
        p.shortcuts = [action]
        #expect(try JSONDecoder().decode(ImpPreferences.self, from: JSONEncoder().encode(p)) == p)
    }


    @Test func contagionIsResponseNotCopy() {
        #expect(Contagion.response(to: .reacted(.dizzy)) == .laugh)
        #expect(Contagion.response(to: .reacted(.jump)) == .jump)
        #expect(Contagion.response(to: .answered) == .smile)
        #expect(Contagion.response(to: .failed) == .wow)
    }
}

@Suite struct ToolSetTests {
    struct Fixed: ToolProvider {
        let name: String
        func tools() async -> [ToolSpec] { [ToolSpec(name: name, description: "")] }
        func call(_ n: String, arguments: String) async throws -> String { "\(name):\(arguments)" }
    }

    @Test func routesCallsToTheRightMember() async throws {
        let set = ToolSet([Fixed(name: "files__read"), Fixed(name: "shell")])
        #expect(await set.tools().map(\.name) == ["files__read", "shell"])
        #expect(try await set.call("shell", arguments: "{}") == "shell:{}")
        await #expect(throws: Error.self) { try await set.call("nope", arguments: "{}") }
    }

    @Test func functionNamesAreSafe() {
        #expect(ToolSet.functionName("ask_Мила & Co") == "ask" + String(repeating: "_", count: 8) + "Co")
        #expect(ToolSet.functionName(String(repeating: "x", count: 80)).count == 64)
    }
}

@Suite struct SystemPromptTests {
    @Test func builtInInstructionsFollowThePersonality() {
        let imp = ImpProfile(name: "Pip", hue: 0, favoriteHue: 0.5, personality: "You are Pip.")
        #expect(imp.instructions == nil)
        let workspace = Workspace.directory(for: imp.id).path
        #expect(imp.systemPrompt == "You are Pip.\n\n" + Briefing.display.replacingOccurrences(of: "{workspace}", with: workspace))
        #expect(imp.systemPrompt.contains("Your workspace folder is \(workspace).") && !imp.systemPrompt.contains("{workspace}"))
    }

    @Test func ownInstructionsCanNameTheWorkspaceToo() {
        var imp = ImpProfile(name: "Pip", hue: 0, favoriteHue: 0.5, personality: "")
        imp.instructions = "Work in {workspace}."
        #expect(imp.systemPrompt == "Work in \(imp.workspace.path).")
    }

    @Test func memorySettingsDefaultOnAndLoadFromOlderProfiles() throws {
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(ImpProfile.imp)) as! [String: Any]
        json["sendsToolCalls"] = nil
        json["exchangesSent"] = nil
        var imp = try JSONDecoder().decode(ImpProfile.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(imp.remembersToolCalls && imp.memoryExchanges == ChatMemory.defaultExchanges)
        imp.sendsToolCalls = false
        imp.exchangesSent = 5
        #expect(!imp.remembersToolCalls && imp.memoryExchanges == 5)
    }

    @Test func ownInstructionsReplaceTheBuiltInOnes() {
        var imp = ImpProfile(name: "Pip", hue: 0, favoriteHue: 0.5, personality: "You are Pip.")
        imp.instructions = "Answer in haiku."
        #expect(imp.systemPrompt == "You are Pip.\n\nAnswer in haiku.")
        imp.instructions = "  "
        #expect(imp.systemPrompt == "You are Pip.")
    }

    @Test func savedProfilesWithoutInstructionsStillDecode() throws {
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(ImpProfile.imp)) as! [String: Any]
        json["instructions"] = nil
        let decoded = try JSONDecoder().decode(ImpProfile.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(decoded.instructions == nil)
    }
}
