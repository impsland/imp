import Foundation

/// When a trigger that went off may actually run (the contract is `docs/sharing/kits.md#triggers`).
extension Shortcut {
    /// Seconds a trigger that asks the model rests after going off on its own.
    public static let rest: TimeInterval = 60

    /// It asks the model and something other than the person sets it off (not keys, a click, a
    /// pointer gesture, the cursor near or away): it then rests for `rest` seconds, so the model is
    /// not flooded. Triggers without an `ask` step never rest.
    public var restsAfterGoingOff: Bool { askStep != nil && trigger.event.isAmbient }

    /// Talks to the person or opens something: when the Mac sets it off it waits for a free Imp.
    public var needsFreeImp: Bool { steps.contains { [.ask, .say, .open].contains($0.act) } }

    /// Whether it may run now. `lastFired`: when it last ran (only a resting trigger is held back).
    /// `isFree`: the Imp is not working and the person is not typing or talking to it.
    public func mayRun(lastFired: Date?, isFree: Bool, now: Date = Date()) -> Bool {
        if trigger.event.isAmbient, needsFreeImp, !isFree { return false }
        if restsAfterGoingOff, let lastFired, now.timeIntervalSince(lastFired) < Self.rest { return false }
        return true
    }
}

extension CursorProximity {
    /// Like `update(distance:)`, and while the cursor stays near it keeps reporting how long it has
    /// rested (`.near(from:to:)`, seconds), so a `near` trigger set to N seconds goes off once, as the
    /// time passes N. `now` is any steadily increasing clock, in seconds.
    public mutating func update(distance: Double, now: Double) -> MacEvent? {
        if let event = update(distance: distance) {
            if case .near = event { arrived = now; reported = 0 }
            return event
        }
        guard isNear else { return nil }
        let rested = now - arrived
        defer { reported = rested }
        return rested > reported ? .near(from: reported, to: rested) : nil
    }
}
