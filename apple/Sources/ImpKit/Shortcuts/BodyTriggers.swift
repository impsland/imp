import Foundation

/// The Imp's own body behaviors (falling asleep when left alone, waking when the cursor comes
/// close) are triggers like any other, made by the user or by the Imp on request (there are none
/// by default). Triggers whose steps are not `ask` run on the Imp itself, without a brain.
extension ImpPreferences {
    /// The triggers of `imp` (or of every Imp) that `event` sets off, for the Imp's body: the
    /// enabled ones whose event matches and whose conditions hold. Nothing here needs a brain.
    public func bodyShortcuts(of imp: UUID, on event: MacEvent, in state: MacState) -> [Shortcut] {
        triggers(for: imp).filter { $0.trigger.event.isBodily && $0.fires(on: event, in: state) }
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
    /// When the cursor came near, and how long of its rest was already reported (see `update(distance:now:)`).
    var arrived = 0.0
    var reported = 0.0

    public init(radius: Double = 80, margin: Double = 12) { self.radius = radius; self.margin = margin }

    /// `distance` from the Imp's centre to the cursor. Returns the event if the cursor crossed.
    public mutating func update(distance: Double) -> MacEvent? {
        if !isNear, distance < radius { isNear = true; return .near(from: -1, to: 0) }
        if isNear, distance > radius + margin { isNear = false; return .away }
        return nil
    }
}

/// What a change to the triggers does to how an Imp follows the cursor.
public enum FollowChange: Equatable, Sendable {
    /// A follow trigger that goes off when it is made or switched on (`start` ones): it applies at once.
    case apply(Shortcut)
    /// The last enabled follow trigger went (removed or switched off): back to the base mode.
    case reset
}

extension ImpPreferences {
    /// How an Imp follows the cursor when no follow trigger has set it: the face looks at the cursor, the body stays.
    public static let baseFollow: (mode: FollowMode, speed: Double) = (.eyes, FollowMath.defaultSpeed)

    /// The enabled triggers of `imp` that set how it follows the cursor.
    public func followTriggers(for imp: UUID) -> [Shortcut] {
        triggers(for: imp).filter { $0.isEnabled && $0.followSetting != nil }
    }

    /// What changing the triggers from `old` to these does for `imp`'s following, if anything.
    public func followChange(from old: ImpPreferences, for imp: UUID) -> FollowChange? {
        let before = old.followTriggers(for: imp), now = followTriggers(for: imp)
        if !before.isEmpty, now.isEmpty { return .reset }
        let new = now.filter { $0.trigger.event == .start && !before.contains($0) }
        return new.last.map(FollowChange.apply)
    }
}
