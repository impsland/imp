import AppKit
import SwiftUI

// The one place the bubble reaches for the system's behind-window blur (SwiftUI materials only blur the
// window's own content). Everything else about the bubble's fill is in BubbleChrome.swift.

/// The blur under a translucent bubble: the system's own, of whatever is behind the bubble's window
/// (SwiftUI's materials only blur the window's own content). It is masked to the shape, so a pebble of
/// the trail gets its own round one and nothing square shows at a corner.
struct BubbleBlur: NSViewRepresentable {
    let cornerRadius: CGFloat

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .popover
        view.blendingMode = .behindWindow
        view.state = .active
        view.maskImage = Self.mask(cornerRadius)
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.maskImage = Self.mask(cornerRadius)
    }

    /// A stretchable rounded rectangle: the corners keep their radius at any size.
    static func mask(_ radius: CGFloat) -> NSImage {
        let side = radius * 2 + 1
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            NSColor.labelColor.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}
