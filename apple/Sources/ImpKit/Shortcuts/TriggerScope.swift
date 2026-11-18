import Foundation

/// Which triggers each Imp has, and how a change made in one Imp's settings is kept (see `SettingScope`).
extension ImpPreferences {
    /// An Imp's own triggers (its versions of shared ones included), in priority order.
    public func shortcuts(of imp: UUID) -> [Shortcut] { shortcuts.filter { $0.performer == imp } }

    /// Shortcuts every Imp answers to (no performer of their own).
    public var sharedShortcuts: [Shortcut] { shortcuts.filter { $0.performer == nil } }

    /// The triggers in effect for `imp`: its own first, then the shared ones it has no version of.
    public func triggers(for imp: UUID) -> [Shortcut] {
        let own = shortcuts(of: imp)
        let replaced = Set(own.compactMap(\.overrides))
        return own + sharedShortcuts.filter { !replaced.contains($0.id) }
    }

    /// How `shortcut` applies to `imp`.
    public func scope(of shortcut: Shortcut, for imp: UUID) -> SettingScope {
        if shortcut.performer == nil { return .everyImp }
        return shortcut.overrides.map { id in sharedShortcuts.contains { $0.id == id } } == true ? .changed : .onlyThisImp
    }

    /// Whether `shortcut` runs on `imp`: its own, or a shared one `imp` has no version of.
    public func runs(_ shortcut: Shortcut, on imp: UUID) -> Bool {
        if let performer = shortcut.performer { return performer == imp }
        return !shortcuts.contains { $0.performer == imp && $0.overrides == shortcut.id }
    }

    /// The Imp that performs an action: its own performer if it's activated, else `fallback`.
    public func performer(of action: Shortcut, fallback: UUID) -> UUID {
        action.performer.flatMap { id in imps.contains { $0.id == id && $0.isActive } ? id : nil } ?? fallback
    }

    /// Shortcuts that should listen right now: switched on, and their Imp is out on the desktop.
    public var liveShortcuts: [Shortcut] {
        let active = Set(imps.filter(\.isActive).map(\.id))
        return shortcuts.filter { a in a.isEnabled && (a.performer.map(active.contains) ?? !active.isEmpty) }
    }

    /// The live trigger `keys` set off and the Imp that runs it: the first in the list whose Imp has
    /// no version of its own of it. `focus` is the Imp a shared trigger goes to.
    public func keyed(_ keys: Hotkey, focus: UUID) -> (shortcut: Shortcut, imp: UUID)? {
        for s in liveShortcuts where s.keys == keys {
            let imp = performer(of: s, fallback: focus)
            if runs(s, on: imp) { return (s, imp) }
        }
        return nil
    }

    /// What `count` clicks on `imp` set off: its own trigger first, else one every Imp shares.
    /// `state` decides the conditions (nil: ignore triggers that have any).
    public func clickShortcut(_ count: Int, on imp: UUID, in state: MacState?) -> Shortcut? {
        triggers(for: imp).first { s in
            s.isEnabled && s.trigger.event == .click && s.trigger.clicks == count
                && (state.map { st in s.conditions.allSatisfy { $0.holds(in: st) } } ?? s.conditions.isEmpty)
        }
    }

    /// The most clicks in a row anything on `imp` answers to (a click waits for more only if needed).
    public func mostClicks(on imp: UUID) -> Int {
        triggers(for: imp).filter { $0.isEnabled && $0.trigger.event == .click }.map(\.trigger.clicks).max() ?? 0
    }

    /// Whether a first click on `imp` waits to see if more follow: only when a trigger answers to two or more.
    public func waitsForMoreClicks(on imp: UUID) -> Bool { mostClicks(on: imp) >= 2 }

    // MARK: Changes

    /// Keeps a trigger that was edited or added, for `target`.
    ///
    /// - For every Imp: a shared one changes in place. An Imp's version of a shared one is written into
    ///   the shared one and goes (the other Imps' versions stay). An Imp's own one becomes shared.
    /// - For one Imp: its own one changes in place. A shared one gets a version for that Imp alone (a new
    ///   trigger that `overrides` it), and the shared one is not touched. Another Imp's trigger is copied,
    ///   never taken.
    /// Returns the id the trigger is kept under.
    @discardableResult
    public mutating func saveTrigger(_ edited: Shortcut, for target: ScopeTarget) -> UUID {
        let original = shortcuts.first { $0.id == edited.id }
        var s = edited
        switch target {
        case .everyImp:
            if let shared = original?.overrides, sharedShortcuts.contains(where: { $0.id == shared }) {
                shortcuts.removeAll { $0.id == edited.id }
                s.id = shared
            }
            s.performer = nil
            s.overrides = nil
        case .imp(let id):
            s.performer = id
            if let original, original.performer == nil {
                // A shared one: this Imp's version of it, new or the one it already has.
                s.overrides = original.id
                s.id = shortcuts.first { $0.performer == id && $0.overrides == original.id }?.id ?? UUID()
            } else if let original, original.performer != id {
                s.id = UUID()
                s.overrides = nil
            } else if let original {
                s.overrides = original.overrides        // its own version stays a version of the shared one
            }
        }
        if let i = shortcuts.firstIndex(where: { $0.id == s.id }) { shortcuts[i] = s } else { shortcuts.append(s) }
        return s.id
    }

    /// Switches a trigger on or off for `imp`. A shared one is switched for `imp` alone (through its own version).
    public mutating func setTrigger(_ id: UUID, enabled on: Bool, for imp: UUID) {
        guard var s = shortcuts.first(where: { $0.id == id }) else { return }
        s.isEnabled = on
        saveTrigger(s, for: .imp(imp))
    }

    /// Removes `imp`'s own trigger, or its version of a shared one (the shared one applies to it again).
    /// A shared trigger is never touched from here: see `removeSharedTrigger(_:)`.
    public mutating func removeTrigger(_ id: UUID, for imp: UUID) {
        shortcuts.removeAll { $0.id == id && $0.performer == imp }
    }

    /// Removes a shared trigger for every Imp. The Imps' own versions of it stay theirs.
    public mutating func removeSharedTrigger(_ id: UUID) {
        guard shortcuts.contains(where: { $0.id == id && $0.performer == nil }) else { return }
        shortcuts.removeAll { $0.id == id }
        for i in shortcuts.indices where shortcuts[i].overrides == id { shortcuts[i].overrides = nil }
    }
}
