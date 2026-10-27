import Foundation
import Testing
@testable import ImpKit

@Suite struct AnimationRuleTests {
    @Test func everyInteractionHasItsOwnFeeling() {
        let p = ImpPreferences()
        let handling = Reaction.allCases.filter { $0.family == .handling }
        #expect(handling.count == 10)
        for r in handling { #expect(p.rule(for: r).triggers.count == 1, "\(r)") }
        // Pressing and carrying are always noticed; cursor games follow the Mouse games switch.
        #expect(!AnimationTrigger.hold.watchesCursor && !AnimationTrigger.pickUp.watchesCursor)
        #expect(AnimationTrigger.stroke.watchesCursor && AnimationTrigger.stare.watchesCursor)
    }

    @Test func everyAnimationPlaysSomehow() {
        for r in Reaction.allCases {
            // Untriggered ones are expressions and gestures, there for the troupe and for you to assign.
            #expect(!r.defaultTriggers.isEmpty || [.expressions, .gestures].contains(r.family), "\(r) never plays")
            #expect(!r.title.isEmpty && !r.summary.isEmpty)
        }
    }

    @Test func defaultsGiveEachGestureOneAnimation() {
        let p = ImpPreferences()
        #expect(p.animation(for: .poke) == .angry)
        #expect(p.animation(for: .favoriteColor) == .delight)
        #expect(p.animation(for: .circle) == .dizzy)
        #expect(p.animation(for: .swish) == .mean)
        #expect(p.animation(for: .stroke) == .pet)
        #expect(p.animation(for: .tickle) == .giggle && p.animation(for: .hold) == .cuddle)
        #expect(p.animation(for: .pickUp) == .wheee && p.animation(for: .shake) == .woozy && p.animation(for: .drop) == .plop)
        #expect(p.animation(for: .rush) == .flinch && p.animation(for: .linger) == .curious && p.animation(for: .stare) == .shy)
        #expect(p.animation(for: .dangle) == .pounce && p.animation(for: .comeback) == .missedYou)
        for t in AnimationTrigger.allCases where t.isExclusive { #expect(p.animations(for: t).count == 1, "\(t)") }
        #expect(p.animations(for: .idle).contains(.hum) && p.animations(for: .idle).contains(.watch))
    }

    @Test func gesturesMoveWhenReassigned() {
        var p = ImpPreferences()
        p.setTrigger(.poke, true, for: .jump)
        #expect(p.animation(for: .poke) == .jump)
        #expect(!p.rule(for: .angry).triggers.contains(.poke))
        // Shared triggers stay shared.
        p.setTrigger(.idle, true, for: .jump)
        #expect(p.animations(for: .idle).contains(.jump) && p.animations(for: .idle).contains(.hum))
    }

    @Test func switchedOffAnimationsDontPlay() {
        var p = ImpPreferences()
        p.setEnabled(false, for: .angry)
        #expect(p.animation(for: .poke) == nil)
        #expect(!p.isEnabled(.angry))
        p.setEnabled(true, for: .angry)
        #expect(p.animations.isEmpty, "back to the default: nothing stored")
        p.setEnabled(false, for: .hum)
        p.resetAnimations()
        #expect(p.isEnabled(.hum))
    }

    @Test func rulesSurviveARoundTrip() throws {
        var p = ImpPreferences()
        p.setTrigger(.circle, true, for: .laugh)
        p.setEnabled(false, for: .nap)
        p.doubleClickOpensSettings = false
        let back = try JSONDecoder().decode(ImpPreferences.self, from: JSONEncoder().encode(p))
        #expect(back.animation(for: .circle) == .laugh && !back.isEnabled(.nap) && !back.doubleClickOpensSettings)
    }

    @Test func routinesStayPrivate() {
        #expect(Contagion.response(to: .reacted(.hum)) == nil)
        #expect(Contagion.response(to: .reacted(.delight)) == .smile)
        #expect(Contagion.response(to: .reacted(.angry)) == .wow)
        #expect(Contagion.response(to: .reacted(.boo)) == .flinch, "a Boo! startles the others")
        #expect(Contagion.response(to: .reacted(.cuddle)) == nil, "a cuddle is between you and it")
    }
}

@Suite struct FavoriteAnimationTests {
    @Test func theyUnlockWithTheFavouriteColourAndPlayWhenQuiet() {
        let p = ImpPreferences()
        let special = Reaction.allCases.filter(\.unlocksWithFavoriteColor)
        #expect(special.count == 5 && special.allSatisfy { $0.family == .favorite })
        #expect(Reaction.allCases.filter { $0.family == .favorite } == special)
        #expect(!Reaction.hum.unlocksWithFavoriteColor && !Reaction.delight.unlocksWithFavoriteColor)
        for r in special {
            #expect(p.rule(for: r).triggers == [.idle], "\(r)")
            #expect(!r.title.isEmpty && !r.summary.isEmpty && !r.symbol.isEmpty)
        }
        #expect(p.animation(for: .favoriteColor) == .delight)
    }
}

@Suite struct CursorWatchTests {
    @Test func theCursorIsWatchedOnlyWhenSomeAnimationNeedsIt() {
        var p = ImpPreferences()
        #expect(p.watchesCursor, "stroking, tickling and the rest are on out of the box")
        p.mouseGames = false
        #expect(!p.watchesCursor)
        p.mouseGames = true
        for r in Reaction.allCases where p.rule(for: r).triggers.contains(where: \.watchesCursor) {
            p.setEnabled(false, for: r)
        }
        #expect(!p.watchesCursor, "everything that watches the cursor is off")
        p.setEnabled(true, for: .pet)
        #expect(p.watchesCursor)
        p.setTrigger(.stroke, false, for: .pet)
        #expect(!p.watchesCursor, "pet no longer has a trigger that needs the cursor")
        p.setTrigger(.swish, true, for: .jump)
        #expect(p.watchesCursor)
    }

    @Test func clicksAndCarryingDontNeedIt() {
        var p = ImpPreferences()
        p.animations = [:]
        for r in Reaction.allCases { p.setTrigger(.poke, false, for: r); p.setEnabled(false, for: r) }
        p.setEnabled(true, for: .angry)
        p.setTrigger(.poke, true, for: .angry)
        p.setTrigger(.pickUp, true, for: .angry)
        #expect(!p.watchesCursor)
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
    @Test func gesturesWaitForATriggerYouGiveThem() {
        var p = ImpPreferences()
        let gestures = Reaction.allCases.filter { $0.family == .gestures }
        #expect(gestures.count == 20)
        #expect(gestures.allSatisfy { p.rule(for: $0).triggers.isEmpty && p.isEnabled($0) })
        p.setTrigger(.idle, true, for: .aha)
        #expect(p.animations(for: .idle).contains(.aha))
    }
}

@Suite struct SwipeTrackerTests {
    @Test func aSwipeFollowsTheFingersThenTurnsThePage() {
        var t = SwipeTracker()
        #expect(t.scroll(.began, dx: -2, dy: 0) == nil)
        #expect(t.scroll(.changed, dx: -10, dy: 1) == .follow(-12))
        #expect(t.scroll(.changed, dx: -70, dy: 0) == .follow(-82))
        #expect(t.scroll(.ended, dx: 0, dy: 0) == .commit(1))
        _ = t.scroll(.began, dx: 0, dy: 0)
        _ = t.scroll(.changed, dx: 90, dy: 0)
        #expect(t.scroll(.ended, dx: 0, dy: 0) == .commit(-1))
    }

    @Test func aShortSwipeSettlesBack() {
        var t = SwipeTracker()
        _ = t.scroll(.began, dx: 0, dy: 0)
        _ = t.scroll(.changed, dx: 30, dy: 0)
        #expect(t.scroll(.ended, dx: 0, dy: 0) == .cancel)
        _ = t.scroll(.began, dx: 0, dy: 0)
        _ = t.scroll(.changed, dx: 200, dy: 0)
        #expect(t.scroll(.cancelled, dx: 0, dy: 0) == .cancel)
    }

    @Test func verticalScrollingIsLeftAlone() {
        var t = SwipeTracker()
        _ = t.scroll(.began, dx: 0, dy: 0)
        #expect(t.scroll(.changed, dx: 2, dy: 20) == nil)
        #expect(t.scroll(.changed, dx: 200, dy: 0) == nil)
        #expect(t.scroll(.ended, dx: 0, dy: 0) == nil)
    }

    @Test func aMouseWheelTurnsOnePageAtATime() {
        var t = SwipeTracker()
        #expect(t.wheel(dx: -3, at: 1) == .commit(1))
        #expect(t.wheel(dx: -3, at: 1.1) == nil)
        #expect(t.wheel(dx: 3, at: 1.5) == .commit(-1))
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
