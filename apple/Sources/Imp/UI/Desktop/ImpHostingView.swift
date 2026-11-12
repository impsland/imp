import AppKit
import ImpKit
import SwiftUI

/// Hosting view that turns mouse input into Imp interactions: click = talk/poke, press and
/// hold = cuddle, drag = carry (and shake), right-click = menu.
final class ImpHostingView: NSHostingView<ImpView> {
    /// How the Imp is being handled, besides clicks.
    enum Handling {
        /// The button went down on it (a click, a hold or a drag may follow).
        case pressed
        /// Held down without moving for `PressGestures.holdAfter`.
        case held
        /// Let go after a hold.
        case unheld
        /// A drag started.
        case lifted
        /// Carried along, moving this fast sideways (points a second).
        case carried(speed: CGFloat)
        /// Shaken back and forth while carried.
        case shaken
        /// Put down, this far from where it was picked up.
        case dropped(distance: CGFloat)
    }

    /// A click (not a drag): whether ⌥ was held, and when (seconds since boot, like `NSEvent.timestamp`).
    var onClick: ((_ alternate: Bool, _ time: TimeInterval) -> Void)?
    var onHandling: ((Handling) -> Void)?
    var menuProvider: (() -> NSMenu)?
    /// The cursor moved over Imp (global monitors don't see moves over our own window).
    var onMouseMoved: (() -> Void)?
    /// A picture is dragged over Imp (true) or away again (false).
    var onPictureHover: ((Bool) -> Void)?
    /// A picture was dropped on Imp: its pasteboard. Returns whether it was taken.
    var onDropPicture: ((NSPasteboard) -> Bool)?
    /// While carried: the pointer and how fast it's going (points a second, y up). Returns true when
    /// that's a throw off the desktop and it has been dealt with: the carry ends there.
    var onFling: ((_ cursor: CGPoint, _ velocity: CGVector) -> Bool)?
    private var dragStart: CGPoint?
    private var windowStart: CGPoint?
    private var dragged = false
    /// Moved far enough to be carried, not just a click with a wobbly hand.
    private var lifted = false
    private var held = false
    private var pressedAt: TimeInterval = 0
    private var holdTimer: Timer?
    private var press = PressGestures()
    private var lastDrag: (x: CGFloat, t: TimeInterval)?
    private var speed: CGFloat = 0
    /// How fast the hand moves, from the mouse's own movement: it keeps counting when the pointer
    /// is stopped by the edge of the screen (that push is what makes a throw).
    private var push = CGVector.zero
    private var lastPush: TimeInterval?
    /// Thrown off the desktop: the rest of this press is ignored.
    private var thrown = false

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.filter { $0.owner === self }.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect],
                                       owner: self))
    }

    override func mouseMoved(with event: NSEvent) { onMouseMoved?() }

    // MARK: Dropping a picture on Imp

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard onDropPicture != nil, Pasteboard.hasPicture(sender.draggingPasteboard) else { return [] }
        onPictureHover?(true)
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        onDropPicture != nil && Pasteboard.hasPicture(sender.draggingPasteboard) ? .copy : []
    }

    override func draggingExited(_ sender: NSDraggingInfo?) { onPictureHover?(false) }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { true }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        onDropPicture?(sender.draggingPasteboard) ?? false
    }

    /// The resting breath as a Core Animation loop, so a resting Imp costs (almost) no CPU.
    /// Same curve and phase as `Motion.breath`, so switching to drawn frames is seamless.
    private(set) var isBreathing = false
    /// The Imp's body clock (see `BodyClock`), so the breath keeps its own rhythm.
    var clock = BodyClock.shared

    func setBreathing(_ on: Bool) {
        isBreathing = on
        wantsLayer = true
        guard let layer else { return }
        layer.removeAnimation(forKey: "breath")
        guard on else { return }
        let side = bounds.height, unit = side / 100
        // Squash pivots on the base of the head (84% down the canvas, see ImpRenderer.size).
        let pivot = (0.5 - ImpRenderer.size.bottom / 100) * side          // from the centre, y-up
        let period = 2 * Double.pi / Motion.breathRate, frames = 48
        let anim = CAKeyframeAnimation(keyPath: "transform")
        anim.values = (0...frames).map { i in
            let t = Double(i) / Double(frames) * period
            let (bob, squash) = Motion.breath(at: t)
            var m = CATransform3DMakeTranslation(0, pivot - bob * unit, 0)    // y-up: positive bob moves down
            m = CATransform3DScale(m, 1 + squash, 1 - squash, 1)
            return NSValue(caTransform3D: CATransform3DTranslate(m, 0, -pivot, 0))
        }
        anim.duration = period
        anim.repeatCount = .infinity
        anim.calculationMode = .cubic
        // Phase-align with the drawn breath, which runs on this Imp's own body clock.
        let phase = clock.time(Date()).truncatingRemainder(dividingBy: period)
        anim.beginTime = layer.convertTime(CACurrentMediaTime(), from: nil) - phase
        anim.isRemovedOnCompletion = false
        layer.add(anim, forKey: "breath")
    }

    override func mouseDown(with event: NSEvent) {
        dragStart = NSEvent.mouseLocation
        windowStart = window?.frame.origin
        pressedAt = event.timestamp
        dragged = false
        lifted = false
        held = false
        press = PressGestures()
        lastDrag = nil
        speed = 0
        push = .zero
        lastPush = nil
        thrown = false
        onHandling?(.pressed)
        holdTimer?.invalidate()
        holdTimer = Timer.scheduledTimer(withTimeInterval: PressGestures.holdAfter, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.dragged else { return }
                self.held = true
                self.onHandling?(.held)
            }
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = dragStart, let origin = windowStart, let window else { return }
        let now = NSEvent.mouseLocation
        let dx = now.x - start.x, dy = now.y - start.y
        if !dragged && hypot(dx, dy) < Self.dragThreshold { return }
        dragged = true
        holdTimer?.invalidate()
        window.setFrameOrigin(CGPoint(x: origin.x + dx, y: origin.y + dy))
        if !lifted && hypot(dx, dy) >= Self.wobble {
            lifted = true
            if held { held = false; onHandling?(.unheld) }
            onHandling?(.lifted)
        }
        guard lifted else { return }
        if let last = lastDrag, event.timestamp > last.t {
            let v = (now.x - last.x) / (event.timestamp - last.t)
            speed = speed * 0.7 + v * 0.3                      // smoothed: mice report in bursts
        }
        lastDrag = (now.x, event.timestamp)
        if let last = lastPush, event.timestamp > last {
            let dt = max(event.timestamp - last, 1.0 / 240)
            // deltaY grows downward; Cocoa's y grows up.
            let v = CGVector(dx: event.deltaX / dt, dy: -event.deltaY / dt)
            push = CGVector(dx: push.dx * 0.55 + v.dx * 0.45, dy: push.dy * 0.55 + v.dy * 0.45)
        }
        lastPush = event.timestamp
        if let onFling, onFling(now, push) {
            thrown = true
            dragStart = nil
            return
        }
        onHandling?(.carried(speed: speed))
        if press.drag(to: now, at: event.timestamp) { onHandling?(.shaken) }
    }

    override func mouseUp(with event: NSEvent) {
        defer { dragStart = nil }
        holdTimer?.invalidate()
        if thrown { thrown = false; return }
        let moved = dragStart.map { hypot(NSEvent.mouseLocation.x - $0.x, NSEvent.mouseLocation.y - $0.y) } ?? 0
        // A quick, short press is a click even if the hand wobbled (clicks and trackpad taps often
        // move a few points). Undo the nudge. Only a real move is a drag.
        if dragged && (lifted || event.timestamp - pressedAt > Self.clickTime) {
            onHandling?(.dropped(distance: moved))
            return
        }
        if dragged, let origin = windowStart { window?.setFrameOrigin(origin) }
        if held {                                       // a cuddle, not a click
            onHandling?(.unheld)
            return
        }
        onClick?(event.modifierFlags.contains(.option), event.timestamp)
    }

    /// Movement before a press starts dragging Imp.
    static let dragThreshold: CGFloat = 6
    /// A press that moved less than this (and was released within `clickTime`) is still a click.
    static let wobble: CGFloat = 10
    static let clickTime: TimeInterval = 0.35

    override func rightMouseDown(with event: NSEvent) {
        guard let menu = menuProvider?() else { return }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }
}
