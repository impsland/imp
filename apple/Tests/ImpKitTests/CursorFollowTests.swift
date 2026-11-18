import CoreGraphics
import Foundation
import Testing
@testable import ImpKit

extension FollowChange { var isApply: Bool { if case .apply = self { true } else { false } } }

@Suite struct CursorFollowTests {
    private let side = 112.0

    @Test func modesAndTheirEffects() {
        #expect(FollowMode.eyes.title == "Eyes")
        #expect(!FollowMode.off.eyesFollow)
        #expect(FollowMode.eyes.eyesFollow && !FollowMode.eyes.movesBody)
        #expect(FollowMode.hop.movesBody && FollowMode.glide.movesBody)
        #expect(ImpPreferences.baseFollow.mode == .eyes && ImpPreferences.baseFollow.speed == 1)
    }

    @Test func aFollowTriggerRoundTripsThroughAKit() throws {
        let s = Shortcut(name: "Hop", trigger: Trigger(.start), steps: [Step(.follow, value: "hop", speed: 1.5)])
        #expect(s.steps[0].act.isLocal && !s.steps[0].act.usesAnimation)
        let text = Kit(triggers: [s]).json()
        #expect(text.contains(#""follow""#) && text.contains(#""hop""#) && text.contains("1.5"))
        let back = try #require(try Kit.parse(text).triggers.first)
        #expect(back.steps == s.steps && back.followSetting?.mode == .hop && back.followSetting?.speed == 1.5)
        let coded = try JSONDecoder().decode(Shortcut.self, from: JSONEncoder().encode(s))
        #expect(coded.followSetting?.mode == .hop && coded.followSetting?.speed == 1.5)
        let fast = Shortcut(name: "x", trigger: Trigger(.start), steps: [Step(.follow, value: "hop", speed: 9)])
        #expect(fast.followSetting?.mode == .hop && fast.followSetting?.speed == FollowMath.speedRange.upperBound)
    }

    @Test func theModelAddsAFollowTrigger() throws {
        let args = try JSONDecoder().decode(JSONValue.self, from: Data(#"{"on": "start", "do": [{"act": "follow", "value": "glide", "speed": 0.5}]}"#.utf8))
        let s = try Shortcut(tool: args, imp: UUID())
        #expect(s.followSetting?.mode == .glide && s.followSetting?.speed == FollowMath.speedRange.lowerBound)
        let slow = try JSONDecoder().decode(JSONValue.self, from: Data(#"{"on": "start", "do": [{"act": "follow", "value": "glide", "speed": 0.1}]}"#.utf8))
        #expect(throws: ToolArgumentError.self) { try Shortcut(tool: slow, imp: UUID()) }
        let bad = try JSONDecoder().decode(JSONValue.self, from: Data(#"{"on": "start", "do": [{"act": "follow", "value": "zoom"}]}"#.utf8))
        #expect(throws: ToolArgumentError.self) { try Shortcut(tool: bad, imp: UUID()) }
    }

    @Test func followTriggersDecideTheRuntimeMode() {
        let imp = UUID()
        let empty = ImpPreferences()
        var p = empty
        let start = Shortcut(name: "f", performer: imp, trigger: Trigger(.start), steps: [Step(.follow, value: "hop")])
        let app = Shortcut(name: "g", performer: imp, trigger: Trigger(.app, value: "Safari"), steps: [Step(.follow, value: "glide")])
        p.shortcuts = [start]
        // New start trigger: applies at once.
        #expect(p.followChange(from: empty, for: imp) == .apply(start))
        // A trigger of another kind waits for its event.
        var q = empty; q.shortcuts = [app]
        #expect(q.followChange(from: empty, for: imp) == nil)
        // Nothing changed: nothing to do.
        #expect(p.followChange(from: p, for: imp) == nil)
        // Switching it off (last one): back to the base mode.
        var off = p; off.setTrigger(start.id, enabled: false, for: imp)
        #expect(off.followChange(from: p, for: imp) == .reset)
        // Switching it on again applies it.
        #expect(p.followChange(from: off, for: imp)?.isApply == true)
        // Removing the last one resets, but not while another remains.
        var gone = p; gone.removeTrigger(start.id, for: imp)
        #expect(gone.followChange(from: p, for: imp) == .reset)
        var two = p; two.shortcuts.append(app)
        var one = two; one.removeTrigger(start.id, for: imp)
        #expect(one.followChange(from: two, for: imp) == nil)
        // Another Imp is not touched.
        #expect(p.followChange(from: empty, for: UUID()) == nil)
    }

    @Test func reduceMotionTurnsHopsAndGlidesIntoEyes() {
        #expect(FollowMode.hop.effective(reduceMotion: true) == .eyes)
        #expect(FollowMode.glide.effective(reduceMotion: true) == .eyes)
        #expect(FollowMode.eyes.effective(reduceMotion: true) == .eyes)
        #expect(FollowMode.off.effective(reduceMotion: true) == .off)
        #expect(FollowMath.moves(.glide, reduceMotion: false))
        #expect(!FollowMath.moves(.glide, reduceMotion: true))
        #expect(!FollowMath.moves(.hop, reduceMotion: true))
        #expect(!FollowMath.moves(.off, reduceMotion: false))
        #expect(!FollowMath.moves(.eyes, reduceMotion: false))
    }

    @Test func itStopsShortOfTheCursor() {
        let stop = FollowMath.stopDistance(side: side)
        let target = FollowMath.target(center: CGPoint(x: 0, y: 0), cursor: CGPoint(x: 500, y: 0), side: side)
        #expect(target != nil)
        #expect(abs((target?.x ?? 0) - (500 - stop)) < 0.001)
        #expect(FollowMath.target(center: .zero, cursor: CGPoint(x: stop, y: 0), side: side) == nil, "already there")
        #expect(FollowMath.target(center: .zero, cursor: CGPoint(x: 10, y: 10), side: side) == nil, "cursor on top of it")
    }

    @Test func glideStepsTowardTheTargetAtItsSpeedAndNeverOvershoots() {
        let target = CGPoint(x: 1000, y: 0)
        let slow = FollowMath.glideStep(center: .zero, toward: target, side: side, speed: 0.5, dt: 0.1)
        let fast = FollowMath.glideStep(center: .zero, toward: target, side: side, speed: 2, dt: 0.1)
        #expect(slow.x > 0 && fast.x > slow.x)
        #expect(abs(fast.x / slow.x - 4) < 0.001)
        let near = FollowMath.glideStep(center: CGPoint(x: 998, y: 0), toward: target, side: side, speed: 2, dt: 1)
        #expect(near.x <= 1000)
        #expect(FollowMath.glideStep(center: target, toward: target, side: side, speed: 1, dt: 0.1) == target)
        // Walking it frame by frame arrives.
        var p = CGPoint.zero
        for _ in 0..<2000 { p = FollowMath.glideStep(center: p, toward: target, side: side, speed: 1, dt: 1 / 60) }
        #expect(hypot(p.x - target.x, p.y - target.y) < 1)
    }

    @Test func hopsCoverABodyAndABitAndLandOnTheLine() throws {
        let leg = try #require(FollowMath.hopLeg(center: .zero, cursor: CGPoint(x: 1000, y: 0), side: side, speed: 1))
        #expect(abs(leg.to.x - side * 1.3) < 0.001 && leg.to.y == 0)
        #expect(leg.center(at: 0) == leg.from)
        #expect(leg.center(at: 1) == leg.to)
        #expect(abs(leg.center(at: 0.5).y - leg.height) < 0.001, "highest half-way")
        #expect(leg.ground(at: 0.5).y == 0)
        let quick = try #require(FollowMath.hopLeg(center: .zero, cursor: CGPoint(x: 1000, y: 0), side: side, speed: 2))
        #expect(quick.duration < leg.duration && quick.pause < leg.pause)
    }

    @Test func aLastShortHopStopsAtTheStoppingDistance() throws {
        let stop = FollowMath.stopDistance(side: side)
        let leg = try #require(FollowMath.hopLeg(center: .zero, cursor: CGPoint(x: stop + 40, y: 0), side: side, speed: 1))
        #expect(abs(leg.to.x - 40) < 0.001)
        #expect(FollowMath.hopLeg(center: .zero, cursor: CGPoint(x: stop + 2, y: 0), side: side, speed: 1) == nil)
    }

    @Test func itStaysOnTheVisibleScreen() {
        let screen = CGRect(x: 0, y: 25, width: 1440, height: 850)
        let inside = FollowMath.keepVisible(CGPoint(x: 700, y: 400), side: side, in: screen)
        #expect(inside == CGPoint(x: 700, y: 400))
        let corner = FollowMath.keepVisible(CGPoint(x: -50, y: 2000), side: side, in: screen)
        #expect(corner == CGPoint(x: side / 2, y: screen.maxY - side / 2))
        let tiny = FollowMath.keepVisible(CGPoint(x: 0, y: 0), side: side, in: CGRect(x: 0, y: 0, width: 50, height: 50))
        #expect(tiny == CGPoint(x: 25, y: 25))
    }

    @Test func speedIsClamped() {
        #expect(FollowMath.clampedSpeed(0) == 0.5)
        #expect(FollowMath.clampedSpeed(99) == 2)
        #expect(FollowMath.clampedSpeed(1.3) == 1.3)
    }
}
