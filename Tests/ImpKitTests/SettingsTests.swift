import Foundation
import Testing
@testable import ImpKit

@Suite struct PreferencesTests {
    @Test func roundTrip() throws {
        var p = ImpPreferences()
        p.ai.brain.model = "x/y"
        p.shortcuts = [Shortcut(name: "Translate", hotkey: Hotkey(keyCode: 79), prompt: "Translate into English.")]
        p.shortcuts[0].prompt = "custom"
        let back = try JSONDecoder().decode(ImpPreferences.self, from: JSONEncoder().encode(p))
        #expect(back == p)
    }

    @Test func settingsSavedBeforeMediaAutoplayStillLoad() throws {
        var p = ImpPreferences()
        p.ai.brain.model = "kept"
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(p)) as! [String: Any]
        json.removeValue(forKey: "mediaAutoplay")                    // as written by an older version
        let old = try JSONDecoder().decode(ImpPreferences.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(old.ai.brain.model == "kept" && old.autoplaysMedia)
        p.autoplaysMedia = false
        #expect(try JSONDecoder().decode(ImpPreferences.self, from: JSONEncoder().encode(p)).autoplaysMedia == false)
    }
}

@Suite struct ServiceTests {
    @Test func nothingIsBuiltIn() {
        let ai = AIConfig()
        #expect(ai.services.isEmpty && ai.service() == nil && ai.brain.model.isEmpty)
    }

    @Test func theFirstServiceBecomesTheDefault() {
        var ai = AIConfig()
        let a = Service(name: "A", baseURL: "https://a.example/v1"), b = Service(name: "B", baseURL: "http://localhost:1234/v1")
        ai.add(a)
        ai.add(b)
        #expect(ai.brain.service == a.id)
        ai.remove(service: a.id)
        #expect(ai.brain.service == b.id)
        ai.remove(service: b.id)
        #expect(ai.brain.service == nil && ai.service() == nil)
    }

    @Test func aBrainWithoutAServiceUsesTheDefaults() {
        var ai = AIConfig()
        let own = Brain(model: "small")
        #expect(ai.service(in: own) == nil)
        let a = Service(name: "A", baseURL: "https://a.example/v1")
        ai.add(a)
        #expect(ai.service(in: own)?.id == a.id)
        #expect(ai.model(in: own) == "small")
        ai.brain.model = "big"
        #expect(ai.model(in: Brain()) == "big" && ai.model() == "big")
    }

    @Test func aBrainWithoutAModelUsesItsServices() {
        var ai = AIConfig()
        let a = Service(name: "A", baseURL: "https://a.example/v1", model: "a/model")
        let b = Service(name: "B", baseURL: "https://b.example/v1", model: "b/model")
        ai.add(a)
        ai.add(b)
        #expect(ai.defaultService == a.id)
        #expect(ai.model() == "a/model" && ai.model(in: Brain()) == "a/model")
        #expect(ai.model(in: Brain(service: b.id)) == "b/model")
        #expect(ai.model(in: Brain(service: b.id, model: "mine")) == "mine")
        ai.defaultService = b.id
        #expect(ai.model(in: nil) == "b/model")                // new Imps follow the starred service
        ai.setModel("  ", for: b.id)
        #expect(ai.services[1].model.isEmpty && ai.model(in: Brain(service: b.id)).isEmpty)
    }

    @Test func servicesSavedWithoutAModelStillLoad() throws {
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(Service(name: "A", baseURL: "https://a.example/v1", model: "m"))) as! [String: Any]
        json.removeValue(forKey: "defaultModel")                   // as written by an older version
        let old = try JSONDecoder().decode(Service.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(old.name == "A" && old.model.isEmpty)
    }

    @Test func modelsMoveFromBrainsToServices() {
        var p = ImpPreferences()
        let a = Service(name: "A", baseURL: "https://a.example/v1"), b = Service(name: "B", baseURL: "https://b.example/v1")
        p.ai.add(a)
        p.ai.add(b)
        p.ai.brain.model = "a/default"                          // how an older version kept it
        var pip = ImpProfile(name: "Pip", hue: 0, favoriteHue: 0.5, personality: "")
        pip.brain = Brain(service: b.id, model: "b/model")
        var bob = ImpProfile(name: "Bob", hue: 0, favoriteHue: 0.5, personality: "")
        bob.brain = Brain(service: a.id, model: "a/other")
        p.imps = [p.imps[0], pip, bob]
        let before = p.imps.map { p.ai.model(in: $0.brain) }
        p.upgrade()
        #expect(p.ai.services.map(\.model) == ["a/default", "b/model"])
        #expect(p.imps[1].brain?.model == "")                   // now just follows B
        #expect(p.imps[2].brain?.model == "a/other")            // its own pick stays its own
        #expect(p.imps.map { p.ai.model(in: $0.brain) } == before)
        let once = p
        p.upgrade()
        #expect(p == once)
    }

    @Test func localDetectionAndLabel() {
        #expect(Service(name: "", baseURL: "http://localhost:11434/v1").isLocal)
        #expect(Service(name: "", baseURL: "http://studio.local:1234/v1").isLocal)
        #expect(!Service(name: "", baseURL: "https://api.example.com/v1").isLocal)
        #expect(Service(name: " ", baseURL: "https://api.example.com/v1").label == "api.example.com")
        #expect(Service(name: "Mine", baseURL: "nope").label == "Mine")
    }
}

@Suite struct PreferencesStoreTests {
    private func scratch() -> (UserDefaults, String) {
        let suite = "imp-tests-\(UUID().uuidString)"
        return (UserDefaults(suiteName: suite)!, suite)
    }

    @Test func savesAndLoads() {
        let (defaults, suite) = scratch()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = PreferencesStore(defaults: defaults)
        var p = ImpPreferences()
        p.ai.add(Service(name: "Local", baseURL: "http://localhost:1234/v1"))
        p.shortcuts = [Shortcut(name: "Translate", prompt: "Translate into English.")]
        store.save(p)
        #expect(store.load() == p)
    }

    @Test func anOlderFormatIsAFreshStart() {
        let (defaults, suite) = scratch()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(Data(#"{"api":{"providers":[]}}"#.utf8), forKey: PreferencesStore.key)
        #expect(PreferencesStore(defaults: defaults).load() == ImpPreferences())
    }
}
