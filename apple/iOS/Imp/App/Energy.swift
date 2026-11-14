import ImpDesign
import ImpKit
import Observation
import SwiftUI

/// The one place the phone decides how hard it works. `FramePolicy` (ImpKit, unit tested) holds the
/// rules. This reads the phone's state for them (Low Power Mode, heat) and hands every loop the
/// answer: a timeline schedule (`PacedTimeline`), a sensor interval (`TiltSource`), or whether an Imp
/// at rest moves at all (`RestMotion`).
///
/// A loop never decides for itself. It says what its picture is doing (`FramePolicy.Activity`) and
/// the policy says how often to draw it, or to not draw at all.
@MainActor @Observable
final class Energy {
    static let shared = Energy()

    private(set) var lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
    private(set) var thermal = ProcessInfo.processInfo.thermalState

    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    private init() {
        let center = NotificationCenter.default
        for name in [Notification.Name.NSProcessInfoPowerStateDidChange, ProcessInfo.thermalStateDidChangeNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { Energy.shared.read() }
            })
        }
    }

    private func read() {
        lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        thermal = ProcessInfo.processInfo.thermalState
    }

    /// What the phone allows right now. Views that read it are redrawn when Low Power Mode or the heat changes.
    func conditions(active: Bool, visible: Bool = true, reduceMotion: Bool) -> FramePolicy.Conditions {
        FramePolicy.Conditions(active: active, visible: visible, lowPower: lowPower, thermal: thermal, reduceMotion: reduceMotion)
    }
}

// MARK: - Frames

/// The frames of a picture at a pace: the steady ones are the system's own animation schedule, and
/// an Imp at rest gets frames only while it blinks (`Motion.blinkWait`).
private struct PacedSchedule: TimelineSchedule {
    var pace: FramePolicy.Pace
    /// The Imp whose blinks are drawn at rest. Without one, a picture at rest gets no frames.
    var blinking: BodyClock?

    func entries(from start: Date, mode: TimelineScheduleMode) -> Entries {
        switch (pace, blinking) {
        case (.blinks(let frame), let clock?):
            .blinks(date: start, frame: frame, clock: clock)
        case (.paused, _), (.blinks, nil):
            // Paused keeps the last frame on screen.
            .steady(AnimationTimelineSchedule(paused: true).entries(from: start, mode: mode))
        case (.every(let seconds), _):
            .steady(AnimationTimelineSchedule(minimumInterval: seconds).entries(from: start, mode: mode))
        }
    }

    enum Entries: Sequence, IteratorProtocol {
        case steady(AnimationTimelineSchedule.Entries)
        case blinks(date: Date, frame: TimeInterval, clock: BodyClock)

        mutating func next() -> Date? {
            switch self {
            case .steady(var entries):
                let date = entries.next()
                self = .steady(entries)
                return date
            case .blinks(let date, let frame, let clock):
                let next = date.addingTimeInterval(Motion.blinkWait(at: clock.time(date), frame: frame))
                self = .blinks(date: next, frame: frame, clock: clock)
                return next
            }
        }
    }
}

// MARK: - Where a picture is

private struct CoveredKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// A sheet is over this part of the app, so nothing in it needs drawing.
    var covered: Bool {
        get { self[CoveredKey.self] }
        set { self[CoveredKey.self] = newValue }
    }
}

private struct DecoratedKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    /// Whether decorations (glows, blurs, drifting colour) may be drawn: off in Low Power Mode, when the
    /// phone runs warm and under Reduce Motion.
    var decorated: Bool {
        get { self[DecoratedKey.self] }
        set { self[DecoratedKey.self] = newValue }
    }
}

/// Puts the policy's answer about decorations in the environment, once, at the root.
private struct EnergyScope: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.environment(\.decorated, Energy.shared.conditions(active: true, reduceMotion: reduceMotion).decorated)
    }
}

extension View {
    /// Gives this view and everything in it `\.decorated`.
    func energyScope() -> some View { modifier(EnergyScope()) }
}

private struct PaceKey: EnvironmentKey {
    static let defaultValue = FramePolicy.Pace.paused
}

private struct BreathesKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// How the picture this view is in is drawn right now. Set by its `PacedTimeline`. A view outside
    /// one is a still picture.
    fileprivate(set) var pace: FramePolicy.Pace {
        get { self[PaceKey.self] }
        set { self[PaceKey.self] = newValue }
    }

    /// Whether the Imps in this picture breathe and float (`FramePolicy.breathes`). Set by its `PacedTimeline`.
    fileprivate(set) var breathes: Bool {
        get { self[BreathesKey.self] }
        set { self[BreathesKey.self] = newValue }
    }
}

/// A timeline that draws at the pace `FramePolicy` gives its activity, and not at all while the app
/// is in the background, covered by a sheet or scrolled or switched away.
///
/// A picture at rest gets no frames from it: each Imp in it draws its own blinks (`BlinkTimeline`).
/// Left at rest for `FramePolicy.quiet` seconds, the picture settles.
struct PacedTimeline<Content: View>: View {
    var activity: FramePolicy.Activity
    @ViewBuilder var content: (Date) -> Content
    @State private var onScreen = true
    /// At rest for long enough to settle. Any other activity in between starts the wait again.
    @State private var settled = false
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.covered) private var covered

    var body: some View {
        let conditions = Energy.shared.conditions(active: scenePhase == .active, visible: onScreen && !covered, reduceMotion: reduceMotion)
        let now = settled && activity == .resting ? .settled : activity
        let pace = FramePolicy.pace(now, conditions)
        TimelineView(PacedSchedule(pace: pace)) { timeline in
            content(timeline.date)
        }
        .environment(\.pace, pace)
        .environment(\.breathes, FramePolicy.breathes(now, conditions))
        .onAppear { onScreen = true }
        .onDisappear { onScreen = false }
        .task(id: activity) {
            settled = false
            guard activity == .resting else { return }
            try? await Task.sleep(for: .seconds(FramePolicy.quiet))
            if !Task.isCancelled { settled = true }
        }
    }
}

/// Frames for the blinks of one Imp, while the picture it is in is at rest and gives it none. The
/// content gets the time of the blink frame to draw, or nil while the picture has frames of its own
/// (or is still): then the Imp is drawn at the picture's time.
struct BlinkTimeline<Content: View>: View {
    /// Nil for an Imp that does not blink (it sleeps, or is a still picture).
    var clock: BodyClock?
    @ViewBuilder var content: (Date?) -> Content
    @Environment(\.pace) private var pace

    var body: some View {
        let blinks = if case .blinks = pace, clock != nil { true } else { false }
        TimelineView(PacedSchedule(pace: blinks ? pace : .paused, blinking: clock)) { timeline in
            content(blinks ? timeline.date : nil)
        }
    }
}

// MARK: - An Imp at rest

/// The motion of an Imp at rest: it swings a finished picture between a transform and its opposite,
/// for as long as the policy lets the Imps breathe (`\.breathes`). The picture is not drawn again
/// for it. This is the only animation in the app that repeats by itself (`PhoneEnergyAuditTests`).
private struct RestMotion: ViewModifier {
    /// How far the picture is squashed (wider, lower) at the end of a swing, about `anchor`.
    var squash = 0.0
    var anchor = UnitPoint.center
    /// How far it has sunk at the end of a swing, in points.
    var sink: CGFloat = 0
    /// Seconds for a swing there and back.
    var period: TimeInterval
    var on: Bool
    @State private var swung = false
    @Environment(\.breathes) private var breathes
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        let moving = on && breathes
        let k = swung ? 1.0 : -1.0
        content
            .scaleEffect(x: 1 + squash * k, y: 1 - squash * k, anchor: anchor)
            .offset(y: sink * k)
            .animation(moving ? Animation.easeInOut(duration: period / 2).repeatForever(autoreverses: true)
                              : ImpDesign.Motion.fade.reducedAware(reduceMotion), value: swung)
            .onChange(of: moving, initial: true) { swung = moving }
    }
}

extension View {
    /// The slow breath of the Imp drawn in this view, which is its square (`ImpRenderer`'s box). It is
    /// the breath `Motion.breath` draws on the Mac: the body sinks and widens a little, about its base.
    func breathing(_ clock: BodyClock, on: Bool = true) -> some View {
        let depth = Motion.breathDepth
        // Sinking by `bob` while squashing about the base is one squash about a point below it.
        let pivot = (ImpRenderer.size.bottom + depth.bob / depth.squash) / 100
        return modifier(RestMotion(squash: depth.squash, anchor: UnitPoint(x: 0.5, y: pivot),
                                   period: 2 * .pi / Motion.breathRate * clock.pace, on: on))
    }

    /// The gentle float of an Imp in the room, `reach` points up and down.
    func floating(_ clock: BodyClock, reach: CGFloat, on: Bool = true) -> some View {
        modifier(RestMotion(sink: reach, period: 2 * .pi / 1.5 * clock.pace, on: on))
    }
}

private extension BodyClock {
    /// A little faster or slower than the next Imp (within a tenth), so a room of them never moves in step.
    var pace: Double { 1 + 0.1 * sin(offset) }
}
