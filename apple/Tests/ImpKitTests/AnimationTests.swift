import Foundation
import Testing
@testable import ImpKit

/// The whole catalog the Den seeds (`spec/animations/catalog.json`), of which the apps bundle only five.
private func catalogData() throws -> Data {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
    return try Data(contentsOf: root.appendingPathComponent("spec/animations/catalog.json"))
}

@Suite struct AnimationRuleTests {
    /// The gestures are started by the Den's animations (installed as made ones), one each; the catalog says which.
    @Test func everyInteractionHasItsOwnFeeling() throws {
        let catalog = AnimationCatalog.parse(try catalogData())
        let handling = catalog.filter { $0.starts.contains { $0.isExclusive && $0 != .favoriteColor } }
        #expect(handling.count == 14)
        for e in handling { #expect(e.starts.count == 1, "\(e.id)") }
        for t in AnimationTrigger.allCases where t.isExclusive {
            #expect(catalog.filter { $0.starts.contains(t) }.count == 1, "\(t)")
        }
        // Pressing and carrying are always noticed; cursor games follow the Mouse games switch.
        #expect(!AnimationTrigger.hold.watchesCursor && !AnimationTrigger.pickUp.watchesCursor)
        #expect(AnimationTrigger.stroke.watchesCursor && AnimationTrigger.stare.watchesCursor)
    }

    /// The Imp answers quickly: no animation of the catalog lasts a second (docs/ux/motion.md).
    @Test func everyAnimationIsShorterThanASecond() throws {
        let root = try JSONDecoder().decode(JSONValue.self, from: try catalogData())
        let list = try #require(root["animations"]?.array)
        #expect(list.count > 50)
        for item in list {
            let beats = item["beats"]?.array ?? []
            let total = beats.reduce(0.0) { $0 + ($1["duration"]?.double ?? 0) }
            #expect(total > 0 && total < 1, "\(item["id"]?.string ?? "?") lasts \(total) s")
        }
    }

    @Test func everyAnimationPlaysSomehow() {
        #expect(Reaction.allCases.count == 5 && Set(AnimationCatalog.bundled.map(\.id)) == Set(Reaction.allCases.map(\.rawValue)))
        for r in Reaction.allCases {
            // Untriggered ones are expressions and gestures, there for the troupe and for you to assign.
            #expect(!r.defaultTriggers.isEmpty || [.expressions, .gestures].contains(r.family), "\(r) never plays")
            #expect(!r.title.isEmpty && !r.summary.isEmpty && !r.beats.isEmpty)
        }
    }

    /// Out of the box every gesture starts exactly one animation, one of the five bundled ones, so an offline Imp is lively.
    /// A quiet moment keeps its routines.
    @Test func everyGestureHasOneBundledAnimationOutOfTheBox() {
        let p = ImpPreferences()
        let bundled = Set(AnimationCatalog.bundled.map(\.id))
        #expect(bundled.count == 5)
        for t in AnimationTrigger.allCases where t.isExclusive {
            #expect(p.animations(for: t).count == 1, "\(t)")
            #expect(p.animation(for: t).map { bundled.contains($0.rawValue) } == true, "\(t)")
        }
        #expect(p.animations(for: .idle) == [.smile])
    }

    @Test func aDenAnimationReplacesTheDefaultAndRemovingItBringsItBack() {
        var p = ImpPreferences()
        let before = p.animation(for: .poke)
        #expect(before != nil)
        let angry = MadeAnimation(name: "Angry", triggers: [.poke], beats: [AnimationBeat(duration: 1)])
        p.save(angry, for: nil)
        #expect(p.ref(for: .poke, imp: nil) == .custom(angry.id))
        #expect(p.animation(for: .poke) == nil, "the default stepped aside, one animation at a time")
        for t in AnimationTrigger.allCases where t.isExclusive && t != .poke { #expect(p.animation(for: t) != nil, "\(t)") }
        p.removeAnimation(angry.id)
        #expect(p.animation(for: .poke) == before)
        #expect(p.ref(for: .poke, imp: nil) == before.map { .preset($0) })
        #expect(p.animations.isEmpty, "back to the default: nothing stored")
    }

    @Test func gesturesMoveWhenReassigned() {
        var p = ImpPreferences()
        p.setTrigger(.poke, true, for: .wow)
        #expect(p.animation(for: .poke) == .wow)
        p.setTrigger(.poke, true, for: .sad)
        #expect(p.animation(for: .poke) == .sad)
        #expect(!p.rule(for: .wow).triggers.contains(.poke))
        // Shared triggers stay shared.
        p.setTrigger(.idle, true, for: .sad)
        #expect(p.animations(for: .idle).contains(.sad) && p.animations(for: .idle).contains(.smile))
    }

    @Test func switchedOffAnimationsDontPlay() {
        var p = ImpPreferences()
        p.setTrigger(.poke, true, for: .wow)
        p.setEnabled(false, for: .wow)
        #expect(p.animation(for: .poke) == nil)
        #expect(!p.isEnabled(.wow))
        p.setEnabled(false, for: .smile)
        #expect(p.animations(for: .idle).isEmpty)
        p.resetAnimations()
        #expect(p.isEnabled(.smile) && p.isEnabled(.wow) && p.animations.isEmpty)
        p.setEnabled(false, for: .sad)
        p.setEnabled(true, for: .sad)
        #expect(p.animations.isEmpty, "back to the default: nothing stored")
    }

    @Test func rulesSurviveARoundTrip() throws {
        var p = ImpPreferences()
        p.setTrigger(.circle, true, for: .wow)
        p.setEnabled(false, for: .sleep)
        let back = try JSONDecoder().decode(ImpPreferences.self, from: JSONEncoder().encode(p))
        #expect(back.animation(for: .circle) == .wow && !back.isEnabled(.sleep))
    }

    /// By design the troupe answers a bundled reaction with the same one (a removed animation's special answer is gone).
    @Test func theTroupeCatchesWhatItSees() {
        #expect(Contagion.response(to: .reacted(.sad)) == .sad)
        #expect(Contagion.response(to: .reacted(.sleep)) == .sleep)
        #expect(Contagion.response(to: .reacted(.greet)) == .greet)
        #expect(Contagion.response(to: .annoyed) == .wow)
    }
}

@Suite struct FavoriteAnimationTests {
    /// The Den's favourite-colour animations are installed as made ones that play only in the favourite colour.
    @Test func theyUnlockWithTheFavouriteColourAndPlayWhenQuiet() throws {
        let root = try JSONDecoder().decode(JSONValue.self, from: try catalogData())
        let special = (root["animations"]?.array ?? []).filter { $0["favoriteColor"]?.bool == true }
        #expect(special.count == 5)

        var p = ImpPreferences()
        let glow = MadeAnimation(name: "Glow", triggers: [.idle], favoriteColorOnly: true, beats: [AnimationBeat(duration: 1)])
        let delight = MadeAnimation(name: "Delight", triggers: [.favoriteColor], beats: [AnimationBeat(duration: 1)])
        p.save(glow, for: nil)
        p.save(delight, for: nil)
        let imp = p.imps[0].id
        #expect(p.refs(for: .idle, imp: imp).contains(.custom(glow.id)))
        #expect(!p.isUnlocked(.custom(glow.id), imp: imp, wearingFavorite: false))
        #expect(p.isUnlocked(.custom(glow.id), imp: imp, wearingFavorite: true))
        #expect(p.isUnlocked(.custom(delight.id), imp: imp, wearingFavorite: false))
        #expect(p.ref(for: .favoriteColor, imp: imp) == .custom(delight.id))
        #expect(p.animation(for: .favoriteColor) == nil, "nothing bundled finds the colour")
    }
}

@Suite struct CursorWatchTests {
    @Test func theCursorIsWatchedOnlyWhenSomeAnimationNeedsIt() {
        var p = ImpPreferences()
        #expect(p.watchesCursor, "the bundled defaults hold cursor games")
        p.mouseGames = false
        #expect(!p.watchesCursor)
        p.mouseGames = true
        p.stopCursorGames()
        #expect(!p.watchesCursor)
        let stroke = MadeAnimation(name: "Pet", triggers: [.stroke], beats: [AnimationBeat(duration: 1)])
        p.save(stroke, for: nil)
        #expect(p.watchesCursor, "an installed animation that strokes needs it")
        p.mouseGames = false
        #expect(!p.watchesCursor)
        p.mouseGames = true
        p.setEnabled(false, animation: stroke.id)
        #expect(!p.watchesCursor, "everything that watches the cursor is off")
        p.setEnabled(true, animation: stroke.id)
        p.setTrigger(.stroke, false, animation: stroke.id)
        #expect(!p.watchesCursor, "it no longer has a trigger that needs the cursor")
        p.setTrigger(.swish, true, for: .sad)
        #expect(p.watchesCursor)
        p.setEnabled(false, for: .sad)
        #expect(!p.watchesCursor)
    }

    @Test func clicksAndCarryingDontNeedIt() {
        var p = ImpPreferences()
        p.stopCursorGames()
        p.setTrigger(.poke, true, for: .wow)
        p.setTrigger(.pickUp, true, for: .wow)
        #expect(!p.watchesCursor)
    }
}

private extension ImpPreferences {
    /// Takes every cursor game away from the built-in animations.
    mutating func stopCursorGames() {
        for t in AnimationTrigger.allCases where t.watchesCursor {
            for r in Reaction.allCases { setTrigger(t, false, for: r) }
        }
    }
}

@Suite struct BlendWeightsTests {
    @Test func aSteadyStateIsSettled() {
        var w = BlendWeights<String>(duration: 0.4)
        w.advance(to: "a", at: 0)
        #expect(w.isSettled && w.mix.count == 1 && w.mix[0].key == "a" && w.mix[0].weight == 1)
    }

    @Test func aChangeFadesOverTheDuration() {
        var w = BlendWeights<String>(duration: 0.4)
        w.advance(to: "a", at: 0)
        for frame in 1...12 { w.advance(to: "b", at: Double(frame) / 60) }      // 0.2 s: half way
        #expect(!w.isSettled)
        let mid = Dictionary(uniqueKeysWithValues: w.mix.map { ($0.key, $0.weight) })
        #expect(abs((mid["a"] ?? 0) - 0.5) < 0.05 && abs((mid["b"] ?? 0) - 0.5) < 0.05)
        for frame in 13...30 { w.advance(to: "b", at: Double(frame) / 60) }
        #expect(w.isSettled && w.mix.map(\.key) == ["b"])
    }

    /// Changing again half way through a fade must not make any state's share jump.
    @Test func changingMidFadeStaysContinuous() {
        var w = BlendWeights<Int>(duration: 0.35)
        var t = 0.0
        var worst = 0.0
        w.advance(to: 0, at: t)
        var previous = Dictionary(uniqueKeysWithValues: w.mix.map { ($0.key, $0.weight) })
        // Moods flip every 0.2 s (shorter than the fade), through four of them.
        while t < 3 {
            t += 1.0 / 60
            w.advance(to: Int(t / 0.2) % 4, at: t)
            let now = Dictionary(uniqueKeysWithValues: w.mix.map { ($0.key, $0.weight) })
            let sum = now.values.reduce(0, +)
            #expect(abs(sum - 1) < 1e-9)
            for k in Set(now.keys).union(previous.keys) { worst = max(worst, abs((now[k] ?? 0) - (previous[k] ?? 0))) }
            previous = now
        }
        #expect(worst < 0.2, "largest single-frame change in any share: \(worst)")
    }

    @Test func aPausedClockResumesGently() {
        var w = BlendWeights<String>(duration: 0.35)
        w.advance(to: "a", at: 0)
        w.advance(to: "b", at: 1)                       // drawing paused for a second
        #expect(!w.isSettled, "the fade starts now, it doesn't finish in one go")
        let share = w.mix.first { $0.key == "b" }?.weight ?? 0
        #expect(share < 0.1)
    }

    @Test func timeRunningBackwardsRestarts() {
        var w = BlendWeights<String>(duration: 0.35)
        w.advance(to: "a", at: 5)
        w.advance(to: "b", at: 1)
        #expect(w.isSettled && w.mix.map(\.key) == ["b"])
    }
}

@Suite struct FavoriteColourTests {
    @Test func closeShadesCountAndTheWheelWraps() {
        var p = ImpProfile.imp
        #expect(p.isFavorite(0.01) && p.isFavorite(0.99) && !p.isFavorite(0.07))
        p.favoriteHue = 0.5
        #expect(p.isFavorite(0.515) && !p.isFavorite(0.57))
        #expect(abs(ImpProfile.hueDistance(0.95, 0.05) - 0.1) < 1e-9)
    }

    @Test func favouriteSurvivesARoundTrip() throws {
        var p = ImpProfile.newcomer(joining: [.imp])
        p.knowsFavorite = true
        let back = try JSONDecoder().decode(ImpProfile.self, from: JSONEncoder().encode(p))
        #expect(back.favoriteHue == p.favoriteHue && back.knowsFavorite)
    }
}

@Suite struct ClickBurstTests {
    @Test func aClickIsDecidedWhenTheBurstEnds() {
        var b = ClickBurst(interval: 0.4)
        #expect(b.click(at: 10) == nil)
        #expect(b.settle(at: 10.2) == nil)                   // too early: a second click may come
        #expect(b.settle(at: 10.4) == .single)
        #expect(b.settle(at: 10.5) == nil)                   // only once
        #expect(b.click(at: 11) == nil)                      // a new burst
        #expect(b.settle(at: 11.4) == .single)
    }

    @Test func aDoubleClickIsDecidedWhenTheBurstEnds() {
        var b = ClickBurst(interval: 0.4)
        #expect(b.click(at: 10) == nil)                      // no single click on the way
        #expect(b.click(at: 10.2) == nil)
        #expect(b.settle(at: 10.3) == nil)                   // too early: a third click may come
        #expect(b.settle(at: 10.6) == .double)
        #expect(b.settle(at: 10.7) == nil)                   // only once
    }

    @Test func aClickNeverWaitsLong() {
        #expect(ClickBurst.gap(system: 0.5) == 0.3)          // the default system interval is too slow
        #expect(ClickBurst.gap(system: 0.25) == 0.25)        // a quicker setting is kept
    }

    @Test func threeClicksDoNothing() {
        var b = ClickBurst(interval: 0.4)
        #expect([10, 10.2, 10.4].map { b.click(at: $0) } == [nil, nil, nil])
        #expect(b.settle(at: 10.8) == nil)
    }

    @Test func fourQuickClicksAreAFlurryNotADoubleClick() {
        var b = ClickBurst(interval: 0.4)
        let outcomes = [10, 10.2, 10.4, 10.6, 10.8].map { b.click(at: $0) }
        #expect(outcomes == [nil, nil, nil, .flurry, nil])   // the poke lands at once, nothing before it
        #expect(b.settle(at: 11.3) == nil)
    }

    @Test func slowClicksAreSeparateClicks() {
        var b = ClickBurst(interval: 0.4)
        let outcomes = [10, 10.5, 11, 11.5].map { t -> ClickBurst.Outcome? in
            _ = b.click(at: t)
            return b.settle(at: t + 0.4)
        }
        #expect(outcomes == [.single, .single, .single, .single])
    }
}

@Suite struct GestureTests {
    @Test func theGreetingNodsWhenTheCursorRestsAndCanBeGivenMore() {
        var p = ImpPreferences()
        let gestures = Reaction.allCases.filter { $0.family == .gestures }
        #expect(gestures == [.greet], "the one bundled answer is a greeting")
        #expect(p.rule(for: .greet).triggers == [.linger, .stare] && p.isEnabled(.greet), "it nods when the cursor rests by it")
        p.setTrigger(.idle, true, for: .greet)
        #expect(p.animations(for: .idle).contains(.greet))
    }
}

@Suite struct BodyClockTests {
    @Test func eachImpKeepsItsOwnStableRhythm() {
        let a = UUID(), b = UUID()
        #expect(BodyClock(a) == BodyClock(a), "same Imp, same rhythm every launch")
        #expect((0..<600).contains(BodyClock(a).offset))
        // A troupe spreads out: offsets differ (and not by whole blink periods).
        let offsets = (0..<8).map { _ in BodyClock(UUID()).offset }
        #expect(Set(offsets).count == offsets.count)
        #expect(BodyClock(a).offset != BodyClock(b).offset)
        let date = Date(timeIntervalSinceReferenceDate: 1000)
        #expect(BodyClock(offset: 2.5).time(date) == 1002.5)
        #expect(BodyClock.shared.time(date) == 1000)
    }
}

@Suite struct PacingTests {
    @Test func springsAtRestAreSettled() {
        #expect(SpringSettle.isSettled(values: [0.5, 10], targets: [0.5, 10], velocities: [0, 0]))
    }

    @Test func aSpringStillTurningIsNotSettled() {
        // Far from the cursor, or nearly there but still moving: keep drawing every frame.
        #expect(!SpringSettle.isSettled(values: [0.1], targets: [0.8], velocities: [0]))
        #expect(!SpringSettle.isSettled(values: [0.8], targets: [0.8], velocities: [0.5]))
    }

    /// A head turn sprung as the face does it (stiffness 210, damping 17) at 60 fps stays
    /// "moving" until it has arrived, so it's never handed to the resting pace mid-turn.
    @Test func aHeadTurnIsDrawnUntilItArrives() {
        var x = -0.8, v = 0.0
        let target = 0.7, dt = 1.0 / 60
        var frames = 0
        while !SpringSettle.isSettled(values: [x], targets: [target], velocities: [v]) {
            v += ((target - x) * 210 - v * 17) * dt
            x += v * dt
            frames += 1
            #expect(frames < 600)
            if frames >= 600 { break }
        }
        #expect(abs(x - target) <= SpringSettle.distance)
        #expect(frames > 10)
    }

    @Test func routineStartsWaitAfterImpBecomesFree() {
        let now = Date(timeIntervalSinceReferenceDate: 1000)
        let stale = now.addingTimeInterval(-30)
        #expect(AnticPacing.nextStart(stale, now: now, free: true) == stale)
        let held = AnticPacing.nextStart(stale, now: now, free: false)
        #expect(held >= now.addingTimeInterval(AnticPacing.settle))
        // Still not free later: keeps being pushed, never fires on the first free tick.
        let later = now.addingTimeInterval(10)
        #expect(AnticPacing.nextStart(held, now: later, free: false) >= later.addingTimeInterval(AnticPacing.settle))
    }
}
