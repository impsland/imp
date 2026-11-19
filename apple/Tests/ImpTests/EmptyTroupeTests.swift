import Foundation
import Testing
import ImpKit
@testable import Imp

/// An empty troupe is a calm, valid state: nothing refills it, and an Imp is hatched only with its Brain.
@MainActor @Suite struct EmptyTroupeTests {
    @Test func emptyPreferencesStayEmptyAfterTheTroupeSyncs() {
        let app = AppModel(persist: false)
        app.prefs = ImpPreferences()
        app.prefs.firstRunSeen = true      // any change makes the preferences sync again
        #expect(app.prefs.imps.isEmpty && app.imps.isEmpty)
        #expect(!app.isReady, "with no Imp nothing is ready")
    }

    @Test func hatchingWithABrainAddsOneImpHoldingIt() throws {
        let app = AppModel(persist: false)
        app.prefs = ImpPreferences()
        let profile = app.prefs.nextImp()
        let brain = FirstRunBrain(name: "Studio", baseURL: "http://localhost:1234/v1", model: "qwen", key: "", isLocal: true)
        let id = try app.adoptFirstRunBrain(brain, for: .newImp(profile))
        #expect(id == profile.id && app.prefs.imps.map(\.id) == [id])
        #expect(app.prefs.ai.services.count == 1)
        #expect(app.isReady(id))
    }

    @Test func theLastImpMaySayGoodbye() {
        let app = AppModel(persist: false)
        app.prefs = ImpPreferences()
        app.prefs.imps = [.imp]
        let id = app.prefs.imps[0].id
        #expect(app.sayGoodbye(id) == nil)
        #expect(app.prefs.imps.isEmpty && app.imps.isEmpty)
    }
}
