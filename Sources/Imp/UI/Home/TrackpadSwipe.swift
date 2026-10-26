import AppKit
import ImpKit
import SwiftUI

extension View {
    /// Two-finger sideways swipes over this view (trackpad, or a sideways mouse wheel). See `SwipeTracker`.
    func onTrackpadSwipe(_ handle: @escaping (SwipeTracker.Output) -> Void) -> some View {
        background(TrackpadSwipe(handle: handle))
    }
}

/// Watches scroll events over its area of the window. It never takes them away from anyone (it's
/// a monitor, not a responder) and never catches clicks.
private struct TrackpadSwipe: NSViewRepresentable {
    let handle: (SwipeTracker.Output) -> Void

    func makeNSView(context: Context) -> Catcher {
        let v = Catcher()
        v.handle = handle
        return v
    }

    func updateNSView(_ view: Catcher, context: Context) { view.handle = handle }

    static func dismantleNSView(_ view: Catcher, coordinator: ()) { view.stop() }

    final class Catcher: NSView {
        var handle: ((SwipeTracker.Output) -> Void)?
        private var tracker = SwipeTracker()
        private var monitor: Any?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stop()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                MainActor.assumeIsolated { self?.scrolled(event) }
                return event
            }
        }

        func stop() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        private func scrolled(_ event: NSEvent) {
            guard event.window === window, event.momentumPhase.isEmpty else { return }
            let inside = bounds.contains(convert(event.locationInWindow, from: nil))
            let output: SwipeTracker.Output?
            if event.hasPreciseScrollingDeltas {
                let phase: SwipeTracker.Phase? = switch event.phase {
                case .began: inside ? .began : nil         // only swipes that start over the stage
                case .changed: .changed
                case .ended: .ended
                case .cancelled: .cancelled
                default: nil
                }
                guard let phase else { return }
                output = tracker.scroll(phase, dx: event.scrollingDeltaX, dy: event.scrollingDeltaY)
            } else {
                guard inside, abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) else { return }
                output = tracker.wheel(dx: event.scrollingDeltaX, at: event.timestamp)
            }
            if let output { handle?(output) }
        }
    }
}
