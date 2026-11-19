import Foundation
import Testing
@testable import ImpKit

/// A trigger plays a made animation by its name, and kits bring the animation along wherever they land.
@Suite struct TriggerAnimationTests {
    static func troupe() -> (prefs: ImpPreferences, pip: UUID, delight: UUID) {
        var prefs = ImpPreferences.withWaitingImp()
        let pip = ImpProfile(name: "Pip", hue: 0.2, favoriteHue: 0.3, personality: "")
        prefs.imps = [pip]
        let delight = prefs.save(MadeAnimation(name: "hn_delight", beats: [AnimationBeat(duration: 1, mood: "happy")]), for: pip.id)
        return (prefs, pip.id, delight)
    }

    static func args(_ animation: String) throws -> JSONValue {
        try JSONValue(jsonString: #"{"name":"HN","on":"website","value":"news.ycombinator.com","do":[{"act":"play","value":"\#(animation)"}]}"#)
    }

    /// The case from the field: the animation it had just made, by the name it gave it.
    @Test func aPlayStepNamesAMadeAnimationAndTheImpFindsIt() throws {
        let (prefs, pip, delight) = Self.troupe()
        for name in ["hn_delight", "HN_Delight", "hn delight", "hn-delight", "custom-\(delight.uuidString)"] {
            let s = try Shortcut(tool: Self.args(name), imp: pip)
            #expect(s.steps.first?.animationName == name)
            #expect(prefs.ref(named: name, imp: pip) == .custom(delight), "\(name)")
        }
    }

    @Test func anImpsTriggerBringsItsAnimationThroughAKit() throws {
        var (prefs, pip, _) = Self.troupe()
        let trigger = Shortcut(name: "HN", performer: pip, trigger: Trigger(.website, value: "news.ycombinator.com"),
                               steps: [Step(.play, value: "hn_delight"), Step(.say, value: "Ooh")])
        prefs.shortcuts.append(trigger)
        let kit = try Kit.parse(prefs.kit(sharing: trigger, named: "HN", imp: pip).json())
        #expect(kit.animations.map(\.title) == ["hn_delight"] && kit.problems.isEmpty)
        #expect(kit.triggers.first?.steps.map(\.act) == [.play, .say])
        var other = ImpPreferences.withWaitingImp()
        let bo = ImpProfile(name: "Bo", hue: 0.6, favoriteHue: 0.6, personality: "")
        other.imps = [bo]
        other.add(kit, triggers: Set(kit.triggers.map(\.id)), servers: [], animations: Set(kit.animations.map(\.id)), for: bo.id)
        let made = try #require(other.ownAnimations(of: bo.id).first)
        #expect(made.title == "hn_delight")
        #expect(other.ref(named: other.shortcuts.last?.steps.first?.animationName ?? "", imp: bo.id) == .custom(made.id))
    }

    @Test func theUntrustedNoteSaysHowToChangeIt() {
        let note = Briefing.untrusted(device: "Anna's iPhone", home: "Studio Mac")
        #expect(note.contains("Mine") && note.contains("Studio Mac") && note.contains("messages to other Imps"))
    }
}
