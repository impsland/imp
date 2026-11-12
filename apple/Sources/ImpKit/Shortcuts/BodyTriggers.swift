import Foundation

/// The Imp's own body behaviors (falling asleep when left alone, waking when the cursor comes
/// close) are triggers like any other (the starter kit has them). They run on the Imp itself,
/// without a brain, from the same list the user edits in Settings.
extension Shortcut {
    /// Whether it acts on the Imp's body alone, so it can run without a brain.
    public var runsLocally: Bool { command.isLocal }
}

extension ImpPreferences {
    /// The triggers of `imp` (or of every Imp) that `event` sets off, for the Imp's body: the
    /// enabled ones whose event matches and whose conditions hold. Nothing here needs a brain.
    public func bodyShortcuts(of imp: UUID, on event: MacEvent, in state: MacState) -> [Shortcut] {
        triggers(for: imp).filter { $0.trigger.kind.isBodily && $0.fires(on: event, in: state) }
    }
}

/// Watches how long the Imp has been left alone and reports each stretch of time as an event,
/// so a trigger set to N seconds goes off once as the time passes N, and again after the next touch.
public struct IdleWatch: Sendable {
    private var last: Double = 0

    public init() {}

    /// The event for the time since the Imp was last touched, if the clock moved.
    public mutating func advance(to idle: Double) -> MacEvent? {
        defer { last = idle }
        return idle > last ? .idle(from: last, to: idle) : nil
    }
}

/// Tells when the cursor comes up to the Imp and when it moves away (with a margin, so a cursor
/// resting on the edge doesn't flicker between the two).
public struct CursorProximity: Sendable {
    public var radius: Double
    public var margin: Double
    public private(set) var isNear = false

    public init(radius: Double = 80, margin: Double = 12) { self.radius = radius; self.margin = margin }

    /// `distance` from the Imp's centre to the cursor. Returns the event if the cursor crossed.
    public mutating func update(distance: Double) -> MacEvent? {
        if !isNear, distance < radius { isNear = true; return .cursorEnter }
        if isNear, distance > radius + margin { isNear = false; return .cursorLeave }
        return nil
    }
}
