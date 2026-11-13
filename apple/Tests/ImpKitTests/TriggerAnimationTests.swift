import Foundation
import Testing
@testable import ImpKit

/// A trigger plays a made animation: the Imp names it as it knows it, and kits keep the link wherever they land.
@Suite struct TriggerAnimationTests {
    static func troupe() -> (prefs: ImpPreferences, pip: UUID, delight: UUID) {
        var prefs = ImpPreferences()
        let pip = ImpProfile(name: "Pip", hue: 0.2, favoriteHue: 0.3, personality: "")
        prefs.imps = [pip]
        let delight = prefs.save(MadeAnimation(name: "hn_delight", beats: [AnimationBeat(duration: 1, mood: "happy")]), for: pip.id)
        return (prefs, pip.id, delight)
    }

    static func args(_ animation: String) throws -> JSONValue {
        try JSONValue(jsonString: #"{"name":"HN","when":{"kind":"website","text":"news.ycombinator.com"},"do":"play","animation":"\#(animation)"}"#)
    }

    /// The case from the field: the animation it had just made, by the name it gave it.
    @Test func theToolTakesAMadeAnimationByName() throws {
        let (prefs, pip, delight) = Self.troupe()
        for name in ["hn_delight", "HN_Delight", "hn delight", "hn-delight", "custom-\(delight.uuidString)"] {
            let s = try Shortcut(tool: Self.args(name), imp: pip) { prefs.ref(named: $0, imp: pip) }
            #expect(s.animation == .custom(delight), "\(name)")
            #expect(s.toolDescription(animationName: prefs.animationName(s.animation!, imp: pip)).contains("“hn_delight”"))
        }
        // Built-in ones by id or title, as before.
        let wave = try Shortcut(tool: Self.args("greet"), imp: pip) { prefs.ref(named: $0, imp: pip) }
        #expect(wave.animation == .preset(.greet))
    }

    @Test func anUnknownNameSaysWhatToGive() throws {
        let (prefs, pip, _) = Self.troupe()
        #expect(throws: ToolArgumentError.self) { try Shortcut(tool: Self.args("nope"), imp: pip) { prefs.ref(named: $0, imp: pip) } }
        do { _ = try Shortcut(tool: Self.args("nope"), imp: pip) { prefs.ref(named: $0, imp: pip) } } catch {
            #expect(error.localizedDescription.contains("imp_play_animations"))
        }
    }

    @Test func anImpsTriggerKeepsItsAnimationThroughAKit() throws {
        var (prefs, pip, delight) = Self.troupe()
        prefs.shortcuts.append(Shortcut(name: "HN", prompt: "", performer: pip, usesClipboard: false,
                                        trigger: Trigger(.website), command: .play, animation: .custom(delight)))
        let text = Kit.exporting(imps: [pip], from: prefs).json()
        #expect(text.contains(#""animation": "hn_delight""#), "a name, not an id that means nothing elsewhere")
        let kit = try Kit.parse(text)
        var other = ImpPreferences()
        let added = other.add(kit, imps: Set(kit.imps.map(\.id)), triggers: [], servers: [], for: nil)
        let new = try #require(added.imps.first?.id)
        let trigger = try #require(other.shortcuts(of: new).first { $0.command == .play })
        let made = try #require(other.ownAnimations(of: new).first)
        #expect(trigger.animation == .custom(made.id) && made.title == "hn_delight")
    }

    @Test func aSharedTriggerBringsItsAnimation() throws {
        let (prefs, pip, delight) = Self.troupe()
        let trigger = Shortcut(name: "HN", prompt: "", performer: pip, usesClipboard: false,
                               trigger: Trigger(.website), command: .play, animation: .custom(delight))
        let kit = try Kit.parse(prefs.kit(sharing: trigger, named: "HN", imp: pip).json())
        #expect(kit.animations.map(\.title) == ["hn_delight"] && kit.problems.isEmpty)
        var other = ImpPreferences()
        let bo = ImpProfile(name: "Bo", hue: 0.6, favoriteHue: 0.6, personality: "")
        other.imps = [bo]
        other.add(kit, triggers: Set(kit.triggers.map(\.id)), servers: [], animations: Set(kit.animations.map(\.id)), for: bo.id)
        let made = try #require(other.ownAnimations(of: bo.id).first)
        #expect(other.shortcuts.last?.animation == .custom(made.id))

        // The animation left out: the trigger plays one there by that name, or nothing (never a dead id).
        var bare = ImpPreferences()
        bare.imps = [bo]
        bare.add(kit, triggers: Set(kit.triggers.map(\.id)), servers: [], for: bo.id)
        #expect(bare.shortcuts.last?.animation == nil)
    }

    @Test func theUntrustedNoteSaysHowToChangeIt() {
        let note = Briefing.untrusted(device: "Anna's iPhone", home: "Studio Mac")
        #expect(note.contains("Mine") && note.contains("Studio Mac") && note.contains("messages to other Imps"))
    }
}
