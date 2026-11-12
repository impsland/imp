import AppKit
import Darwin
import ImpKit
import IOKit.ps
import Network
import os

/// What Imp notices about the Mac, for triggers (`MacEvent`s) and for the model (`report()`).
/// Everything here is public information that needs no permission: the battery, the app in front,
/// waking up, heat, the network, processor load, time away from the keyboard and mouse (only how
/// long, never what was typed), and the page in the browser if its extension is connected.
@MainActor
final class Senses {
    /// Something happened. Called on the main actor.
    var onEvent: ((MacEvent) -> Void)?

    private(set) var battery: Int?
    private(set) var charging: Bool?
    private(set) var cpu: Int?
    private(set) var offline = false
    private var frontApp: NSRunningApplication?
    /// The last few processor samples (one every `cpuEvery` seconds), for a sustained load.
    private var loads: [Int] = []
    private var lastTicks: host_cpu_load_info?
    private var lastMinute = -1
    private var awaySince: Date?
    private var timers: [Timer] = []
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private let path = NWPathMonitor()
    private let log = Logger(subsystem: "app.imp.Imp", category: "senses")

    static let cpuEvery: TimeInterval = 10
    /// Away from the keyboard and mouse at least this long before coming back counts.
    static let awayAfter: TimeInterval = 60

    func start() {
        guard timers.isEmpty else { return }
        frontApp = NSWorkspace.shared.frontmostApplication
        readBattery(announce: false)
        sampleCPU()
        let ws = NSWorkspace.shared.notificationCenter
        observe(ws, NSWorkspace.didActivateApplicationNotification) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            self?.frontApp = app
            guard app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
            self?.onEvent?(.app(name: app.localizedName ?? "", bundleID: app.bundleIdentifier ?? ""))
        }
        observe(ws, NSWorkspace.didWakeNotification) { [weak self] _ in self?.onEvent?(.wake) }
        observe(DistributedNotificationCenter.default(), Notification.Name("com.apple.screenIsUnlocked")) { [weak self] _ in
            self?.onEvent?(.wake)
        }
        observe(NotificationCenter.default, ProcessInfo.thermalStateDidChangeNotification) { [weak self] _ in
            if Self.isHot { self?.onEvent?(.hot) }
        }
        path.pathUpdateHandler = { [weak self] p in
            let off = p.status != .satisfied
            Task { @MainActor in
                guard let self, off != self.offline else { return }
                self.offline = off
                self.onEvent?(.network(offline: off))
            }
        }
        path.start(queue: .global(qos: .utility))
        timers = [
            repeating(30) { $0.readBattery(announce: true) },
            repeating(Self.cpuEvery) { $0.sampleCPU() },
            repeating(5) { $0.checkAway() },
            repeating(2) { $0.checkMinute() },
        ]
        log.info("senses started")
    }

    func stop() {
        timers.forEach { $0.invalidate() }
        timers = []
        observers.forEach { $0.0.removeObserver($0.1) }
        observers = []
        path.cancel()
    }

    // MARK: State

    static var isHot: Bool { [.serious, .critical].contains(ProcessInfo.processInfo.thermalState) }

    /// How the Mac is right now.
    var state: MacState {
        let page = BrowserBridge.shared.page
        let c = Calendar.current.dateComponents([.hour, .minute], from: Date())
        return MacState(battery: battery, charging: charging, frontApp: frontApp?.localizedName, frontAppID: frontApp?.bundleIdentifier,
                        page: page?.url, pageTitle: page?.title, cpu: cpu, hot: Self.isHot, offline: offline,
                        minuteOfDay: (c.hour ?? 0) * 60 + (c.minute ?? 0))
    }

    /// Everything Imp can tell the model about the Mac (`mac_status`).
    func report() -> String {
        let s = state
        var lines: [String] = []
        let now = Date()
        lines.append("Time: \(now.formatted(date: .complete, time: .shortened)) (\(TimeZone.current.identifier))")
        if let b = s.battery {
            lines.append("Battery: \(b) %, \(s.charging == true ? "on the charger" : "on battery")")
        } else {
            lines.append("Battery: none (a desktop Mac), on mains power")
        }
        if let cpu = s.cpu { lines.append("Processor: \(cpu) % busy (\(ProcessInfo.processInfo.activeProcessorCount) cores)") }
        lines.append("Heat: \(Self.thermalWords)")
        if let memory = Self.memory() { lines.append("Memory: \(memory)") }
        lines.append("Network: \(s.offline ? "offline" : "online")")
        lines.append("Up since: \(Self.duration(ProcessInfo.processInfo.systemUptime)) ago")
        let idle = Self.idleSeconds
        lines.append("Away from keyboard and mouse: \(idle < 5 ? "no, in use" : Self.duration(idle))")
        if let front = s.frontApp { lines.append("In front: \(front)\(s.frontAppID.map { " (\($0))" } ?? "")") }
        let apps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }.compactMap(\.localizedName)
        lines.append("Open apps: \(apps.joined(separator: ", "))")
        if let screen = NSScreen.main {
            let f = screen.frame
            lines.append("Main screen: \(Int(f.width))×\(Int(f.height)) points\(NSScreen.screens.count > 1 ? ", \(NSScreen.screens.count) screens" : "")")
        }
        if let page = BrowserBridge.shared.page {
            lines.append("Browser (\(page.browser)): “\(page.title)” \(page.url)")
        } else {
            lines.append("Browser page: unknown (the Imp browser extension isn't connected)")
        }
        return lines.joined(separator: "\n")
    }

    private static var thermalWords: String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: "normal"
        case .fair: "warm"
        case .serious: "hot (slowing down)"
        case .critical: "very hot (slowing down a lot)"
        @unknown default: "unknown"
        }
    }

    // MARK: Sampling

    private func readBattery(announce: Bool) {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return }
        for source in list {
            guard let d = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  d[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  let now = d[kIOPSCurrentCapacityKey] as? Int, let max = d[kIOPSMaxCapacityKey] as? Int, max > 0 else { continue }
            let level = now * 100 / max
            let plugged = (d[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue
            let (oldLevel, oldPlugged) = (battery, charging)
            battery = level
            charging = plugged
            guard announce else { return }
            if let oldPlugged, oldPlugged != plugged { onEvent?(.charger(connected: plugged)) }
            if let oldLevel, oldLevel != level { onEvent?(.battery(from: oldLevel, to: level)) }
            return
        }
    }

    private func sampleCPU() {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count) }
        }
        guard result == KERN_SUCCESS else { return }
        defer { lastTicks = info }
        guard let last = lastTicks else { return }
        func ticks(_ i: host_cpu_load_info, _ k: Int32) -> Double {
            Double(withUnsafeBytes(of: i.cpu_ticks) { $0.load(fromByteOffset: Int(k) * MemoryLayout<natural_t>.stride, as: natural_t.self) })
        }
        let busy = [CPU_STATE_USER, CPU_STATE_SYSTEM, CPU_STATE_NICE].reduce(0.0) { $0 + ticks(info, $1) - ticks(last, $1) }
        let idle = ticks(info, CPU_STATE_IDLE) - ticks(last, CPU_STATE_IDLE)
        guard busy + idle > 0 else { return }
        let load = Int((busy / (busy + idle) * 100).rounded())
        loads = Array((loads + [load]).suffix(3))
        // Busy means busy for a while (half a minute), not one spike.
        let sustained = loads.count == 3 ? loads.min()! : 0
        cpu = load
        // Every sample: whoever listens decides when it crosses their line (see `AppModel.fire`).
        if loads.count == 3 { onEvent?(.busy(sustained)) }
    }

    /// Seconds since the last keyboard or mouse event (anywhere, no permission needed).
    static var idleSeconds: TimeInterval {
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
    }

    private func checkAway() {
        let idle = Self.idleSeconds
        if idle >= Self.awayAfter {
            if awaySince == nil { awaySince = Date().addingTimeInterval(-idle) }
        } else if let since = awaySince, idle < 5 {
            awaySince = nil
            onEvent?(.back(away: Int(Date().timeIntervalSince(since) / 60)))
        }
    }

    private func checkMinute() {
        let absolute = Int(Date().timeIntervalSince1970 / 60)
        guard absolute != lastMinute else { return }
        let first = lastMinute < 0
        lastMinute = absolute
        guard !first else { return }
        let c = Calendar.current.dateComponents([.hour, .minute], from: Date())
        onEvent?(.minute(ofDay: (c.hour ?? 0) * 60 + (c.minute ?? 0), absolute: absolute))
    }

    // MARK: Helpers

    private func observe(_ center: NotificationCenter, _ name: Notification.Name, _ handle: @escaping @MainActor (Notification) -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { note in
            nonisolated(unsafe) let note = note               // delivered on the main queue, read there only
            MainActor.assumeIsolated { handle(note) }
        }
        observers.append((center, token))
    }

    private func repeating(_ seconds: TimeInterval, _ work: @escaping @MainActor (Senses) -> Void) -> Timer {
        let t = Timer(timeInterval: seconds, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { if let self { work(self) } }
        }
        t.tolerance = seconds * 0.2
        RunLoop.main.add(t, forMode: .common)
        return t
    }

    private static func memory() -> String? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count) }
        }
        guard result == KERN_SUCCESS else { return nil }
        let page = Double(getpagesize())
        let used = Double(stats.active_count + stats.wire_count + stats.compressor_page_count) * page
        let total = Double(ProcessInfo.processInfo.physicalMemory)
        let gb = { (b: Double) in String(format: "%.1f GB", b / 1_073_741_824) }
        return "\(gb(used)) of \(gb(total)) in use"
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let m = Int(seconds / 60)
        if m < 1 { return "\(Int(seconds)) s" }
        if m < 60 { return "\(m) min" }
        let h = m / 60
        return h < 48 ? "\(h) h \(m % 60) min" : "\(h / 24) days"
    }
}
