import Foundation

/// How often the Imps are drawn. Heat comes from frames, so they get as many as the moment needs:
/// the display's own rate while something moves fast, a calm rate while the Imps only breathe, blink
/// and float, and fewer of both when the device is saving power or running hot.
public enum FramePolicy {
    /// How much the device lets the Imps spend.
    public enum Budget: Int, Comparable, Sendable {
        case full, saving, critical

        public static func < (a: Budget, b: Budget) -> Bool { a.rawValue < b.rawValue }
    }

    /// Low Power Mode and a serious heat state save; a critical heat state saves hard.
    public static func budget(lowPower: Bool, thermal: ProcessInfo.ThermalState) -> Budget {
        switch thermal {
        case .critical: .critical
        case .serious: .saving
        default: lowPower ? .saving : .full
        }
    }

    /// Seconds between frames, or nil for the display's own rate.
    public static func interval(lively: Bool, budget: Budget) -> TimeInterval? {
        switch (lively, budget) {
        case (true, .full): nil
        case (true, .saving): 1 / 60
        case (true, .critical): 1 / 30
        case (false, .full): 1 / 30
        case (false, .saving): 1 / 20
        case (false, .critical): 1 / 12
        }
    }

    /// How long the pace stays lively after the last movement, so springs and blends that are still
    /// settling (a head turning back, a mood fading) are drawn smoothly to their end.
    public static let settle: TimeInterval = 0.8
}

/// Remembers when something last moved, so the frame rate falls back to calm only after the Imps
/// have settled, not in the middle of a flick.
public struct LivelyHold: Sendable {
    private var until = Date.distantPast

    public init() {}

    /// Whether the pace is lively at `date`, given whether something moves right now.
    public mutating func lively(moving: Bool, at date: Date) -> Bool {
        if moving { until = date.addingTimeInterval(FramePolicy.settle) }
        return date < until
    }

    /// Keeps the pace lively until `date` at least (a mood changed, a bubble came up).
    public mutating func extend(to date: Date) { until = max(until, date) }
}
