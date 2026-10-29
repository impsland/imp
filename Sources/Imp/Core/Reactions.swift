import AppKit
import ImpKit

/// Plays animations on request (clicks, colours, previews) and turns the ways you handle an Imp
/// into them: mouse games, a cursor resting on or beside it, pressing, carrying and shaking it.
/// A game belongs to whichever Imp you play with, and the rest of the troupe may join in (see
/// `Stage`). Only the cursor is watched, never the keyboard.
@MainActor
final class Reactions {
    private unowned let app: AppModel
    private var gestures: [UUID: MouseGestures] = [:]
    private var mouseMonitor: Any?
    /// Looks for a resting cursor (a stare, a linger) a few times a second.
    private var restTimer: Timer?
    private var lastPlayed: [String: Date] = [:]
    /// The last time the cursor moved (seconds since boot).
    private var lastMove = ProcessInfo.processInfo.systemUptime

    /// Seconds between looks for a resting cursor.
    static let restCheck: TimeInterval = 0.25
    /// The same mouse game won't repeat sooner than this.
    static let cooldown: TimeInterval = 6
    /// The cursor's been away this long: moving it again is coming back.
    static let away: TimeInterval = 60
    /// A stroke or tickle keeps the Imp enjoying it this long after the last one.
    static let afterglow: TimeInterval = 1.2

    init(app: AppModel) { self.app = app }

    /// The cursor is only watched while some switched-on animation is started by it (and Mouse
    /// games is on): see `ImpPreferences.watchesCursor`.
    func apply(_ prefs: ImpPreferences) {
        if prefs.watchesCursor, mouseMonitor == nil {
            mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved]) { [weak self] _ in
                MainActor.assumeIsolated { self?.mouseMoved() }
            }
            restTimer = Timer.scheduledTimer(withTimeInterval: Self.restCheck, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.checkRest() }
            }
            restTimer?.tolerance = Self.restCheck / 2
            lastMove = ProcessInfo.processInfo.systemUptime
        } else if !prefs.watchesCursor, let monitor = mouseMonitor {
            NSEvent.removeMonitor(monitor)
            mouseMonitor = nil
            restTimer?.invalidate()
            restTimer = nil
            gestures = [:]
        }
    }

    // MARK: The cursor

    func mouseMoved() {
        guard app.prefs.watchesCursor else { return }
        let p = NSEvent.mouseLocation, t = ProcessInfo.processInfo.systemUptime
        if t - lastMove > Self.away, let nearest = nearest(to: p) { handle(.comeback, by: nearest) }
        lastMove = t
        for imp in app.imps {
            let head = imp.headOnScreen
            if let trigger = gestures[imp.id, default: MouseGestures()].move(to: p, at: t, center: head.center, radius: head.radius) {
                handle(trigger, by: imp)
            }
        }
    }

    /// The cursor may be resting on an Imp's face or beside it.
    private func checkRest() {
        guard NSEvent.pressedMouseButtons == 0 else { return }
        let t = ProcessInfo.processInfo.systemUptime
        for imp in app.imps {
            let head = imp.headOnScreen
            if let trigger = gestures[imp.id]?.rest(at: t, center: head.center, radius: head.radius) {
                handle(trigger, by: imp)
            }
        }
    }

    /// The Imp was pressed: a cursor left on it after a click or a drag isn't a stare or a stroke.
    func pressed(_ imp: ImpModel) {
        gestures[imp.id, default: MouseGestures()].pressed()
    }

    private func nearest(to p: CGPoint) -> ImpModel? {
        app.imps.min { hypot($0.impCenter.x - p.x, $0.impCenter.y - p.y) < hypot($1.impCenter.x - p.x, $1.impCenter.y - p.y) }
    }

    // MARK: Playing

    /// Something you did to an Imp: plays the animation its trigger starts, if any. If that's
    /// already playing (you keep stroking it), it carries on instead of starting over. `held`
    /// keeps it going until `release(_:by:)` (a press, a carry).
    func handle(_ trigger: AnimationTrigger, by imp: ImpModel, held: Bool = false) {
        guard trigger.watchesCursor ? app.prefs.watchesCursor : true,
              let ref = app.prefs.ref(for: trigger, imp: imp.id) else { return }
        let until = held ? Date.distantFuture : Date().addingTimeInterval(Self.afterglow)
        if imp.life.sustain(ref, until: until) { return }
        // Cursor games have a cooldown: a game played again and again stops being a reaction.
        if trigger.watchesCursor,
           Date().timeIntervalSince(lastPlayed["\(imp.id)/\(ref.key)"] ?? .distantPast) < Self.cooldown { return }
        play(ref, by: imp)
        if held { imp.life.sustain(ref, until: until) }
    }

    /// You let go: the animation `trigger` kept going finishes its last beat.
    func release(_ trigger: AnimationTrigger, by imp: ImpModel) {
        guard let ref = app.prefs.ref(for: trigger, imp: imp.id) else { return }
        imp.life.sustain(ref, until: Date())
    }

    /// Plays an animation now (gestures, clicks, Settings previews). The troupe may join in.
    func play(_ reaction: Reaction, by imp: ImpModel? = nil) { play(.preset(reaction), by: imp) }

    /// Plays a built-in or made animation. Only built-in ones set the troupe off (they know what those mean).
    func play(_ ref: AnimationRef, by imp: ImpModel? = nil) {
        guard let imp = imp ?? app.focused, !imp.isBusy, imp.life.isUnlocked(ref) else { return }
        lastPlayed["\(imp.id)/\(ref.key)"] = Date()
        imp.touch()
        imp.life.perform(ref)
        if let reaction = ref.preset { app.stage.broadcast(.reacted(reaction), from: imp) }
    }

    /// Plays whatever animation a trigger starts (nil when none is assigned or it's switched off).
    @discardableResult
    func play(_ trigger: AnimationTrigger, by imp: ImpModel) -> AnimationRef? {
        guard let ref = app.prefs.ref(for: trigger, imp: imp.id) else { return nil }
        play(ref, by: imp)
        return ref
    }
}
