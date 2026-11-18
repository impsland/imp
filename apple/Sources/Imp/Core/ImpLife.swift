import AppKit
import CoreGraphics
import ImpKit
import Observation
import os

/// Imp's "inner life": wakes up smoothly, plays the animation it is asked to, and reports what happens to
/// its body (left alone, the cursor near or away) to the triggers. Nothing starts on its own. Ticks with all the others, at 10 Hz
/// while anything moves and slower at rest (see `LifeTicker`), off the render loop, so drawing never mutates
/// state.
@MainActor @Observable
final class ImpLife {
    private(set) var antic: Antic?
    private(set) var stepIndex = 0
    private(set) var stepStarted = Date()
    /// Start of the last hop.
    private(set) var hopAt = Date.distantPast
    /// Something is moving right now (cursor, a hop, a reaction, another Imp on stage), so
    /// Imp should draw at full frame rate. Changes only when it flips, so views re-render rarely.
    private(set) var lively = true

    /// What the ticker needs of this Imp (set by every tick).
    @ObservationIgnored private(set) var tickState = TickState.busy

    @ObservationIgnored private weak var model: ImpModel?
    /// The animation holds its last beat until then (see `sustain`).
    @ObservationIgnored private var sustainedUntil = Date.distantPast
    /// Turns the time since it was last touched, and where the cursor is, into events for the triggers.
    @ObservationIgnored private var idleWatch = IdleWatch()
    @ObservationIgnored private var proximity = CursorProximity()

    /// Seconds without mouse movement before Imp starts entertaining itself.
    static let quietAfter: Double = 5

    var step: AnticStep? {
        guard let antic, antic.steps.indices.contains(stepIndex) else { return nil }
        return antic.steps[stepIndex]
    }

    /// The glyph the current animation shows: how long it has shown and has left (it fades
    /// out before it goes. One held by a sustained animation stays).
    func glyph(at date: Date) -> (glyph: Glyph, age: Double, remaining: Double)? {
        guard let antic, var g = antic.steps.glyph(at: stepIndex, elapsed: date.timeIntervalSince(stepStarted)) else { return nil }
        if sustainedUntil > date { g.remaining = max(g.remaining, 0.5) }
        return g
    }

    /// Keeps `reaction` going, holding its last beat, until `until`, if it's what's playing
    /// (petting, a cuddle, being carried last as long as you keep at it). Returns whether it was.
    @discardableResult
    func sustain(_ ref: AnimationRef, until: Date) -> Bool {
        guard antic?.name == ref.key else { return false }
        sustainedUntil = until
        return true
    }

    func start(_ model: ImpModel) {
        self.model = model
        LifeTicker.shared.add(self)
    }

    /// Smooth wake-up: eyes pop open, a happy little stretch, then back to normal.
    func wake() {
        play(Antic(name: "wake", steps: [
            AnticStep(duration: 0.55, look: CGPoint(x: 0, y: -0.15), mood: .surprised),
            AnticStep(duration: 0.9, look: CGPoint(x: 0, y: -0.05), mood: .happy),
        ], isWake: true))
    }

    func cancel() {
        antic = nil
    }

    /// For good: the Imp went home (the shared ticker would otherwise keep driving it).
    func stop() {
        LifeTicker.shared.remove(self)
        antic = nil
    }

    private func play(_ a: Antic) {
        #if DEBUG
        Logger(subsystem: "app.imp.Imp", category: "life").info("antic: \(a.name, privacy: .public)")
        #endif
        antic = a
        LifeTicker.shared.nudge()
        stepIndex = 0
        stepStarted = Date()
        sustainedUntil = .distantPast
        if a.steps.first?.hop == true { hop(at: stepStarted) }
    }

    /// Starts a hop, unless the last is still in the air: restarting it would drop the body
    /// from mid-jump straight to the ground.
    private func hop(at date: Date) {
        if Motion.canHop(since: date.timeIntervalSince(hopAt)) { hopAt = date }
    }

    /// The cursor just moved: draw at the full rate now (the next tick keeps it so while it moves).
    func mouseMoved() {
        tickState = .busy
        if !lively { lively = true }
    }

    func tick(now: Date, mouse: CGPoint, mouseIdle: TimeInterval) {
        guard let model else { return }
        defer {
            tickState = model.mood(at: now) == .sleepy && antic == nil ? .asleep : (lively || antic != nil ? .busy : .calm)
        }

        let nowLively = mouseIdle < 1 || now.timeIntervalSince(hopAt) < 1
            || (model.flash.map { $0.until > now } ?? false) || model.app.stage.focus(for: model) != nil
        if nowLively != lively { lively = nowLively }

        // What happens to its body (left alone, the cursor coming close or going away) goes to the
        // trigger list: falling asleep and waking are triggers there, like any other.
        if model.visit?.isAwake != false {
            let idleFor = now.timeIntervalSince(model.lastActivity)
            let reach = hypot(mouse.x - model.impCenter.x, mouse.y - model.impCenter.y)
            for event in [idleWatch.advance(to: idleFor), proximity.update(distance: reach, now: now.timeIntervalSinceReferenceDate)].compactMap({ $0 }) {
                model.app.fire(event, at: model)
            }
        }

        // Going after the cursor, if that is how this Imp is set: hops and glides stop with Reduce Motion.
        let goes = FollowMath.moves(model.followMode, reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
            && model.visit == nil && model.isFree(at: now) && now >= model.followBlockedUntil && !model.app.isAway(model.id)
        model.followCursor = goes ? mouse : nil
        if goes { model.onFollow?() }

        // Advance the current routine.
        if let a = antic {
            if now.timeIntervalSince(stepStarted) >= a.steps[stepIndex].duration {
                if stepIndex + 1 < a.steps.count {
                    stepIndex += 1
                    stepStarted = now
                    if a.steps[stepIndex].hop { hop(at: now) }
                } else if now < sustainedUntil {
                    // Still being petted, held or carried: stay in the last beat.
                } else {
                    antic = nil
                }
            }
        }

        // Animations never start on their own: whatever plays was asked for by a trigger, a tool, or the person.
    }

    // MARK: Animations

    /// Plays an animation on request: a word you typed, a mouse game, a click, another Imp, a
    /// preview. With `facing`, the whole routine is aimed that way (a nod toward a friend
    /// instead of toward you). Requested animations aren't interrupted by the mouse.
    func perform(_ ref: AnimationRef, facing: CGPoint? = nil) {
        let user = CGPoint(x: 0, y: 0.1)
        let steps = steps(for: ref)
        guard !steps.isEmpty else { return }
        let aimed = facing.map { aim in
            steps.map { step in
                var s = step
                if let l = step.look {
                    s.look = CGPoint(x: max(-1, min(1, aim.x + l.x - user.x)), y: max(-1, min(1, aim.y + l.y - user.y)))
                }
                return s
            }
        } ?? steps
        play(Antic(name: ref.key, steps: aimed, sticky: true))
    }

    /// Plays beats another device sent: the Imp's home acting an animation out on its body here.
    func perform(beats: [AnimationBeat]) {
        guard !beats.isEmpty else { return }
        play(Antic(name: "home", steps: beats.map(AnticStep.init), sticky: true))
    }

    /// The beats it plays for `ref`: its own version of it or a shared one, at its own tempo.
    func steps(for ref: AnimationRef) -> [AnticStep] {
        guard let model else { return [] }
        return Antics.steps(for: ref, prefs: model.prefs, imp: model.id)
    }
}
