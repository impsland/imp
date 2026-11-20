import SwiftUI

#if os(macOS)
import AppKit

public extension View {
    /// Shows `cursor` over this view, and the standard arrow again as soon as the pointer leaves it or the view goes away.
    /// The system owns the cursor rect, so it is reset by itself: nothing is pushed that has to be popped, and a view
    /// removed while the pointer is over it cannot leave its cursor behind (which `NSCursor.push()` from a hover does).
    /// For the cursors SwiftUI has (`.link`, resize, grab) use `pointerStyle(_:)`. This is for the ones it doesn't.
    func cursor(_ cursor: NSCursor) -> some View {
        overlay(CursorArea(cursor: cursor))
    }
}

/// An invisible view whose only job is one cursor rect over its bounds. It takes no clicks.
private struct CursorArea: NSViewRepresentable {
    let cursor: NSCursor

    func makeNSView(context: Context) -> CursorView { CursorView(cursor: cursor) }

    func updateNSView(_ view: CursorView, context: Context) {
        guard view.cursor !== cursor else { return }
        view.cursor = cursor
        view.window?.invalidateCursorRects(for: view)
    }

    final class CursorView: NSView {
        var cursor: NSCursor

        init(cursor: NSCursor) {
            self.cursor = cursor
            super.init(frame: .zero)
        }

        @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func resetCursorRects() { addCursorRect(bounds, cursor: cursor) }
    }
}
#endif
