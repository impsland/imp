import ImpKit
import Observation
import SwiftUI

/// How hard the Imps may work right now: it drops in Low Power Mode and when the phone runs hot.
@MainActor @Observable
final class Energy {
    static let shared = Energy()

    private(set) var budget = Energy.read()

    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    private init() {
        let center = NotificationCenter.default
        for name in [Notification.Name.NSProcessInfoPowerStateDidChange, ProcessInfo.thermalStateDidChangeNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { Energy.shared.budget = Energy.read() }
            })
        }
    }

    private static func read() -> FramePolicy.Budget {
        FramePolicy.budget(lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled, thermal: ProcessInfo.processInfo.thermalState)
    }

    /// A timeline schedule at the pace the moment needs: the display's own rate while `lively`,
    /// calmer otherwise, and none at all while `paused`. `fastest` caps the rate for what looks
    /// the same at 60 fps as at 120.
    func schedule(lively: Bool, paused: Bool = false, fastest: TimeInterval = 0) -> AnimationTimelineSchedule {
        let interval = max(fastest, FramePolicy.interval(lively: lively, budget: budget) ?? 0)
        return .animation(minimumInterval: interval > 0 ? interval : nil, paused: paused)
    }
}
