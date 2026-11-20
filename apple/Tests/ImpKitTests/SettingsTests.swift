import Foundation
import Testing
@testable import ImpKit

@Suite struct PreferencesTests {
    @Test func roundTrip() throws {
        var p = ImpPreferences.withWaitingImp()
        p.ai.brain.model = "x/y"
        p.shortcuts = [Shortcut(name: "Translate", hotkey: Hotkey(keyCode: 79), steps: [Step(.ask, value: "Translate into English.")])]
        p.shortcuts[0].steps = [Step(.ask, value: "custom")]
        let back = try JSONDecoder().decode(ImpPreferences.self, from: JSONEncoder().encode(p))
        #expect(back == p)
    }

    @Test func settingsSavedBeforeMediaAutoplayStillLoad() throws {
        var p = ImpPreferences.withWaitingImp()
        p.ai.brain.model = "kept"
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(p)) as! [String: Any]
        json.removeValue(forKey: "mediaAutoplay")                    // a key this version never wrote
        let old = try JSONDecoder().decode(ImpPreferences.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(old.ai.brain.model == "kept" && old.autoplaysMedia)
        p.autoplaysMedia = false
        #expect(try JSONDecoder().decode(ImpPreferences.self, from: JSONEncoder().encode(p)).autoplaysMedia == false)
    }
}

@Suite struct BubbleAppearanceTests {
    @Test func defaultsToSolid() {
        let a = BubbleAppearance()
        #expect(a.style == .solid && a.opacity == BubbleAppearance.defaultOpacity)
        #expect(ImpPreferences.withWaitingImp().bubbleAppearance == a)
    }

    @Test func opacityIsClamped() {
        #expect(BubbleAppearance(opacity: 0).opacity == BubbleAppearance.minimumOpacity)
        #expect(BubbleAppearance(opacity: 5).opacity == 1)
        var a = BubbleAppearance()
        a.opacity = -1
        #expect(a.opacity == BubbleAppearance.minimumOpacity)
        #expect(BubbleAppearance(opacity: .nan).opacity == BubbleAppearance.defaultOpacity)
    }

    @Test func roundTripsAndLoadsWithoutTheField() throws {
        var p = ImpPreferences.withWaitingImp()
        p.bubbleAppearance = BubbleAppearance(style: .translucent, opacity: 0.6)
        #expect(try JSONDecoder().decode(ImpPreferences.self, from: JSONEncoder().encode(p)).bubbleAppearance == p.bubbleAppearance)
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(ImpPreferences.withWaitingImp())) as! [String: Any]
        json.removeValue(forKey: "bubbleLook")
        let old = try JSONDecoder().decode(ImpPreferences.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(old.bubbleAppearance == BubbleAppearance())
        let bare = try JSONDecoder().decode(BubbleAppearance.self, from: Data("{}".utf8))
        #expect(bare == BubbleAppearance())
    }

    @Test func fillIsSolidWhenTheSystemAsksOrThereIsNoBlur() {
        let t = BubbleAppearance(style: .translucent, opacity: 0.6)
        #expect(t.fillOpacity(reduceTransparency: false, increaseContrast: false) == 0.6)
        #expect(t.fillOpacity(reduceTransparency: true, increaseContrast: false) == 1)
        #expect(t.fillOpacity(reduceTransparency: false, increaseContrast: true) == 1)
        #expect(t.fillOpacity(reduceTransparency: false, increaseContrast: false, canBlur: false) == 1)
        #expect(BubbleAppearance().fillOpacity(reduceTransparency: false, increaseContrast: false) == 1)
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
        var p = ImpPreferences.withWaitingImp()
        p.appearance = .dark
        p.controlInk = .black
        p.antics = false
        p.inputMaxLines = 5
        p.firstRunSeen = true
        p.dictationLocale = "de-DE"
        p.imps[0].isActive = false
        p.imps[0].origin = CGPoint(x: 10, y: 20)
        p.imps[0].knowsFavorite = true
        // What the configuration holds is not kept here.
        p.ai.add(Service(name: "Local", baseURL: "http://localhost:1234/v1"))
        p.shortcuts = [Shortcut(name: "Translate", hotkey: Hotkey(keyCode: 79), steps: [Step(.ask, value: "Translate into English.")])]
        store.save(p.local)
        let back = store.load()
        #expect(back == p.local)
        var restored = ImpPreferences.withWaitingImp()
        restored.apply(back)
        #expect(restored.appearance == .dark && restored.controlInk == .black && !restored.antics && restored.inputMaxLines == 5)
        #expect(restored.firstRunSeen && restored.dictationLocale == "de-DE")
        #expect(!restored.imps[0].isActive && restored.imps[0].origin == CGPoint(x: 10, y: 20) && restored.imps[0].knowsFavorite)
        #expect(restored.shortcuts.isEmpty && restored.ai.services.isEmpty, "services and triggers are in the configuration")
    }

    @Test func anOlderFormatIsAFreshStart() {
        let (defaults, suite) = scratch()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(Data(#"{"api":{"providers":[]}}"#.utf8), forKey: PreferencesStore.key)
        let loaded = PreferencesStore(defaults: defaults).load()
        #expect(loaded == LocalPreferences(), "a fresh install has the defaults")
    }

    @Test func aFreshInstallHasNoTriggers() {
        let (defaults, suite) = scratch()
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(ImpPreferences.withWaitingImp().shortcuts.isEmpty)
        #expect(PreferencesStore(defaults: defaults).load() == LocalPreferences())
    }
}
