import Foundation

/// What sets a trigger off: keys you press, clicks on the Imp, or something happening on your Mac.
/// A trigger is one event, plus optional conditions that must hold at that moment
/// (`Shortcut.conditions`: "when Chrome comes to the front, only if the battery is below 20 %").
///
/// Nothing here decides what Imp *does* about it: the trigger hands its instruction and what
/// happened to the Imp's model, which answers and uses its tools (animations, speech, the shell…).
public struct Trigger: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Sendable, Identifiable {
        /// A global keyboard shortcut (`Shortcut.hotkey`).
        case keys
        /// Clicking the Imp `number` times in a row.
        case clicks
        /// The battery falls below `number` percent (as a condition: is below it).
        case battery
        /// The charger is plugged in (`flag` true) or unplugged (false).
        case charger
        /// An app comes to the front: `text` is its name or bundle ID (empty: any app).
        case app
        /// The browser's active tab shows a website whose address contains `text` (needs the extension).
        case website
        /// Every day at `number` minutes after midnight.
        case time
        /// Every `number` minutes.
        case every
        /// You're back after at least `number` minutes away from the keyboard and mouse.
        case back
        /// The Mac wakes up or its screen unlocks.
        case wake
        /// Imp starts (or this Imp comes out onto the desktop).
        case start
        /// The processor has been busier than `number` percent for a while.
        case busy
        /// The Mac is running hot (its thermal state is serious or critical).
        case hot
        /// The network goes away (`flag` true) or comes back (false).
        case offline
        /// Only as a condition: the time of day is between `number` and `until` (minutes after midnight).
        case hours

        public var id: String { rawValue }

        public var title: String {
            switch self {
            case .keys: "Keys"
            case .clicks: "Clicks on the Imp"
            case .battery: "Battery low"
            case .charger: "Charger"
            case .app: "App in front"
            case .website: "Website"
            case .time: "Every day at"
            case .every: "Repeat"
            case .back: "You come back"
            case .wake: "Mac wakes up"
            case .start: "Imp starts"
            case .busy: "Mac is busy"
            case .hot: "Mac runs hot"
            case .offline: "Network"
            case .hours: "Time of day"
            }
        }

        public var symbol: String {
            switch self {
            case .keys: "keyboard"
            case .clicks: "cursorarrow.click"
            case .battery: "battery.25percent"
            case .charger: "powerplug"
            case .app: "macwindow"
            case .website: "globe"
            case .time: "alarm"
            case .every: "repeat"
            case .back: "figure.walk.arrival"
            case .wake: "sunrise"
            case .start: "power"
            case .busy: "cpu"
            case .hot: "thermometer.high"
            case .offline: "wifi.slash"
            case .hours: "clock"
            }
        }

        /// Can set a trigger off (everything but a time window, which only ever *holds*).
        public var isEvent: Bool { self != .hours }

        /// Describes a state that can be checked at any moment, so it can also be a condition.
        public var isCondition: Bool {
            switch self {
            case .battery, .charger, .app, .website, .busy, .hot, .offline, .hours: true
            case .keys, .clicks, .time, .every, .back, .wake, .start: false
            }
        }

        /// Happens on the Mac rather than to the Imp (keys and clicks are you, talking to it).
        public var isAmbient: Bool { self != .keys && self != .clicks }
    }

    public var kind: Kind
    /// clicks: how many; battery/busy: percent; every/back: minutes; time/hours: minutes after midnight.
    public var number: Int?
    /// hours: where the window ends (minutes after midnight; it may wrap past midnight).
    public var until: Int?
    /// app: its name or bundle ID; website: part of the address.
    public var text: String?
    /// charger: plugged in (true) or unplugged; offline: goes offline (true) or comes back.
    public var flag: Bool?

    public init(_ kind: Kind, number: Int? = nil, until: Int? = nil, text: String? = nil, flag: Bool? = nil) {
        self.kind = kind; self.number = number; self.until = until; self.text = text; self.flag = flag
    }

    public static let keys = Trigger(.keys)
    public static func clicks(_ n: Int) -> Trigger { Trigger(.clicks, number: n) }

    /// A fresh trigger of `kind` with sensible values to edit.
    public static func starter(_ kind: Kind) -> Trigger {
        switch kind {
        case .keys, .wake, .start, .hot: Trigger(kind)
        case .clicks: .clicks(1)
        case .battery: Trigger(.battery, number: 20)
        case .charger: Trigger(.charger, flag: true)
        case .app, .website: Trigger(kind, text: "")
        case .time: Trigger(.time, number: 9 * 60)
        case .every: Trigger(.every, number: 60)
        case .back: Trigger(.back, number: 15)
        case .busy: Trigger(.busy, number: 85)
        case .offline: Trigger(.offline, flag: true)
        case .hours: Trigger(.hours, number: 9 * 60, until: 18 * 60)
        }
    }

    // MARK: Values, within sensible ranges

    public static let maxClicks = 3

    public var clicks: Int { min(max(number ?? 1, 1), Self.maxClicks) }
    public var percent: Int { min(max(number ?? 20, 1), 99) }
    public var minutes: Int { min(max(number ?? 60, 1), 24 * 60) }
    public var minuteOfDay: Int { ((number ?? 0) % 1440 + 1440) % 1440 }
    public var endMinute: Int { ((until ?? 0) % 1440 + 1440) % 1440 }
    public var word: String { (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
    public var isOn: Bool { flag ?? true }

    /// In a few words, for lists: "Battery below 20 %", "Safari comes to the front".
    public var summary: String {
        switch kind {
        case .keys: "Keys"
        case .clicks: clicks == 1 ? "1 click on the Imp" : "\(clicks) clicks on the Imp"
        case .battery: "Battery below \(percent) %"
        case .charger: isOn ? "Charger plugged in" : "Charger unplugged"
        case .app: word.isEmpty ? "Any app comes to the front" : "\(word) comes to the front"
        case .website: word.isEmpty ? "Any website" : "On \(word)"
        case .time: "Every day at \(Self.clock(minuteOfDay))"
        case .every: minutes % 60 == 0 ? "Every \(minutes / 60 == 1 ? "hour" : "\(minutes / 60) hours")" : "Every \(minutes) min"
        case .back: "Back after \(minutes) min away"
        case .wake: "The Mac wakes up"
        case .start: "Imp starts"
        case .busy: "Processor above \(percent) %"
        case .hot: "The Mac runs hot"
        case .offline: isOn ? "Network goes away" : "Network comes back"
        case .hours: "Between \(Self.clock(minuteOfDay)) and \(Self.clock(endMinute))"
        }
    }

    /// The same, as a condition: "the battery is below 20 %".
    public var conditionSummary: String {
        switch kind {
        case .battery: "Battery below \(percent) %"
        case .charger: isOn ? "On the charger" : "On battery"
        case .app: word.isEmpty ? "Any app in front" : "\(word) is in front"
        case .website: word.isEmpty ? "Any website open" : "\(word) is open"
        case .busy: "Processor above \(percent) %"
        case .hot: "The Mac is hot"
        case .offline: isOn ? "Offline" : "Online"
        default: summary
        }
    }

    /// "09:05".
    public static func clock(_ minuteOfDay: Int) -> String {
        String(format: "%02d:%02d", minuteOfDay / 60, minuteOfDay % 60)
    }

    /// Minutes after midnight from "9:05", "21:30", "9pm", "7:15 am". Nil if it isn't a time.
    public static func minuteOfDay(parsing text: String) -> Int? {
        var s = text.lowercased().trimmingCharacters(in: .whitespaces)
        var offset = 0
        if s.hasSuffix("am") || s.hasSuffix("pm") {
            offset = s.hasSuffix("pm") ? 12 * 60 : 0
            s = String(s.dropLast(2)).trimmingCharacters(in: .whitespaces)
        }
        let parts = s.split(separator: ":").map { Int($0) }
        guard (1...2).contains(parts.count), let h = parts[0], let m = parts.count > 1 ? parts[1] : 0,
              (0..<60).contains(m), (0..<24).contains(h) else { return nil }
        if offset > 0 || text.lowercased().hasSuffix("am") {
            guard (1...12).contains(h) else { return nil }
            return (h % 12) * 60 + m + offset
        }
        return h * 60 + m
    }
}

// MARK: What happens on the Mac

/// How the Mac is right now, as far as triggers care. Nil fields aren't known (no battery, no
/// browser extension connected…).
public struct MacState: Equatable, Sendable {
    public var battery: Int?
    public var charging: Bool?
    public var frontApp: String?
    public var frontAppID: String?
    /// The address in the browser's active tab.
    public var page: String?
    public var pageTitle: String?
    /// Processor load, 0…100.
    public var cpu: Int?
    public var hot = false
    public var offline = false
    public var minuteOfDay = 0

    public init(battery: Int? = nil, charging: Bool? = nil, frontApp: String? = nil, frontAppID: String? = nil,
                page: String? = nil, pageTitle: String? = nil, cpu: Int? = nil, hot: Bool = false, offline: Bool = false,
                minuteOfDay: Int = 0) {
        self.battery = battery; self.charging = charging; self.frontApp = frontApp; self.frontAppID = frontAppID
        self.page = page; self.pageTitle = pageTitle; self.cpu = cpu; self.hot = hot; self.offline = offline
        self.minuteOfDay = minuteOfDay
    }
}

/// Something that just happened on the Mac.
public enum MacEvent: Equatable, Sendable {
    /// The battery level changed (from, to), in percent.
    case battery(from: Int, to: Int)
    case charger(connected: Bool)
    case app(name: String, bundleID: String)
    case page(url: String, title: String)
    /// A new minute began: minutes after midnight, and minutes since 1970 (for "every N minutes").
    case minute(ofDay: Int, absolute: Int)
    /// You're back after `away` minutes.
    case back(away: Int)
    case wake
    case start
    /// The processor load (percent), sustained.
    case busy(Int)
    case hot
    case network(offline: Bool)

    /// What happened, in words for the model.
    public var description: String {
        switch self {
        case .battery(_, let to): "The battery is down to \(to) %."
        case .charger(let on): on ? "The charger was plugged in." : "The charger was unplugged."
        case .app(let name, _): "\(name) came to the front."
        case .page(let url, let title): title.isEmpty ? "The browser is showing \(url)." : "The browser is showing “\(title)” (\(url))."
        case .minute(let m, _): "It's \(Trigger.clock(m))."
        case .back(let away): "The user is back after \(away) minutes away."
        case .wake: "The Mac just woke up."
        case .start: "Imp just started."
        case .busy(let load): "The processor has been busy (\(load) %)."
        case .hot: "The Mac is running hot."
        case .network(let offline): offline ? "The network went away." : "The network is back."
        }
    }
}

extension Trigger {
    /// Whether this trigger goes off for `event`.
    public func matches(_ event: MacEvent) -> Bool {
        switch (kind, event) {
        case (.battery, .battery(let from, let to)): from >= percent && to < percent
        case (.charger, .charger(let on)): on == isOn
        case (.app, .app(let name, let id)): Self.sameApp(word, name: name, id: id)
        case (.website, .page(let url, _)): Self.onSite(word, url: url)
        case (.time, .minute(let m, _)): m == minuteOfDay
        case (.every, .minute(_, let absolute)): absolute % minutes == 0
        case (.back, .back(let away)): away >= minutes
        case (.wake, .wake), (.start, .start), (.hot, .hot): true
        case (.busy, .busy(let load)): load >= percent
        case (.offline, .network(let offline)): offline == isOn
        default: false
        }
    }

    /// Whether this condition holds in `state`. Kinds that aren't states never hold.
    public func holds(in s: MacState) -> Bool {
        switch kind {
        case .battery: s.battery.map { $0 < percent } ?? false
        case .charger: s.charging.map { $0 == isOn } ?? false
        case .app: s.frontApp.map { Self.sameApp(word, name: $0, id: s.frontAppID ?? "") } ?? false
        case .website: s.page.map { Self.onSite(word, url: $0) } ?? false
        case .busy: s.cpu.map { $0 >= percent } ?? false
        case .hot: s.hot
        case .offline: s.offline == isOn
        case .hours: Self.within(s.minuteOfDay, from: minuteOfDay, to: endMinute)
        case .keys, .clicks, .time, .every, .back, .wake, .start: false
        }
    }

    /// A minute of the day inside a window that may wrap past midnight (22:00–07:00).
    static func within(_ m: Int, from a: Int, to b: Int) -> Bool {
        a <= b ? (a <= m && m < b) : (m >= a || m < b)
    }

    /// An app by name or bundle ID, ignoring case. Empty matches any app.
    static func sameApp(_ wanted: String, name: String, id: String) -> Bool {
        wanted.isEmpty || wanted.caseInsensitiveCompare(name) == .orderedSame || wanted.caseInsensitiveCompare(id) == .orderedSame
    }

    /// An address containing `wanted` ("amazon", "amazon.com", "github.com/apple"), ignoring case
    /// and the scheme. Empty matches any page.
    static func onSite(_ wanted: String, url: String) -> Bool {
        guard !wanted.isEmpty else { return !url.isEmpty }
        func bare(_ s: String) -> String {
            var t = s.lowercased()
            for p in ["https://", "http://", "www."] where t.hasPrefix(p) { t.removeFirst(p.count) }
            return t
        }
        return bare(url).contains(bare(wanted))
    }
}

extension Shortcut {
    /// Goes off for `event` in `state`: its trigger matches and every condition holds.
    public func fires(on event: MacEvent, in state: MacState) -> Bool {
        isEnabled && trigger.kind.isAmbient && trigger.matches(event) && conditions.allSatisfy { $0.holds(in: state) }
    }
}
