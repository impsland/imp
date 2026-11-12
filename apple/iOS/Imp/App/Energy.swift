import ImpKit
import Observation
import SwiftUI

/// The one place the phone decides how hard it works. `FramePolicy` (ImpKit, unit tested) holds the
/// rules; this reads the phone's state for them (Low Power Mode, heat) and hands every loop the
/// answer: a timeline schedule (`PacedTimeline`) or a sensor interval (`TiltSource`).
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

extension FramePolicy.Pace {
    /// The schedule for a `TimelineView` at this pace. Paused keeps the last frame on screen.
    var schedule: AnimationTimelineSchedule {
        .animation(minimumInterval: interval, paused: self == .paused)
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

/// A timeline that draws at the pace `FramePolicy` gives its activity, and not at all while the app
/// is in the background, covered by a sheet or scrolled or switched away.
struct PacedTimeline<Content: View>: View {
    var activity: FramePolicy.Activity
    @ViewBuilder var content: (Date) -> Content
    @State private var onScreen = true
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.covered) private var covered

    var body: some View {
        let conditions = Energy.shared.conditions(active: scenePhase == .active, visible: onScreen && !covered, reduceMotion: reduceMotion)
        TimelineView(FramePolicy.pace(activity, conditions).schedule) { timeline in
            content(timeline.date)
        }
        .onAppear { onScreen = true }
        .onDisappear { onScreen = false }
    }
}
