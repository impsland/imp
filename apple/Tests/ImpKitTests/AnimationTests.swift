import Foundation
import Testing
@testable import ImpKit

private func beat() -> [AnimationBeat] { [AnimationBeat(duration: 0.5)] }

@Suite struct AnimationLibraryTests {
    @Test func cursorEventsAreTheOnesThatWatchTheCursor() {
        // Pressing and carrying are noticed on the Imp itself. The rest of the pointer's doings watch it from afar.
        #expect(!TriggerEvent.hold.watchesCursor && !TriggerEvent.drag.watchesCursor && !TriggerEvent.poke.watchesCursor)
        #expect(TriggerEvent.stroke.watchesCursor && TriggerEvent.near.watchesCursor && TriggerEvent.away.watchesCursor)
    }

    @Test func freshPreferencesHaveNoAnimations() {
        let p = ImpPreferences()
        #expect(p.animationLibrary.isEmpty)
        #expect(p.ref(named: "Angry", imp: nil) == nil)
    }

    @Test func aMadeAnimationIsFoundByNameAndRemovingItForgetsIt() {
        var p = ImpPreferences()
        let angry = MadeAnimation(name: "Angry", beats: beat())
        p.save(angry, for: nil)
        #expect(p.ref(named: "angry", imp: nil) == .custom(angry.id))
        p.removeAnimation(angry.id)
        #expect(p.ref(named: "Angry", imp: nil) == nil)
        #expect(p.animationLibrary.isEmpty)
    }

    @Test func nothingStartsAnAnimationButATrigger() throws {
        var p = ImpPreferences()
        let a = MadeAnimation(name: "A", beats: beat())
        p.save(a, for: nil)
        p.setEnabled(false, animation: a.id)
        let back = try JSONDecoder().decode(ImpPreferences.self, from: JSONEncoder().encode(p))
        #expect(back.animationLibrary.map(\.id) == [a.id])
        #expect(!back.watchesCursor, "no trigger, nothing to watch for")
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
