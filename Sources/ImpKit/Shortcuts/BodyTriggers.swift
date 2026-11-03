import Foundation

/// The Imp's own body behaviors (falling asleep when left alone, waking when the cursor comes
/// close) are triggers like any other. They run on the Imp itself, without a brain, from the same
/// list the user edits in Settings.
extension Shortcut {
    /// Stable identities for the triggers every install starts with.
    public static let sleepID = UUID(uuidString: "B0D10000-0000-4000-8000-000000000001")!
    public static let wakeID = UUID(uuidString: "B0D10000-0000-4000-8000-000000000002")!

    /// The triggers every install starts with: left alone for a while, the Imp dozes off, and the
    /// cursor coming close wakes it. Users can switch them off, change the times and animations, or delete them.
    public static var bodyDefaults: [Shortcut] {
        var sleep = Shortcut(name: String(localized: "Fall asleep"), prompt: "", usesClipboard: false,
                             trigger: Trigger(.idle, number: Trigger.defaultIdleSeconds), command: .sleep, animation: .preset(.yawn))
        sleep.id = sleepID
        var wake = Shortcut(name: String(localized: "Wake up"), prompt: "", usesClipboard: false,
                            trigger: Trigger(.enter), command: .wakeUp)
        wake.id = wakeID
        return [sleep, wake]
    }

    /// Whether it acts on the Imp's body alone, so it can run without a brain.
    public var runsLocally: Bool { command.isLocal }
}

extension ImpPreferences {
    /// Adds the default body triggers that were never added (matched by id, so one the user
    /// deleted stays deleted and a default added by a later version appears for existing users).
    mutating func addBodyDefaults() {
        var added = Set(addedDefaults ?? [])
        for d in Shortcut.bodyDefaults where !added.contains(d.id) {
            added.insert(d.id)
            if !shortcuts.contains(where: { $0.id == d.id }) { shortcuts.append(d) }
        }
        addedDefaults = added.sorted { $0.uuidString < $1.uuidString }
    }

    /// The triggers of `imp` (or of every Imp) that `event` sets off, for the Imp's body: the
    /// enabled ones whose event matches and whose conditions hold. Nothing here needs a brain.
    public func bodyShortcuts(of imp: UUID, on event: MacEvent, in state: MacState) -> [Shortcut] {
        shortcuts.filter { ($0.performer == imp || $0.performer == nil) && $0.trigger.kind.isBodily && $0.fires(on: event, in: state) }
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
