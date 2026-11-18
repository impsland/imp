import Foundation

extension ImpPreferences {
    /// Whether the cursor needs watching at all: Mouse games is on and some switched-on trigger is
    /// set off by watching the pointer from afar (stroke, circle, near…). Nothing else needs the
    /// global mouse monitor.
    public var watchesCursor: Bool {
        mouseGames && shortcuts.contains { $0.isEnabled && $0.trigger.event.watchesCursor }
    }
}
