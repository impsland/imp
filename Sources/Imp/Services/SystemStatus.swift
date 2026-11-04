import Foundation
import Observation

/// Cached answers to "what does macOS currently allow?" for the UI. Every check is a call to
/// another process (on macOS 26 about 17 ms each for the microphone, speech and screen recording,
/// and 4 ms for the login item), far too slow to ask in a SwiftUI body. Refreshed every couple of
/// seconds while the Home window is open, and read off the main thread: read there, the checks
/// stopped every animation (the home screen's embers, an Imp being dragged) for about 60 ms each
/// time.
@MainActor @Observable
final class SystemStatus {
    static let shared = SystemStatus()

    private(set) var granted: Set<Permission> = []
    private(set) var launchesAtLogin = false

    @ObservationIgnored private var timer: Timer?
    /// The read in progress: a refresh while one is under way joins it.
    @ObservationIgnored private var reading: Task<Void, Never>?

    /// The first answers are read at once, so nothing shows a permission as missing for a moment.
    private init() { apply(Self.read()) }

    func isGranted(_ p: Permission) -> Bool { granted.contains(p) }
    func allGranted(_ ps: [Permission]) -> Bool { ps.allSatisfy(granted.contains) }

    /// Re-reads everything. Assigns only what changed, so views only redraw for real changes.
    /// Returns the read, for whoever needs to wait for its answers.
    @discardableResult
    func refresh() -> Task<Void, Never>? {
        if let reading { return reading }
        let task = Task { [weak self] in
            let read = await Task.detached(priority: .utility) { Self.read() }.value
            self?.apply(read)
            self?.reading = nil
        }
        reading = task
        return task
    }

    private struct Reading: Sendable {
        var granted: Set<Permission>
        var launchesAtLogin: Bool
    }

    private nonisolated static func read() -> Reading {
        Reading(granted: Set(Permission.allCases.filter(\.isGranted)), launchesAtLogin: LoginItem.isEnabled)
    }

    private func apply(_ read: Reading) {
        if read.granted != granted { granted = read.granted }
        if read.launchesAtLogin != launchesAtLogin { launchesAtLogin = read.launchesAtLogin }
    }

    func start() {
        refresh()
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
            MainActor.assumeIsolated { _ = SystemStatus.shared.refresh() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }
}
