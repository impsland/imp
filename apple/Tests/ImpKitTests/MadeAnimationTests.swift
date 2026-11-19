import Foundation
import Testing
@testable import ImpKit

@Suite struct MadeAnimationTests {
    static let beats = [AnimationBeat(duration: 0.4, lookX: 0, lookY: 0.1, mood: "happy", hop: true),
                        AnimationBeat(duration: 0.8, mood: "content", glyph: "heart", tilt: 5)]

    static func troupe() -> (ImpPreferences, UUID, UUID) {
        var p = ImpPreferences.withWaitingImp()
        let pip = ImpProfile(name: "Pip", hue: 0.5, favoriteHue: 0.9, personality: "")
        p.imps = [.imp, pip]
        return (p, p.imps[0].id, pip.id)
    }

    @Test func aSharedAnimationIsFoundByEveryImpAndAnImpsOwnOnlyByThatImp() {
        var (p, imp, pip) = Self.troupe()
        let wave = MadeAnimation(name: "Wave", beats: Self.beats)
        p.save(wave, for: nil)
        #expect(p.ref(named: "Wave", imp: pip) == .custom(wave.id) && p.ref(named: "Wave", imp: imp) == .custom(wave.id))
        let mine = MadeAnimation(name: "Grumble", beats: Self.beats)
        p.save(mine, for: pip)
        #expect(p.ref(named: "Grumble", imp: pip) == .custom(mine.id))
        #expect(p.ref(named: "Grumble", imp: imp) == nil, "the others don't have it")
        p.removeAnimation(mine.id)
        #expect(p.ref(named: "Grumble", imp: pip) == nil)
    }

    @Test func anImpsAnimationsListItsOwnFirstThenTheSharedOnesItHasNoVersionOf() {
        var (p, imp, pip) = Self.troupe()
        let wave = MadeAnimation(name: "Wave", beats: Self.beats)
        let bow = MadeAnimation(name: "Bow", beats: Self.beats)
        let nod = MadeAnimation(name: "Nod", beats: Self.beats)
        for shared in [wave, bow, nod] { p.save(shared, for: nil) }
        p.save(MadeAnimation(name: "Grumble", beats: Self.beats), for: pip)
        var waveForPip = wave
        waveForPip.beats = [AnimationBeat(duration: 0.2)]
        p.save(waveForPip, for: pip)
        let samename = MadeAnimation(name: "bow", beats: Self.beats)
        p.save(samename, for: pip)

        let listed = p.listedAnimations(for: pip)
        #expect(listed.map(\.animation.title).prefix(3).sorted() == ["Grumble", "Wave", "bow"].sorted())
        #expect(listed.suffix(1).map(\.animation.title) == ["Nod"], "the shared ones come last; a version or a same title hides the shared one")
        #expect(listed.last?.scope == .everyImp && listed.last?.isShared == true)
        #expect(listed.first { $0.animation.title == "Grumble" }?.scope == .onlyThisImp)
        #expect(listed.first { $0.animation.title == "Wave" }?.scope == .changed)
        #expect(p.listedAnimations(for: imp).map(\.animation.title) == ["Wave", "Bow", "Nod"], "another Imp sees only the shared ones")
    }

    @Test func onlyTriggersWatchTheCursor() {
        var p = ImpPreferences.withWaitingImp()
        p.save(MadeAnimation(name: "Spin", beats: Self.beats), for: nil)
        #expect(!p.watchesCursor, "an animation never starts by itself")
        p.shortcuts = [Shortcut(name: "Dizzy", trigger: Trigger(.circle), steps: [Step(.play, value: "Spin")])]
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
        #expect(MadeAnimation(kit: try! JSONValue(jsonString: #"{"beats": []}"#), problems: &problems) == nil)
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
        p.save(MadeAnimation(name: "Slow blink", beats: Self.beats), for: pip)
        p.save(MadeAnimation(name: "Yawn", beats: Self.beats), for: pip)
        var kit = Kit.exporting(imps: [pip], from: p)
        kit.animations = [MadeAnimation(name: "Shrug", about: "A shrug.", beats: Self.beats)]
        let text = kit.json()
        #expect(text.contains(#"{"duration":0.4,"look":[0,0.1],"mood":"happy","hop":true}"#), "a beat is one line")
        let back = try Kit.parse(text)
        #expect(back.animations.map(\.name) == ["Shrug"])
        #expect(back.imps[0].traits == p.imps[1].traits.normalized)
        #expect(back.imps[0].animations.map(\.title) == ["Slow blink", "Yawn"])

        var other = ImpPreferences.withWaitingImp()
        let added = other.add(back, imps: Set(back.imps.map(\.id)), triggers: [], servers: [], animations: Set(back.animations.map(\.id)), for: nil)
        #expect(added.animations == 1 && added.imps.count == 1)
        let hatched = other.imps.first { $0.id == added.imps[0].id }!
        #expect(hatched.traits == back.imps[0].traits && hatched.animations.count == 2)
        #expect(!hatched.animations.contains { a in back.imps[0].animations.contains { $0.id == a.id } }, "new ids")
        #expect(other.animationLibrary.map(\.name) == ["Shrug"])
    }

    @Test func aKitOfOnlyAnimationsReads() throws {
        let kit = try Kit.parse(#"{"animations": [{"name": "Nod", "beats": [{"duration": 0.3, "look": [0, 0.4]}]}]}"#)
        #expect(kit.animations.count == 1 && kit.itemCount == 1)
        var p = ImpPreferences.withWaitingImp()
        p.save(MadeAnimation(name: "Nod", beats: Self.beats), for: nil)
        p.add(kit, triggers: [], servers: [], animations: [kit.animations[0].id], for: nil)
        #expect(p.animationLibrary.map(\.name) == ["Nod", "Nod 2"])
    }

    @Test func movesAreKeptInBoundsAndOnlyStoredWhenTheyMeanSomething() {
        let spin = AnimationBeat(duration: 1, move: "spin", times: 40, reverse: true).normalized
        #expect(spin.move == "spin" && spin.times == AnimationBeat.timesRange.upperBound && spin.reverse == true)
        let usual = AnimationBeat(duration: 1, move: "bounce", times: 3, reverse: false).normalized
        #expect(usual.times == nil && usual.reverse == nil && usual.repeats == 3, "the move's usual count isn't stored")
        let unknown = AnimationBeat(duration: 1, move: "moonwalk", times: 2, reverse: true).normalized
        #expect(unknown.move == nil && unknown.times == nil && unknown.reverse == nil)
        #expect(AnimationBeat(duration: 1, move: "flip", times: 0).normalized.times == nil, "at least once: the usual count for a flip")
    }

    @Test func aKitCarriesMovesAndReportsUnknownOnes() throws {
        let beat = AnimationBeat(duration: 1.2, mood: "happy", move: "roll", times: 2, reverse: true).normalized
        #expect(beat.kitJSON["move"]?.string == "roll" && beat.kitJSON["times"]?.double == 2 && beat.kitJSON["reverse"]?.bool == true)
        var problems: [String] = []
        let back = try #require(AnimationBeat(kit: beat.kitJSON, problems: &problems))
        #expect(back == beat && problems.isEmpty)
        let still = AnimationBeat(duration: 0.5).normalized.kitJSON
        #expect(still["move"] == nil && still["times"] == nil, "no move: nothing written")
        let odd = try #require(AnimationBeat(kit: ["duration": 1, "move": "moonwalk", "times": 1e300], problems: &problems))
        #expect(odd.move == nil && problems.count == 1, "a huge count doesn't trap, an unknown move is reported")
    }

    @Test func beatsSavedBeforeMovesStillLoad() throws {
        let old = #"{"duration":0.5,"tilt":0,"hop":true,"stretch":0.1,"mood":"happy"}"#
        let beat = try JSONDecoder().decode(AnimationBeat.self, from: Data(old.utf8))
        #expect(beat.move == nil && beat.repeats == 1 && beat.hop && beat.mood == "happy")
        let moving = AnimationBeat(duration: 1, move: "spin", times: 2)
        #expect(try JSONDecoder().decode(AnimationBeat.self, from: JSONEncoder().encode(moving)) == moving)
    }
}
