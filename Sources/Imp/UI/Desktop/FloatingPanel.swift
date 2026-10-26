import AppKit

/// Borderless, non-activating floating panel: clicking it never steals focus from the
/// app you're working in (so your selection stays put).
final class FloatingPanel: NSPanel {
    var allowsKey = false
    init(size: CGSize) {
        super.init(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = Self.impLevel
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        isMovable = false
        animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    }
    /// Above ordinary floating panels (so Imp and its bubble are never buried), below menus.
    static let impLevel = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 2)

    override var canBecomeKey: Bool { allowsKey }
    override var canBecomeMain: Bool { false }
}
