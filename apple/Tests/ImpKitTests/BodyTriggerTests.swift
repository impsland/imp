import CoreGraphics
import Foundation
import Testing
@testable import ImpKit

/// Sleep, wake and the like are triggers: they run on the body, from the same list, with no brain.
@Suite struct BodyTriggerTests {
    private let imp = UUID()
    private let state = MacState()

    @Test func idleGoesOffOnceAsTheTimePassesItsNumber() {
        let t = Trigger(.idle, value: "240")
        #expect(t.matches(.idle(from: 239.9, to: 240.1)))
        #expect(t.matches(.idle(from: 200, to: 240)))
        #expect(!t.matches(.idle(from: 100, to: 239)))
        #expect(!t.matches(.idle(from: 240.1, to: 241)), "already past it: no new alarm")
        #expect(!t.matches(.away))
    }

    @Test func idleWatchReportsEachStretchAndStartsOverAfterATouch() {
        var watch = IdleWatch()
        #expect(watch.advance(to: 10) == .idle(from: 0, to: 10))
        #expect(watch.advance(to: 20) == .idle(from: 10, to: 20))
        #expect(watch.advance(to: 3) == nil, "touched: the clock restarts")
        #expect(watch.advance(to: 6) == .idle(from: 3, to: 6))
    }

    @Test func cursorComesNearAndAwayWithoutFlickering() {
        var near = CursorProximity(radius: 80, margin: 12)
        #expect(near.update(distance: 300) == nil)
        #expect(near.update(distance: 70) == .near(from: -1, to: 0))
        #expect(near.update(distance: 60) == nil)
        #expect(near.update(distance: 85) == nil, "on the edge: still near")
        #expect(near.update(distance: 120) == .away)
        #expect(near.update(distance: 130) == nil)
        #expect(Trigger(.near).matches(.near(from: -1, to: 0)))
        #expect(Trigger(.away).matches(.away))
        #expect(!Trigger(.away).matches(.near(from: -1, to: 0)))
    }

    @Test func nearWithSecondsGoesOffAgainOnceTheRestHasLastedThatLong() {
        var near = CursorProximity(radius: 80, margin: 12)
        let at3 = Trigger(.near, value: "3"), at0 = Trigger(.near, value: "0")
        var events: [MacEvent] = []
        for second in 0...5 {
            if let e = near.update(distance: second == 0 ? 50 : 40, now: 100 + Double(second)) { events.append(e) }
        }
        #expect(events.filter(at0.matches).count == 1, "the instant one goes off on arrival only")
        #expect(events.filter(at3.matches).count == 1, "the 3 second one when the third second passes")
        #expect(near.update(distance: 200, now: 106) == .away)
        #expect(near.update(distance: 50, now: 107) == .near(from: -1, to: 0), "a new visit starts the count again")
    }

    private func slept() -> Shortcut { Shortcut(name: "Fall asleep", trigger: Trigger(.idle, value: "240"), steps: [Step(.sleep)]) }
    private func woke() -> Shortcut { Shortcut(name: "Wake up", trigger: Trigger(.near), steps: [Step(.wake)]) }

    /// Preferences with a "Fall asleep" and a "Wake up" trigger that someone added: nothing ships with them.
    private func withBodyTriggers() -> ImpPreferences {
        var prefs = ImpPreferences.withWaitingImp()
        prefs.shortcuts = [slept(), woke()]
        return prefs
    }

    @Test func bodyTriggersRunWithoutABrain() {
        let prefs = withBodyTriggers()
        #expect(prefs.shortcuts.allSatisfy { $0.runsLocally && $0.isValid })
        #expect(prefs.shortcuts.allSatisfy { $0.performer == nil }, "every Imp")
    }

    @Test func aFreshInstallHasNoTriggersAndNothingFallsAsleepOrWakes() {
        let fresh = ImpPreferences.withWaitingImp()
        #expect(fresh.shortcuts.isEmpty)
        #expect(fresh.bodyShortcuts(of: imp, on: .idle(from: 0, to: 100_000), in: state).isEmpty, "no sleeping of its own")
        #expect(fresh.bodyShortcuts(of: imp, on: .near(from: -1, to: 0), in: state).isEmpty, "no waking of its own")
        #expect(fresh.bodyShortcuts(of: imp, on: .away, in: state).isEmpty)
    }

    @Test func idleSleepAndNearWakeComeFromTheList() {
        let prefs = withBodyTriggers()
        #expect(prefs.bodyShortcuts(of: imp, on: .idle(from: 239, to: 241), in: state).map(\.name) == ["Fall asleep"])
        #expect(prefs.bodyShortcuts(of: imp, on: .near(from: -1, to: 0), in: state).map(\.name) == ["Wake up"])
        #expect(prefs.bodyShortcuts(of: imp, on: .away, in: state).isEmpty)
    }

    @Test func eachTriggerCanBeSwitchedOff() throws {
        var prefs = withBodyTriggers()
        let i = try #require(prefs.shortcuts.firstIndex { $0.name == "Fall asleep" })
        prefs.shortcuts[i].isEnabled = false
        #expect(prefs.bodyShortcuts(of: imp, on: .idle(from: 239, to: 241), in: state).isEmpty)
        #expect(prefs.bodyShortcuts(of: imp, on: .near(from: -1, to: 0), in: state).count == 1)
        prefs.shortcuts[i].isEnabled = true
        #expect(prefs.bodyShortcuts(of: imp, on: .idle(from: 239, to: 241), in: state).count == 1)
    }

    @Test func timeIsASetting() throws {
        var prefs = withBodyTriggers()
        let i = try #require(prefs.shortcuts.firstIndex { $0.name == "Fall asleep" })
        prefs.shortcuts[i].trigger.value = "60"
        #expect(prefs.bodyShortcuts(of: imp, on: .idle(from: 239, to: 241), in: state).isEmpty)
        #expect(prefs.bodyShortcuts(of: imp, on: .idle(from: 59, to: 61), in: state).count == 1)
    }

    @Test func aTriggerForOneImpIsNotForAnother() {
        var prefs = ImpPreferences.withWaitingImp()
        let other = UUID()
        prefs.shortcuts = [Shortcut(name: "Nap", performer: other, trigger: Trigger(.idle, value: "10"), steps: [Step(.sleep)])]
        #expect(prefs.bodyShortcuts(of: imp, on: .idle(from: 9, to: 11), in: state).isEmpty)
        #expect(prefs.bodyShortcuts(of: other, on: .idle(from: 9, to: 11), in: state).count == 1)
    }

    @Test func conditionsStillApplyAndAsleepSeesTheImpsOwnSleep() {
        var prefs = ImpPreferences.withWaitingImp()
        prefs.shortcuts = [Shortcut(name: "Nap", trigger: Trigger(.idle, value: "10"),
                                    conditions: [Condition(.charger, value: "plugged")], steps: [Step(.sleep)]),
                           Shortcut(name: "Stir", trigger: Trigger(.near), conditions: [Condition(.asleep, value: "true")], steps: [Step(.wake)])]
        #expect(prefs.bodyShortcuts(of: imp, on: .idle(from: 9, to: 11), in: MacState(charging: false)).isEmpty)
        #expect(prefs.bodyShortcuts(of: imp, on: .idle(from: 9, to: 11), in: MacState(charging: true)).count == 1)
        let near = MacEvent.near(from: -1, to: 0)
        #expect(prefs.bodyShortcuts(of: imp, on: near, in: MacState(asleep: false)).isEmpty)
        #expect(prefs.bodyShortcuts(of: imp, on: near, in: MacState(asleep: true)).count == 1)
    }

    @Test func storedFormatRoundTrips() throws {
        let s = Shortcut(name: "Nap", trigger: Trigger(.idle, value: "30"), conditions: [Condition(.hours, value: "22:00-07:00")],
                         steps: [Step(.say, value: "Zzz"), Step(.sleep, value: "Yawn")])
        let back = try JSONDecoder().decode(Shortcut.self, from: JSONEncoder().encode(s))
        #expect(back == s)
        #expect(AnimationRef(key: AnimationRef.custom(UUID(uuidString: "11111111-1111-4111-8111-111111111111")!).key)
                == .custom(UUID(uuidString: "11111111-1111-4111-8111-111111111111")!))
        #expect(AnimationRef(key: "nonsense") == nil)
    }

    @Test func summariesAreReadable() {
        #expect(!Trigger(.idle, value: "240").summary.isEmpty)
        #expect(Trigger.starter(.idle).idleSeconds == 240)
        #expect(Trigger(.idle, value: "1").idleSeconds == Trigger.idleRange.lowerBound)
    }

    // MARK: Running

    @Test func onlyAnAskSetOffByTheMacOrTheClockRests() {
        let ask = Step(.ask, value: "look")
        let now = Date(), recent = now.addingTimeInterval(-10), old = now.addingTimeInterval(-61)
        let byClock = Shortcut(name: "A", trigger: Trigger(.every, value: "5"), steps: [Step(.say, value: "hi"), ask])
        #expect(byClock.restsAfterGoingOff)
        #expect(!byClock.mayRun(lastFired: recent, isFree: true, now: now), "rests for 60 s")
        #expect(byClock.mayRun(lastFired: old, isFree: true, now: now))
        #expect(!byClock.mayRun(lastFired: nil, isFree: false, now: now), "a busy Imp waits")
        for event in [TriggerEvent.keys, .click, .poke, .stroke, .near, .away] {
            let byPerson = Shortcut(name: "P", hotkey: event == .keys ? Hotkey(keyCode: 1, modifiers: 0) : nil, trigger: Trigger(event), steps: [ask])
            #expect(!byPerson.restsAfterGoingOff && byPerson.mayRun(lastFired: recent, isFree: false, now: now), "\(event)")
        }
        let body = Shortcut(name: "B", trigger: Trigger(.idle, value: "30"), steps: [Step(.play, value: "Yawn"), Step(.sleep)])
        #expect(!body.restsAfterGoingOff && body.mayRun(lastFired: recent, isFree: false, now: now), "body-only triggers never rest")
        let talks = Shortcut(name: "T", trigger: Trigger(.wake), steps: [Step(.say, value: "hi")])
        #expect(!talks.restsAfterGoingOff && talks.mayRun(lastFired: recent, isFree: true, now: now))
        #expect(!talks.mayRun(lastFired: nil, isFree: false, now: now), "but it doesn't talk over the person")
    }

    @Test func everyGestureIsTheEventOfTheSameName() {
        #expect(TriggerEvent.gestures.map(\.rawValue) == ["poke", "hold", "drag", "drop", "shake", "stroke", "tickle", "circle", "swish", "rush", "dangle"])
        for g in TriggerEvent.gestures {
            #expect(Trigger(g).matches(.gesture(g)))
            #expect(!Trigger(g).matches(.gesture(g == .poke ? .hold : .poke)))
            #expect(!Trigger(g).matches(.away))
        }
        #expect(!Trigger(.click).matches(.gesture(.poke)))
    }

    @Test func allMatchingTriggersGoOffInListOrder() {
        var prefs = ImpPreferences.withWaitingImp()
        prefs.shortcuts = ["one", "two", "three"].map { Shortcut(name: $0, trigger: Trigger(.poke), steps: [Step(.say, value: $0)]) }
        let fired = prefs.triggers(for: imp).filter { $0.fires(on: .gesture(.poke), in: state) }
        #expect(fired.map(\.name) == ["one", "two", "three"])
    }

    @Test func cursorWatchingRunsOnlyWhileATriggerNeedsIt() {
        var prefs = ImpPreferences.withWaitingImp()
        prefs.mouseGames = true
        #expect(!prefs.watchesCursor)
        prefs.shortcuts = [Shortcut(name: "Ouch", trigger: Trigger(.poke), steps: [Step(.say, value: "Ouch")])]
        #expect(!prefs.watchesCursor, "a poke is a click on the Imp, not the cursor from afar")
        prefs.shortcuts.append(Shortcut(name: "Purr", trigger: Trigger(.stroke), steps: [Step(.say, value: "Purr")]))
        #expect(prefs.watchesCursor)
        prefs.shortcuts[1].isEnabled = false
        #expect(!prefs.watchesCursor)
    }
}
