import AppKit
import ImpKit
import Observation

/// How hard the Imps may work: the frame rate they draw at, from `FramePolicy` (the same numbers as the
/// iPhone's). Anything moving is drawn at 60 fps and a resting Imp's breath and floating at 30, and both
/// fall (to 30 and 20) in Low Power Mode and when the Mac runs hot, but stay smooth.
@MainActor @Observable
final class Energy {
    static let shared = Energy()

    private(set) var budget = Energy.read()

    /// Seconds between frames while something moves (a head turning, eyes following the cursor, a hop).
    var frame: Double { FramePolicy.livelyInterval[budget] ?? Self.fullFrame }

    /// Seconds between frames for an Imp that only breathes, floats and blinks.
    var calmFrame: Double { FramePolicy.calmInterval[budget] ?? FramePolicy.calmInterval[.saving] ?? Self.fullFrame }

    /// Seconds between frames for a drawing that wants `fps` frames a second: half as many when saving.
    func interval(fps: Double) -> Double { budget == .full ? 1 / fps : 2 / fps }

    nonisolated static let fullFrame = 1 / FramePolicy.framesPerSecond

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

/// How much an Imp needs the ticker right now.
enum TickState: Sendable { case busy, calm, asleep }

/// How often the Imps' inner life ticks, from what they are doing: fast while anything moves,
/// slowly while they all rest, rarely while they all sleep, never while nobody can see them.
enum TickPace {
    static let busy: TimeInterval = 0.1
    static let calm: TimeInterval = 0.25
    static let asleep: TimeInterval = 1

    static func interval(_ states: [TickState], unseen: Bool) -> TimeInterval? {
        guard !unseen, !states.isEmpty else { return nil }
        if states.contains(.busy) { return busy }
        return states.contains(.calm) ? calm : asleep
    }
}

/// One timer for every Imp's inner life, and one reading of the cursor, however many Imps are out.
/// It ticks fast only while something moves (see `TickPace`) and speeds up at once when the mouse
/// moves or an Imp starts something (`nudge`).
@MainActor
final class LifeTicker {
    static let shared = LifeTicker()

    private var lives: [ImpLife] = []
    private var timer: Timer?
    private var current: TimeInterval?
    /// The screens are asleep or the session is locked: nobody can see an Imp, so nothing ticks.
    private var unseen = false
    private var observers: [NSObjectProtocol] = []
    private var monitors: [Any] = []
    private(set) var mouse = NSEvent.mouseLocation
    private(set) var lastMouseMove = Date()

    private init() {
        let center = NSWorkspace.shared.notificationCenter
        let names: [(Notification.Name, Bool)] = [
            (NSWorkspace.screensDidSleepNotification, true), (NSWorkspace.screensDidWakeNotification, false),
            (NSWorkspace.sessionDidResignActiveNotification, true), (NSWorkspace.sessionDidBecomeActiveNotification, false),
        ]
        for (name, away) in names {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { LifeTicker.shared.setUnseen(away) }
            })
        }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved], handler: { _ in
            MainActor.assumeIsolated { LifeTicker.shared.mouseMoved() }
        }) { monitors.append(global) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved], handler: { event in
            MainActor.assumeIsolated { LifeTicker.shared.mouseMoved() }
            return event
        }) { monitors.append(local) }
    }

    private func setUnseen(_ value: Bool) {
        guard unseen != value else { return }
        unseen = value
        reschedule(to: value ? nil : TickPace.busy)
    }

    func add(_ life: ImpLife) {
        guard !lives.contains(where: { $0 === life }) else { return }
        lives.append(life)
        nudge()
    }

    func remove(_ life: ImpLife) {
        lives.removeAll { $0 === life }
        if lives.isEmpty { reschedule(to: nil) }
    }

    /// The mouse moved. Every Imp is lively at once (so its view draws at the full rate from the next
    /// frame, not from the next tick, which could be 150 ms away) and the ticker speeds up.
    private func mouseMoved() {
        lastMouseMove = Date()
        for life in lives { life.mouseMoved() }
        nudge()
    }

    /// Something happened that an Imp reacts to (the mouse, a message, a trigger, a wake): tick fast again.
    func nudge() {
        guard !unseen, !lives.isEmpty, current != TickPace.busy else { return }
        reschedule(to: TickPace.busy)
    }

    private func reschedule(to interval: TimeInterval?) {
        guard interval != current || (interval != nil && timer == nil) else { return }
        timer?.invalidate()
        timer = nil
        current = interval
        guard let interval else { return }
        let t = Timer(timeInterval: interval, repeats: true) { _ in
            MainActor.assumeIsolated { LifeTicker.shared.tick() }
        }
        t.tolerance = interval / 2        // lets the system coalesce wake-ups with other work
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func tick() {
        let now = Date(), p = NSEvent.mouseLocation
        if hypot(p.x - mouse.x, p.y - mouse.y) > 2 {
            mouse = p
            lastMouseMove = now
        }
        let idle = now.timeIntervalSince(lastMouseMove)
        for life in lives { life.tick(now: now, mouse: p, mouseIdle: idle) }
        let wanted = TickPace.interval(lives.map(\.tickState), unseen: unseen)
        // The mouse moved a moment ago: stay fast until it has rested.
        reschedule(to: idle < 1 ? TickPace.busy : wanted)
    }
}
