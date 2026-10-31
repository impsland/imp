import AppKit
import ImpKit
import Observation

/// How hard the Imps may work: the frame rate they draw at while moving, which drops in Low Power
/// Mode and when the Mac runs hot.
@MainActor @Observable
final class Energy {
    static let shared = Energy()

    private(set) var budget = Energy.read()

    /// Seconds between frames while something moves.
    var frame: Double { budget == .full ? Self.fullFrame : Self.savingFrame }

    nonisolated static let fullFrame = 1.0 / 60
    nonisolated static let savingFrame = 1.0 / 30

    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    private init() {
        for name in [Notification.Name.NSProcessInfoPowerStateDidChange, ProcessInfo.thermalStateDidChangeNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { Energy.shared.budget = Energy.read() }
            })
        }
    }

    private static func read() -> FramePolicy.Budget {
        FramePolicy.budget(lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled, thermal: ProcessInfo.processInfo.thermalState)
    }
}

/// One timer for every Imp's inner life, and one reading of the cursor, however many Imps are out.
@MainActor
final class LifeTicker {
    static let shared = LifeTicker()

    /// Seconds between ticks.
    static let interval: TimeInterval = 0.1

    private var lives: [ImpLife] = []
    private var timer: Timer?
    private(set) var mouse = NSEvent.mouseLocation
    private(set) var lastMouseMove = Date()

    func add(_ life: ImpLife) {
        guard !lives.contains(where: { $0 === life }) else { return }
        lives.append(life)
        guard timer == nil else { return }
        let t = Timer(timeInterval: Self.interval, repeats: true) { _ in
            MainActor.assumeIsolated { LifeTicker.shared.tick() }
        }
        t.tolerance = Self.interval / 2        // lets the system coalesce wake-ups with other work
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func remove(_ life: ImpLife) {
        lives.removeAll { $0 === life }
        guard lives.isEmpty else { return }
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        let now = Date(), p = NSEvent.mouseLocation
        if hypot(p.x - mouse.x, p.y - mouse.y) > 2 {
            mouse = p
            lastMouseMove = now
        }
        for life in lives { life.tick(now: now, mouse: p, mouseIdle: now.timeIntervalSince(lastMouseMove)) }
    }
}
