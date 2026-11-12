import AppKit
import SwiftUI

/// Stops a window from putting the cursor in its first text field when it opens: AppKit does that by itself,
/// and a form should wait until the user chooses a field. Typing in a field still works as usual.
private struct NoInitialFocus: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { Probe() }
    func updateNSView(_ view: NSView, context: Context) {}

    private final class Probe: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            // After AppKit has chosen its first responder, and once more after the first layout.
            for delay in [0.0, 0.15] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak window] in
                    guard let window, window.firstResponder is NSText else { return }
                    window.makeFirstResponder(nil)
                }
            }
        }
    }
}

extension View {
    /// Nothing is focused when this view's window first appears.
    func noInitialFocus() -> some View { background(NoInitialFocus().frame(width: 0, height: 0)) }
}
