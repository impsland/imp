import Foundation

/// How often the Imps are drawn, and how often the phone's sensors are read. Heat comes from frames
/// and samples, so every loop asks this one policy what the moment needs, and nothing else decides:
///
/// 1. Nothing that is not on screen runs: not while the app is in the background, not while a sheet
///    covers it, not on another tab.
/// 2. A picture that does not change costs no frames at all (`Activity.still`).
/// 3. Anything that visibly moves (a head turning, eyes following a finger, the cursor or the tilt, a
///    hop, a mood fading) is drawn at the display's rate, 60 fps (`lively`). The Imps that only
///    breathe, blink and float are drawn at 30 (`calm`): that is still smooth, and it is the stillness
///    (no frames at all), not a low frame rate, that saves the energy. 120 Hz is not used: the motion
///    here is slow and soft, and a second 60 frames a second would double the cost for no visible gain.
/// 4. Low Power Mode and a warm device are the platform saying what it can sustain: the rates fall
///    (60 to 30, 30 to 20) but stay smooth. A serious or critical heat state also switches the
///    decorations off (`Conditions.decorated`).
/// 5. Reduce Motion stops what only decorates (the breathing, the floating); what a finger drives
///    still answers the finger.
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

    /// What a picture is doing, which is what it costs.
    public enum Activity: Int, Comparable, Sendable {
        /// Nothing changes: asleep, empty, or waiting for an event. No frames.
        case still
        /// Breathing, blinking, floating.
        case calm
        /// Something moves: a finger, the cursor or the tilt, a toss, a game, a mood fading.
        case lively

        public static func < (a: Activity, b: Activity) -> Bool { a.rawValue < b.rawValue }
    }

    /// Everything outside the picture that decides how often it is drawn.
    public struct Conditions: Equatable, Sendable {
        /// The app's scene is active (in front, not in the background or switching).
        public var active: Bool
        /// The picture itself is on screen (not under a sheet, not on another tab).
        public var visible: Bool
        public var lowPower: Bool
        public var thermal: ProcessInfo.ThermalState
        public var reduceMotion: Bool

        public init(active: Bool = true, visible: Bool = true, lowPower: Bool = false,
                    thermal: ProcessInfo.ThermalState = .nominal, reduceMotion: Bool = false) {
            self.active = active
            self.visible = visible
            self.lowPower = lowPower
            self.thermal = thermal
            self.reduceMotion = reduceMotion
        }

        public var budget: Budget { FramePolicy.budget(lowPower: lowPower, thermal: thermal) }

        /// Whether anything may run at all.
        public var running: Bool { active && visible }

        /// Whether decorations (glows, blurs, drifting colour, particles) may be drawn. They go when the
        /// device is saving power or running warm, and under Reduce Motion.
        public var decorated: Bool { running && budget == .full && !reduceMotion }
    }

    /// How a timeline should run.
    public enum Pace: Equatable, Sendable {
        /// No frames: the last one stays.
        case paused
        /// At most one frame every this many seconds.
        case every(TimeInterval)

        public var interval: TimeInterval? {
            if case .every(let seconds) = self { seconds } else { nil }
        }
    }

    /// Frames per second for each activity and budget. These are design numbers shared with the other
    /// platforms (`behavior` in `design/tokens.json`, checked against these by `FramePolicyTests`).
    public static let framesPerSecond = 60.0
    public static let framesPerSecondSaving = 30.0
    public static let calmFramesPerSecond = 30.0
    public static let calmFramesPerSecondSaving = 20.0

    public static let calmInterval: [Budget: TimeInterval] = [.full: 1 / calmFramesPerSecond, .saving: 1 / calmFramesPerSecondSaving]
    public static let livelyInterval: [Budget: TimeInterval] = [
        .full: 1 / framesPerSecond, .saving: 1 / framesPerSecondSaving, .critical: 1 / framesPerSecondSaving,
    ]

    /// The pace for a picture doing `activity` under `conditions`.
    public static func pace(_ activity: Activity, _ conditions: Conditions) -> Pace {
        guard conditions.running else { return .paused }
        let budget = conditions.budget
        switch activity {
        case .still:
            return .paused
        case .calm:
            // A hot device and Reduce Motion keep the Imps still instead of breathing.
            guard !conditions.reduceMotion, let seconds = calmInterval[budget] else { return .paused }
            return .every(seconds)
        case .lively:
            return .every(livelyInterval[budget] ?? 1 / framesPerSecondSaving)
        }
    }

    /// Sensor samples per second. The picture eases towards each sample with a spring on every frame
    /// (`SpringStep`), so the sensor only has to be fast enough not to miss a throw or a shake.
    public static let sensorHz = 30.0
    public static let sensorHzSaving = 20.0

    /// Seconds between motion-sensor samples, or nil when the sensor should be off. A device that
    /// saves power reads fewer. Reading the phone only to make a picture follow it (`decorative`)
    /// stops under Reduce Motion; reading it to tell a shake that sends an Imp does not.
    public static func motionInterval(_ conditions: Conditions, decorative: Bool) -> TimeInterval? {
        guard conditions.running, !(decorative && conditions.reduceMotion) else { return nil }
        switch conditions.budget {
        case .full: return 1 / sensorHz
        case .saving: return 1 / sensorHzSaving
        case .critical: return nil
        }
    }

    /// How long the pace stays lively after the last movement, so springs and blends that are still
    /// settling (a head turning back, a mood fading) are drawn smoothly to their end. The face's
    /// springs need about 0.75 s to come within a hair of their target, a mood blend 0.35 s on top.
    public static let settle: TimeInterval = 1.2
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
