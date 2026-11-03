import CoreGraphics
import Foundation
import Testing
@testable import ImpKit

/// Sleep, wake and the like are triggers: they run on the body, from the same list, with no brain.
@Suite struct BodyTriggerTests {
    private let imp = UUID()
    private let state = MacState()

    @Test func idleGoesOffOnceAsTheTimePassesItsNumber() {
        let t = Trigger(.idle, number: 240)
        #expect(t.matches(.idle(from: 239.9, to: 240.1)))
        #expect(t.matches(.idle(from: 200, to: 240)))
        #expect(!t.matches(.idle(from: 100, to: 239)))
        #expect(!t.matches(.idle(from: 240.1, to: 241)), "already past it: no new alarm")
        #expect(!t.matches(.cursorEnter))
    }

    @Test func idleWatchReportsEachStretchAndStartsOverAfterATouch() {
        var watch = IdleWatch()
        #expect(watch.advance(to: 10) == .idle(from: 0, to: 10))
        #expect(watch.advance(to: 20) == .idle(from: 10, to: 20))
        #expect(watch.advance(to: 3) == nil, "touched: the clock restarts")
        #expect(watch.advance(to: 6) == .idle(from: 3, to: 6))
    }

    @Test func cursorEntersAndLeavesWithoutFlickering() {
        var near = CursorProximity(radius: 80, margin: 12)
        #expect(near.update(distance: 300) == nil)
        #expect(near.update(distance: 70) == .cursorEnter)
        #expect(near.update(distance: 60) == nil)
        #expect(near.update(distance: 85) == nil, "on the edge: still near")
        #expect(near.update(distance: 120) == .cursorLeave)
        #expect(near.update(distance: 130) == nil)
        #expect(Trigger(.enter).matches(.cursorEnter))
        #expect(Trigger(.leave).matches(.cursorLeave))
        #expect(!Trigger(.enter).matches(.cursorLeave))
    }

    @Test func defaultsArePresentAndRunWithoutABrain() {
        let prefs = ImpPreferences()
        let sleep = prefs.shortcuts.first { $0.id == Shortcut.sleepID }
        let wake = prefs.shortcuts.first { $0.id == Shortcut.wakeID }
        #expect(sleep?.trigger == Trigger(.idle, number: Trigger.defaultIdleSeconds))
        #expect(sleep?.command == .sleep)
        #expect(sleep?.animation != nil)
        #expect(wake?.trigger.kind == .enter)
        #expect(wake?.command == .wakeUp)
        #expect(sleep?.runsLocally == true && wake?.runsLocally == true)
        #expect(sleep?.isRunnable == true, "nothing to say: it needs no instruction")
        #expect(sleep?.performer == nil, "every Imp")
        #expect(Trigger.defaultIdleSeconds == 240)
    }

    @Test func idleSleepAndHoverWakeComeFromTheList() {
        let prefs = ImpPreferences()
        let slept = prefs.bodyShortcuts(of: imp, on: .idle(from: 239, to: 241), in: state)
        #expect(slept.map(\.id) == [Shortcut.sleepID])
        #expect(slept.allSatisfy { $0.runsLocally })
        let woke = prefs.bodyShortcuts(of: imp, on: .cursorEnter, in: state)
        #expect(woke.map(\.id) == [Shortcut.wakeID])
        #expect(prefs.bodyShortcuts(of: imp, on: .cursorLeave, in: state).isEmpty)
    }

    @Test func eachTriggerCanBeSwitchedOff() {
        var prefs = ImpPreferences()
        let i = prefs.shortcuts.firstIndex { $0.id == Shortcut.sleepID }!
        prefs.shortcuts[i].isEnabled = false
        #expect(prefs.bodyShortcuts(of: imp, on: .idle(from: 239, to: 241), in: state).isEmpty)
        #expect(prefs.bodyShortcuts(of: imp, on: .cursorEnter, in: state).count == 1)
        prefs.shortcuts[i].isEnabled = true
        #expect(prefs.bodyShortcuts(of: imp, on: .idle(from: 239, to: 241), in: state).count == 1)
    }

    @Test func timeAndAnimationAreSettings() {
        var prefs = ImpPreferences()
        let i = prefs.shortcuts.firstIndex { $0.id == Shortcut.sleepID }!
        prefs.shortcuts[i].trigger.number = 60
        prefs.shortcuts[i].animation = .preset(.sleep)
        #expect(prefs.bodyShortcuts(of: imp, on: .idle(from: 239, to: 241), in: state).isEmpty)
        let found = prefs.bodyShortcuts(of: imp, on: .idle(from: 59, to: 61), in: state)
        #expect(found.first?.animation == .preset(.sleep))
    }

    @Test func aTriggerForOneImpIsNotForAnother() {
        var prefs = ImpPreferences()
        prefs.shortcuts.removeAll()
        let other = UUID()
        prefs.shortcuts.append(Shortcut(name: "Nap", prompt: "", performer: other, trigger: Trigger(.idle, number: 10), command: .sleep))
        #expect(prefs.bodyShortcuts(of: imp, on: .idle(from: 9, to: 11), in: state).isEmpty)
        #expect(prefs.bodyShortcuts(of: other, on: .idle(from: 9, to: 11), in: state).count == 1)
    }

    @Test func conditionsStillApply() {
        var prefs = ImpPreferences()
        prefs.shortcuts.removeAll()
        prefs.shortcuts.append(Shortcut(name: "Nap", prompt: "", trigger: Trigger(.idle, number: 10),
                                        conditions: [Trigger(.charger, flag: true)], command: .sleep))
        #expect(prefs.bodyShortcuts(of: imp, on: .idle(from: 9, to: 11), in: MacState(charging: false)).isEmpty)
        #expect(prefs.bodyShortcuts(of: imp, on: .idle(from: 9, to: 11), in: MacState(charging: true)).count == 1)
    }

    @Test func aFreshInstallHasTheDefaultsAndDeletedOnesStayDeleted() throws {
        var p = ImpPreferences()
        #expect(p.shortcuts.contains { $0.id == Shortcut.sleepID } && p.shortcuts.contains { $0.id == Shortcut.wakeID })
        p.shortcuts.removeAll { $0.id == Shortcut.sleepID }
        let back = try JSONDecoder().decode(ImpPreferences.self, from: JSONEncoder().encode(p))
        #expect(!back.shortcuts.contains { $0.id == Shortcut.sleepID })
        #expect(back.shortcuts.filter { $0.id == Shortcut.wakeID }.count == 1)
    }

    @Test func storedFormatRoundTripsTheAnimationAndTheKind() throws {
        let s = Shortcut.bodyDefaults[0]
        let back = try JSONDecoder().decode(Shortcut.self, from: JSONEncoder().encode(s))
        #expect(back == s)
        #expect(back.animation == s.animation)
        #expect(AnimationRef(key: AnimationRef.custom(UUID(uuidString: "11111111-1111-4111-8111-111111111111")!).key)
                == .custom(UUID(uuidString: "11111111-1111-4111-8111-111111111111")!))
        #expect(AnimationRef(key: "nonsense") == nil)
    }

    @Test func summariesAreReadable() {
        #expect(!Trigger(.idle, number: 240).summary.isEmpty)
        #expect(Trigger.starter(.idle).idleSeconds == 240)
        #expect(Trigger(.idle, number: 1).idleSeconds == Trigger.idleRange.lowerBound)
        #expect(Trigger.Kind.idle.isEvent && !Trigger.Kind.idle.isCondition)
    }
}
