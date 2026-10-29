import AppKit
import CoreGraphics
import ImpKit
import Observation
import os

/// Imp's "inner life": wakes up smoothly, notices when the cursor's been still, and fills quiet
/// moments with small routines (glances, humming, ideas, head turns, dozing off…).
/// Ticks at ~10 Hz with all the others (see `LifeTicker`), off the render loop, so drawing never mutates state.
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

    @ObservationIgnored private weak var model: ImpModel?
    /// Each Imp's first routine comes at its own moment, so a troupe doesn't start in unison.
    @ObservationIgnored private var nextAnticAt = Date().addingTimeInterval(.random(in: 5...12))
    @ObservationIgnored private var lastName = ""
    /// The animation holds its last beat until then (see `sustain`).
    @ObservationIgnored private var sustainedUntil = Date.distantPast

    /// Seconds without mouse movement before Imp starts entertaining itself.
    static let quietAfter: Double = 5

    var step: AnticStep? {
        guard let antic, antic.steps.indices.contains(stepIndex) else { return nil }
        return antic.steps[stepIndex]
    }

    /// The glyph the current animation shows: how long it has shown and has left (it fades
    /// out before it goes; one held by a sustained animation stays).
    func glyph(at date: Date) -> (glyph: Glyph, age: Double, remaining: Double)? {
        guard let antic, var g = antic.steps.glyph(at: stepIndex, elapsed: date.timeIntervalSince(stepStarted)) else { return nil }
        if sustainedUntil > date { g.remaining = max(g.remaining, 0.5) }
        return g
    }

    /// Keeps `reaction` going, holding its last beat, until `until`, if it's what's playing
    /// (petting, a cuddle, being carried last as long as you keep at it). Returns whether it was.
    @discardableResult
    func sustain(_ reaction: Reaction, until: Date) -> Bool {
        guard antic?.name == reaction.rawValue else { return false }
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
        stepIndex = 0
        stepStarted = Date()
        sustainedUntil = .distantPast
        lastName = a.name
        if a.steps.first?.hop == true { hop(at: stepStarted) }
    }

    /// Starts a hop, unless the last is still in the air: restarting it would drop the body
    /// from mid-jump straight to the ground.
    private func hop(at date: Date) {
        if Motion.canHop(since: date.timeIntervalSince(hopAt)) { hopAt = date }
    }

    func tick(now: Date, mouse: CGPoint, mouseIdle: TimeInterval) {
        guard let model else { return }

        let nowLively = mouseIdle < 1 || now.timeIntervalSince(hopAt) < 1
            || (model.flash.map { $0.until > now } ?? false) || model.app.stage.focus(for: model) != nil
        if nowLively != lively { lively = nowLively }

        // Waking: the cursor sneaks up on a sleeping imp.
        if model.mood(at: now) == .sleepy {
            let d = hypot(mouse.x - model.impCenter.x, mouse.y - model.impCenter.y)
            if d < 80 {
                model.touch()
                wake()
            }
            return
        }

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
                    nextAnticAt = now.addingTimeInterval(.random(in: 6...14))
                }
            }
        }

        // Only play when nothing else is going on.
        let free = model.isFree(at: now) && model.prefs.antics
        // A start time that passed while Imp was busy must not fire the instant it's free again.
        nextAnticAt = AnticPacing.nextStart(nextAnticAt, now: now, free: free)
        // Tricks and reactions only give way to real work. Idle antics also to the mouse.
        let interrupted = antic.map { a in
            a.sticky ? model.isBusy : (!free || mouseIdle < 1)
        } ?? false
        if let a = antic, !a.isWake, interrupted {
            antic = nil                                   // the user is back: follow the cursor again
            nextAnticAt = now.addingTimeInterval(.random(in: 3...6))
        }
        guard free, antic == nil, mouseIdle >= Self.quietAfter, now >= nextAnticAt else { return }
        if let routine = pick(model: model) {
            play(routine)
        } else {
            nextAnticAt = now.addingTimeInterval(.random(in: 6...14))    // nothing allowed right now
        }
    }

    // MARK: Animations

    /// Plays an animation on request: a word you typed, a mouse game, a click, another Imp, a
    /// preview. With `facing`, the whole routine is aimed that way (a nod toward a friend
    /// instead of toward you). Requested animations aren't interrupted by the mouse.
    func perform(_ reaction: Reaction, facing: CGPoint? = nil) {
        guard isUnlocked(reaction) else { return }
        let user = CGPoint(x: 0, y: 0.1)
        let steps = steps(for: reaction)
        let aimed = facing.map { aim in
            steps.map { step in
                var s = step
                if let l = step.look {
                    s.look = CGPoint(x: max(-1, min(1, aim.x + l.x - user.x)), y: max(-1, min(1, aim.y + l.y - user.y)))
                }
                return s
            }
        } ?? steps
        play(Antic(name: reaction.rawValue, steps: aimed, sticky: true))
    }

    /// Whether this Imp may play `reaction` now: the ones that unlock with a favourite colour
    /// only while it wears it.
    func isUnlocked(_ reaction: Reaction) -> Bool {
        guard reaction.unlocksWithFavoriteColor else { return true }
        return model.map { $0.profile.isFavorite($0.profile.hue) } ?? false
    }

    private func steps(for reaction: Reaction) -> [AnticStep] {
        Antics.steps(for: reaction, work: model.map(lookToward(screenCenterOf:)) ?? .zero)
    }

    // MARK: Routines

    /// A routine for a quiet moment, from the animations the user lets play then (weighted,
    /// and never the same one twice in a row).
    private func pick(model: ImpModel) -> Antic? {
        var pool = model.prefs.animations(for: .idle).filter(isUnlocked)
        if pool.count > 1 { pool.removeAll { $0.rawValue == lastName } }
        let total = pool.reduce(0) { $0 + $1.idleWeight }
        guard total > 0 else { return nil }
        var r = Int.random(in: 0..<total)
        for reaction in pool {
            if r < reaction.idleWeight { return Antic(name: reaction.rawValue, steps: steps(for: reaction)) }
            r -= reaction.idleWeight
        }
        return nil
    }

    /// Direction from Imp toward the middle of its screen — roughly where you're working.
    private func lookToward(screenCenterOf model: ImpModel) -> CGPoint {
        let screen = NSScreen.screens.first { $0.frame.contains(model.impCenter) } ?? NSScreen.main
        guard let f = screen?.visibleFrame else { return .zero }
        let dx = f.midX - model.impCenter.x, dy = model.impCenter.y - (f.midY + f.height * 0.1)
        let d = max(1, hypot(dx, dy))
        let k = min(1, d / 220)
        return CGPoint(x: dx / d * k, y: dy / d * k * 0.8)
    }
}
