import AppKit
import SwiftUI

/// Hosts a SwiftUI row inside an `NSMenu`. Menus only draw their own arrow over standard items,
/// and Imp is never the active app while its menus are open, so its cursor rects don't apply:
/// over a custom row the cursor would follow the app behind the menu (an I-beam, a hand…).
/// This row claims the arrow itself whenever the mouse is over it.
final class MenuRowHost<Content: View>: NSHostingView<Content> {
    private var arrowArea: NSTrackingArea?

    /// A menu is not a window with a title bar or a safe area: without this the hosting view reserves
    /// the top inset of the menu's window above the row, a band that makes the padding uneven.
    required init(rootView: Content) {
        super.init(rootView: rootView)
        safeAreaRegions = []
    }

    @MainActor @preconcurrency required dynamic init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// The row is as tall as its content needs at whatever width the menu gives it, so a wider menu never clips
    /// or stretches the padding.
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(NSSize(width: newSize.width, height: fittingSize.height))
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        // Only our own area: SwiftUI's hover tracking keeps its areas.
        if let arrowArea { removeTrackingArea(arrowArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .cursorUpdate,
                                                         .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        arrowArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        NSCursor.arrow.set()
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        NSCursor.arrow.set()
    }

    override func cursorUpdate(with event: NSEvent) { NSCursor.arrow.set() }
}
