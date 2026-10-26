import Foundation
import Observation

/// Cached answers to "what does macOS currently allow?" for the UI. Some of these checks are
/// slow (Input Monitoring ~8 ms, the login item ~2 ms: they're IPC calls), far too slow to ask
/// in a SwiftUI body that re-renders while the mouse moves. Refreshed every couple of seconds,
/// and only while Settings is open.
@MainActor @Observable
final class SystemStatus {
    static let shared = SystemStatus()

    private(set) var granted: Set<Permission> = []
    private(set) var launchesAtLogin = false

    @ObservationIgnored private var timer: Timer?

    private init() { refresh() }

    func isGranted(_ p: Permission) -> Bool { granted.contains(p) }
    func allGranted(_ ps: [Permission]) -> Bool { ps.allSatisfy(granted.contains) }

    /// Re-reads everything. Assigns only what changed, so views only redraw for real changes.
    func refresh() {
        let g = Set(Permission.allCases.filter(\.isGranted))
        if g != granted { granted = g }
        let login = LoginItem.isEnabled
        if login != launchesAtLogin { launchesAtLogin = login }
    }

    func start() {
        refresh()
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
            MainActor.assumeIsolated { SystemStatus.shared.refresh() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }
}
