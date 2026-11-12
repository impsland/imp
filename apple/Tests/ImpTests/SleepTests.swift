import Foundation
import Testing
import ImpKit
@testable import Imp

/// An Imp without a brain it can use sleeps, wherever its body is: at home on this Mac, moved home
/// from an iPhone, or visiting from a device whose Imp has none. Nothing it does (a reaction, a tool
/// step, an animation) shows it awake, and asking it is refused at once.
@MainActor @Suite struct SleepTests {
    /// A Mac with one service that needs no key: an Imp that uses it can think.
    private func appWithLocalService() -> (AppModel, Service) {
        let app = AppModel(persist: false)
        let local = Service(name: "Studio", baseURL: "http://localhost:1234/v1", model: "qwen")
        app.prefs.ai.add(local)
        app.assistant.configure(ai: app.prefs.ai, servers: [], keychain: false)
        return (app, local)
    }

    @Test func anImpWithoutABrainSleepsThroughAReaction() {
        let app = AppModel(persist: false)
        let imp = ImpModel(id: app.prefs.imps[0].id, app: app)
        #expect(!imp.isReady)
        imp.react(.happy, for: 5)
        #expect(imp.mood(at: Date()) == .sleepy)
    }

    @Test func anImpWithABrainStillShowsItsReaction() {
        let (app, _) = appWithLocalService()
        let imp = ImpModel(id: app.prefs.imps[0].id, app: app)
        #expect(imp.isReady)
        imp.react(.happy, for: 5)
        #expect(imp.mood(at: Date()) == .happy)
    }

    /// Moved home from an iPhone where it had no brain: the Mac's own service is not its brain.
    @Test func aPocketImpWithoutABrainSleepsAfterMovingHome() throws {
        let (app, _) = appWithLocalService()
        var pocket = PocketImp(name: "Pip")
        pocket.brain = PocketService()
        let (kit, secrets) = try pocket.adoption(secrets: NoSecrets())
        _ = try app.prefs.adopt(kit: kit, as: pocket.id, secrets: secrets)
        let imp = ImpModel(id: pocket.id, app: app)
        #expect(!imp.isReady)
        imp.react(.excited, for: 5)
        #expect(imp.mood(at: Date()) == .sleepy)
    }

    /// Shaken over from an iPhone where it has no brain: its home is connected and says so.
    /// Its home's animations, its work and the moods it sends must not wake it here.
    @Test func aVisitorWhoseHomeHasNoBrainSleepsWhateverItDoes() {
        let (app, _) = appWithLocalService()
        let look = LinkImp(id: UUID(), name: "Pip", hue: 0.3, scale: 1, traits: .plain)
        let visiting = Visiting(look: look, homeID: UUID(), homeName: "iPhone",
                                wakefulness: .visiting(homeConnected: true, homeSaysReady: false), side: .left, from: UUID())
        let imp = ImpModel(id: look.id, app: app, visiting: visiting)
        imp.heard(mood: Mood.working.rawValue)
        imp.react(.excited, for: 5)
        #expect(imp.activity != nil)
        #expect(imp.mood(at: Date()) == .sleepy)
        // Asking it is refused at once: no text box, no question sent, a sentence that says why.
        imp.startTyping()
        #expect(imp.bubble?.phase == .hint)
        #expect(imp.bubble?.text.contains("no brain") == true)
        #expect(imp.work == nil)
    }

    /// The same visitor once its home has a brain for it: awake, and its moods show.
    @Test func aVisitorWhoseHomeHasABrainIsAwake() {
        let (app, _) = appWithLocalService()
        let look = LinkImp(id: UUID(), name: "Pip", hue: 0.3, scale: 1, traits: .plain)
        let visiting = Visiting(look: look, homeID: UUID(), homeName: "iPhone",
                                wakefulness: .visiting(homeConnected: true, homeSaysReady: true), side: .left, from: UUID())
        let imp = ImpModel(id: look.id, app: app, visiting: visiting)
        imp.react(.excited, for: 5)
        #expect(imp.mood(at: Date()) == .excited)
        imp.startTyping()
        #expect(imp.bubble?.phase == .typing)
    }

    /// At home without a brain: asking is refused at once with the way to the Brain tab, and a
    /// wake-up trigger leaves it asleep.
    @Test func anImpWithoutABrainRefusesAtOnceAndStaysAsleep() {
        let app = AppModel(persist: false)
        let imp = ImpModel(id: app.prefs.imps[0].id, app: app)
        imp.startTyping()
        let bubble = imp.bubble
        #expect(bubble?.phase == .hint)
        #expect(bubble?.link == .settings)
        #expect(bubble?.text.contains("Brain tab") == true)
        imp.wakeUp(playing: nil)
        #expect(imp.mood(at: Date()) == .sleepy)
        #expect(imp.sleepReason != nil)
    }
}

/// A phone with no secrets kept.
private struct NoSecrets: PocketSecrets {
    func get(_ slot: PocketSlot, imp: UUID) -> String? { nil }
    func set(_ value: String, _ slot: PocketSlot, imp: UUID) {}
    func remove(_ slot: PocketSlot, imp: UUID) {}
}
