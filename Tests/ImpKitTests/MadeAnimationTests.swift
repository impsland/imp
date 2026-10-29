import Foundation
import Testing
@testable import ImpKit

@Suite struct MadeAnimationTests {
    static let beats = [AnimationBeat(duration: 0.4, lookX: 0, lookY: 0.1, mood: "happy", hop: true),
                        AnimationBeat(duration: 0.8, mood: "content", glyph: "heart", tilt: 5)]

    static func troupe() -> (ImpPreferences, UUID, UUID) {
        var p = ImpPreferences()
        let pip = ImpProfile(name: "Pip", hue: 0.5, favoriteHue: 0.9, personality: "")
        p.imps.append(pip)
        return (p, p.imps[0].id, pip.id)
    }

    @Test func anImpsOwnVersionWinsOverTheSharedOneWhichWinsOverTheBuiltIn() {
        var (p, imp, pip) = Self.troupe()
        #expect(p.replacement(for: .jump, imp: pip) == nil)
        let shared = MadeAnimation(name: "", replaces: .jump, beats: Self.beats)
        p.save(shared, for: nil)
        #expect(p.replacement(for: .jump, imp: pip)?.id == shared.id && p.replacement(for: .jump, imp: imp)?.id == shared.id)
        let own = MadeAnimation(name: "", replaces: .jump, beats: [AnimationBeat(duration: 1)])
        p.save(own, for: pip)
        #expect(p.replacement(for: .jump, imp: pip)?.id == own.id)
        #expect(p.replacement(for: .jump, imp: imp)?.id == shared.id, "the others keep the shared one")
        p.removeAnimation(own.id)
        #expect(p.replacement(for: .jump, imp: pip)?.id == shared.id)
    }

    @Test func aSharedAnimationTakesAGestureFromTheBuiltInOne() {
        var (p, _, pip) = Self.troupe()
        let wave = MadeAnimation(name: "Wave", triggers: [.poke], beats: Self.beats)
        p.save(wave, for: nil)
        #expect(p.ref(for: .poke, imp: pip) == .custom(wave.id))
        #expect(p.animation(for: .poke) == nil, "Tantrum gave it up")
        p.setTrigger(.poke, true, for: .angry)
        #expect(p.ref(for: .poke, imp: pip) == .preset(.angry))
        #expect(p.animationLibrary[0].triggers.isEmpty)
    }

    @Test func anImpsOwnGestureOnlyChangesThatImp() {
        var (p, imp, pip) = Self.troupe()
        let mine = MadeAnimation(name: "Grumble", triggers: [.poke], beats: Self.beats)
        p.save(mine, for: pip)
        #expect(p.ref(for: .poke, imp: pip) == .custom(mine.id))
        #expect(p.ref(for: .poke, imp: imp) == .preset(.angry))
        #expect(p.refs(for: .idle, imp: pip).contains(.preset(.hum)))
    }

    @Test func madeAnimationsMayWatchTheCursor() {
        var p = ImpPreferences()
        for r in Reaction.allCases { p.setEnabled(false, for: r) }
        #expect(!p.watchesCursor)
        p.save(MadeAnimation(name: "Spin", triggers: [.circle], beats: Self.beats), for: nil)
        #expect(p.watchesCursor)
    }

    @Test func filesAndModelsAreKeptInBounds() {
        var problems: [String] = []
        let json = try! JSONValue(jsonString: #"{"name": "  Wild  ", "beats": [{"duration": 99, "look": [5, -5], "mood": "furious", "tilt": 400}, {"mood": "happy"}]}"#)
        let a = MadeAnimation(kit: json, problems: &problems)!
        #expect(a.name == "Wild" && a.beats.count == 1)
        #expect(a.beats[0].duration == 6 && a.beats[0].lookX == 1 && a.beats[0].lookY == -1 && a.beats[0].tilt == 30 && a.beats[0].mood == nil)
        #expect(problems.count == 2, "\(problems)")
        let long = MadeAnimation(name: "Long", beats: Array(repeating: AnimationBeat(duration: 5), count: 30)).normalized
        #expect(long.beats.count == MadeAnimation.maxBeats && long.duration <= MadeAnimation.maxDuration + 0.001)
        #expect(MadeAnimation(kit: try! JSONValue(jsonString: #"{"replaces": "teleport", "beats": [{"duration": 1}]}"#), problems: &problems) == nil)
    }

    @Test func traitsAreClampedAndOnlyStoredWhenSet() throws {
        var pip = ImpProfile(name: "Pip", hue: 0, favoriteHue: 0.5, personality: "")
        pip.traits = ImpTraits(lids: 5, tempo: 9)
        #expect(pip.traits.lids == 0.6 && pip.traits.tempo == 1.6)
        pip.traits = .plain
        let data = try JSONEncoder().encode(pip)
        #expect(!String(decoding: data, as: UTF8.self).contains("character"))
        #expect(ImpTraits.presets.first { $0.id == "tired" }!.traits.preset?.id == "tired")
        #expect(ImpTraits.plain.summary == "Plain")
    }

    @Test func oldSettingsStillLoad() throws {
        var (p, _, pip) = Self.troupe()
        p.save(MadeAnimation(name: "Wave", beats: Self.beats), for: pip)
        let back = try JSONDecoder().decode(ImpPreferences.self, from: JSONEncoder().encode(p))
        #expect(back.ownAnimations(of: pip).map(\.name) == ["Wave"])
        let old = try JSONDecoder().decode(ImpProfile.self, from: Data(#"{"id":"1A1A1A1A-0000-4000-8000-00000000F00D","name":"Imp","isActive":true,"hue":0,"favoriteHue":0,"knowsFavorite":false,"scale":1,"personality":"","servers":[],"usesShell":true}"#.utf8))
        #expect(old.animations.isEmpty && old.traits == .plain)
    }

    @Test func aKitCarriesAnimationsAndAnImpsCharacter() throws {
        var (p, _, pip) = Self.troupe()
        p.imps[1].traits = ImpTraits(lids: 0.3, tempo: 0.8)
        p.save(MadeAnimation(name: "Slow blink", triggers: [.idle], beats: Self.beats), for: pip)
        p.save(MadeAnimation(name: "", replaces: .yawn, beats: Self.beats), for: pip)
        var kit = Kit.exporting(imps: [pip], from: p)
        kit.animations = [MadeAnimation(name: "Shrug", about: "A shrug.", beats: Self.beats)]
        #expect(kit.formatVersion == 3)
        let text = kit.json()
        #expect(text.contains(#"{"duration":0.4,"look":[0,0.1],"mood":"happy","hop":true}"#), "a beat is one line")
        let back = try Kit.parse(text)
        #expect(back.animations.map(\.name) == ["Shrug"])
        #expect(back.imps[0].traits == p.imps[1].traits.normalized)
        #expect(back.imps[0].animations.map(\.title) == ["Slow blink", "Yawn"] && back.imps[0].animations[1].replaces == .yawn)

        var other = ImpPreferences()
        let added = other.add(back, imps: Set(back.imps.map(\.id)), triggers: [], servers: [], animations: Set(back.animations.map(\.id)), for: nil)
        #expect(added.animations == 1 && added.imps.count == 1)
        let hatched = other.imps.first { $0.id == added.imps[0].id }!
        #expect(hatched.traits == back.imps[0].traits && hatched.animations.count == 2)
        #expect(!hatched.animations.contains { a in back.imps[0].animations.contains { $0.id == a.id } }, "new ids")
        #expect(other.animationLibrary.map(\.name) == ["Shrug"])
    }

    @Test func aKitOfOnlyAnimationsReads() throws {
        let kit = try Kit.parse(#"{"imp": 3, "animations": [{"name": "Nod", "beats": [{"duration": 0.3, "look": [0, 0.4]}]}]}"#)
        #expect(kit.animations.count == 1 && kit.itemCount == 1 && kit.formatVersion == 3)
        var p = ImpPreferences()
        p.save(MadeAnimation(name: "Nod", beats: Self.beats), for: nil)
        p.add(kit, triggers: [], servers: [], animations: [kit.animations[0].id], for: nil)
        #expect(p.animationLibrary.map(\.name) == ["Nod", "Nod 2"])
    }
}
