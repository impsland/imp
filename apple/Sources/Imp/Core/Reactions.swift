import AppKit
import ImpKit

/// Plays animations on request (previews, tools, triggers) and turns the ways you handle an Imp
/// into trigger events: every pointer gesture (poke, hold, drag, drop, shake, stroke, tickle,
/// circle, swish, rush, dangle) is fired at that Imp as the event of the same name, and the
/// triggers decide what happens. Only the cursor is watched, never the keyboard, and only while
/// some enabled trigger needs it (see `ImpPreferences.watchesCursor`).
@MainActor
final class Reactions {
    private unowned let app: AppModel
    private var gestures: [UUID: MouseGestures] = [:]
    private var mouseMonitor: Any?
    private var lastFired: [String: Date] = [:]

    /// The same gesture from the cursor won't repeat sooner than this.
    static let cooldown: TimeInterval = 6

    init(app: AppModel) { self.app = app }

    /// The cursor is only watched while some switched-on trigger is set off by it (and Mouse games is on).
    func apply(_ prefs: ImpPreferences) {
        if prefs.watchesCursor, mouseMonitor == nil {
            mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved]) { [weak self] _ in
                MainActor.assumeIsolated { self?.mouseMoved() }
            }
        } else if !prefs.watchesCursor, let monitor = mouseMonitor {
            NSEvent.removeMonitor(monitor)
            mouseMonitor = nil
            gestures = [:]
        }
    }

    // MARK: The cursor

    func mouseMoved() {
        guard app.prefs.watchesCursor else { return }
        let p = NSEvent.mouseLocation, t = ProcessInfo.processInfo.systemUptime
        for imp in app.imps {
            let head = imp.headOnScreen
            if let event = gestures[imp.id, default: MouseGestures()].move(to: p, at: t, center: head.center, radius: head.radius) {
                handle(event, by: imp)
            }
        }
    }

    /// The Imp was pressed: a cursor left on it after a click or a drag isn't a stroke.
    func pressed(_ imp: ImpModel) {
        gestures[imp.id, default: MouseGestures()].pressed()
    }

    // MARK: Gestures

    /// Something you did to an Imp: fires the trigger event of that name at it. Gestures made with
    /// the cursor alone repeat no sooner than `cooldown` (stroking goes on and on).
    func handle(_ event: TriggerEvent, by imp: ImpModel) {
        guard event.isGesture else { return }
        if event.watchesCursor {
            let key = "\(imp.id)/\(event.rawValue)"
            guard Date().timeIntervalSince(lastFired[key] ?? .distantPast) >= Self.cooldown else { return }
            lastFired[key] = Date()
        }
        app.fire(gesture: event, at: imp)
    }

    // MARK: Playing

    /// Plays an animation now (triggers, tools, Settings previews). A busy Imp is left alone, unless
    /// `evenIfBusy` (a trigger's `play` step runs right after its `ask` started the work).
    func play(_ ref: AnimationRef, by imp: ImpModel? = nil, evenIfBusy: Bool = false) {
        guard let imp = imp ?? app.focused, evenIfBusy || !imp.isBusy else { return }
        imp.touch()
        imp.life.perform(ref)
        // On another device: it acts it out.
        if app.isAway(imp.id) { app.link.animate(imp.id, beats: Antics.beats(for: ref, prefs: app.prefs, imp: imp.id) ?? []) }
    }
}
