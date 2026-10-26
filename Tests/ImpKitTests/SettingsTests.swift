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
