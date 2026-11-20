import Foundation

/// What sets a trigger off. The contract is `docs/sharing/kits.md#triggers`: a trigger is one
/// event (with its one `value`), optional conditions, and one to five steps.
public enum TriggerEvent: String, Codable, CaseIterable, Sendable, Identifiable {
    /// A global keyboard shortcut (`Shortcut.hotkey`).
    case keys
    /// Clicking the Imp 1 to 3 times in a row.
    case click
    // What the person does to the Imp with the pointer.
    case poke, hold, drag, drop, shake, stroke, tickle, circle, swish, rush, dangle
    /// The pointer rests next to the Imp for `value` seconds.
    case near
    /// The pointer moves away from the Imp.
    case away
    /// Imp starts (or this trigger is made or switched on).
    case start
    /// Every day at `value` ("HH:MM").
    case at
    /// Every `value` minutes.
    case every
    /// Nobody has touched or talked to the Imp for `value` seconds.
    case idle
    /// The person is back after `value` minutes away.
    case back
    /// The Mac wakes up or unlocks.
    case wake
    /// An app (`value`: name or bundle ID, empty: any) comes to the front.
    case app
    /// The browser shows a page whose address contains `value`.
    case website
    /// The battery falls below `value` percent.
    case battery
    /// The charger is `plugged` or `unplugged`.
    case charger
    /// The processor stays above `value` percent.
    case busy
    /// The Mac runs hot.
    case hot
    /// The network goes `offline` or comes back `online`.
    case network

    public var id: String { rawValue }

    /// The things done to the Imp with the pointer: four quick clicks, press and hold, drag, drop, and so on.
    public static let gestures: [TriggerEvent] = [.poke, .hold, .drag, .drop, .shake, .stroke, .tickle, .circle, .swish, .rush, .dangle]

    public var isGesture: Bool { Self.gestures.contains(self) }

    /// The person did it (keys, clicks, the pointer), rather than the Mac or the clock.
    public var isPersonal: Bool { self == .keys || self == .click || isGesture || self == .near || self == .away }

    /// Happens on the Mac or the clock, not because the person did something to the Imp.
    public var isAmbient: Bool { !isPersonal }

    /// Needs the cursor watched from afar (the global mouse monitor): these are not clicks on the Imp.
    public var watchesCursor: Bool {
        switch self {
        case .stroke, .tickle, .circle, .swish, .rush, .dangle, .near, .away: true
        default: false
        }
    }

    /// Happens to the Imp itself, not on the Mac: needs no Mac state.
    public var isBodily: Bool { self == .idle || self == .near || self == .away }

    /// One or two words, for its tile and its menu.
    public var title: String {
        switch self {
        case .keys: String(localized: "Keys")
        case .click: String(localized: "trigger.event.click")
        case .poke: String(localized: "trigger.event.poke")
        case .hold: String(localized: "trigger.event.hold")
        case .drag: String(localized: "trigger.event.drag")
        case .drop: String(localized: "trigger.event.drop")
        case .shake: String(localized: "trigger.event.shake")
        case .stroke: String(localized: "trigger.event.stroke")
        case .tickle: String(localized: "trigger.event.tickle")
        case .circle: String(localized: "trigger.event.circle")
        case .swish: String(localized: "trigger.event.swish")
        case .rush: String(localized: "trigger.event.rush")
        case .dangle: String(localized: "trigger.event.dangle")
        case .near: String(localized: "trigger.event.near")
        case .away: String(localized: "trigger.event.away")
        case .start: String(localized: "Imp starts")
        case .at: String(localized: "trigger.event.at")
        case .every: String(localized: "trigger.event.every")
        case .idle: String(localized: "Left alone")
        case .back: String(localized: "You come back")
        case .wake: String(localized: "Mac wakes up")
        case .app: String(localized: "App in front")
        case .website: String(localized: "Website")
        case .battery: String(localized: "Battery low")
        case .charger: String(localized: "Charger")
        case .busy: String(localized: "Mac is busy")
        case .hot: String(localized: "Mac runs hot")
        case .network: String(localized: "Network")
        }
    }

    /// What it means, in a few more words: the tooltip of its tile.
    public var hint: String {
        switch self {
        case .keys: String(localized: "A shortcut on the keyboard")
        case .click: String(localized: "Clicks on the Imp")
        case .poke: String(localized: "4 quick clicks")
        case .hold: String(localized: "Press and hold it")
        case .drag: String(localized: "Drag it")
        case .drop: String(localized: "Let go of it")
        case .shake: String(localized: "Shake it while carrying")
        case .stroke: String(localized: "Stroke its head")
        case .tickle: String(localized: "Tickle it")
        case .circle: String(localized: "Circle it with the cursor")
        case .swish: String(localized: "Swish past its face")
        case .rush: String(localized: "Rush at it")
        case .dangle: String(localized: "Bob the cursor above it")
        case .near: String(localized: "Cursor comes close")
        case .away: String(localized: "Cursor moves away")
        case .start: String(localized: "The Imp starts, or the trigger is switched on")
        case .at: String(localized: "Every day at")
        case .every: String(localized: "Again and again, every few minutes")
        case .idle: String(localized: "Left alone")
        case .back: String(localized: "You come back")
        case .wake: String(localized: "Mac wakes up")
        case .app: String(localized: "An app comes to the front")
        case .website: String(localized: "A website opens in the browser")
        case .battery: String(localized: "The battery runs low")
        case .charger: String(localized: "The charger is plugged in or out")
        case .busy: String(localized: "Mac is busy")
        case .hot: String(localized: "Mac runs hot")
        case .network: String(localized: "The network goes away or comes back")
        }
    }

    public var symbol: String {
        switch self {
        case .keys: "keyboard"
        case .click: "cursorarrow.click"
        case .poke: "cursorarrow.click.2"
        case .hold: "hand.tap.fill"
        case .drag: "hand.raised.fingers.spread.fill"
        case .drop: "arrow.down.circle"
        case .shake: "iphone.radiowaves.left.and.right"
        case .stroke: "hand.draw"
        case .tickle: "hand.point.up.fill"
        case .circle: "arrow.triangle.2.circlepath"
        case .swish: "arrow.left.and.right"
        case .rush: "hare.fill"
        case .dangle: "arrow.up.and.down"
        case .near: "cursorarrow.rays"
        case .away: "cursorarrow.motionlines"
        case .start: "power"
        case .at: "alarm"
        case .every: "repeat"
        case .idle: "moon.zzz"
        case .back: "figure.walk.arrival"
        case .wake: "sunrise"
        case .app: "macwindow"
        case .website: "globe"
        case .battery: "battery.25percent"
        case .charger: "powerplug"
        case .busy: "cpu"
        case .hot: "thermometer.high"
        case .network: "wifi.slash"
        }
    }

    /// Whether `value` is a number in the kit's JSON (else a word, or nothing).
    var valueIsNumber: Bool {
        switch self {
        case .click, .near, .every, .idle, .back, .battery, .busy: true
        default: false
        }
    }
}

/// What must hold at the moment a trigger goes off (`if`).
public enum TriggerState: String, Codable, CaseIterable, Sendable, Identifiable {
    case battery, charger, app, website, busy, hot, network
    /// Between two times of day (it may wrap past midnight): `value` "22:00-07:00".
    case hours
    /// On some days: "mon-fri" or "sat,sun".
    case days
    /// Whether the Imp is asleep: `value` true or false.
    case asleep

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .battery: String(localized: "Battery low")
        case .charger: String(localized: "Charger")
        case .app: String(localized: "App in front")
        case .website: String(localized: "Website")
        case .busy: String(localized: "Mac is busy")
        case .hot: String(localized: "Mac runs hot")
        case .network: String(localized: "Network")
        case .hours: String(localized: "Time of day")
        case .days: String(localized: "Days")
        case .asleep: String(localized: "Asleep")
        }
    }

    public var symbol: String {
        switch self {
        case .battery: "battery.25percent"
        case .charger: "powerplug"
        case .app: "macwindow"
        case .website: "globe"
        case .busy: "cpu"
        case .hot: "thermometer.high"
        case .network: "wifi"
        case .hours: "clock"
        case .days: "calendar"
        case .asleep: "moon.zzz"
        }
    }

    var valueIsNumber: Bool { self == .battery || self == .busy }
}

// MARK: - Event and condition values

/// The one argument of an event or a condition, as text, with the typed readings of it. Numbers are
/// kept as text so a trigger reads and writes the same everywhere. `nil` means the default.
enum TriggerValue {
    static func int(_ v: String?, _ fallback: Int, _ range: ClosedRange<Int>) -> Int {
        min(max(v.flatMap { Int($0) } ?? fallback, range.lowerBound), range.upperBound)
    }

    static let weekdays = ["mon", "tue", "wed", "thu", "fri", "sat", "sun"]

    /// Days of the week, 0 = Monday … 6 = Sunday, from "mon-fri" or "sat,sun" (a range may wrap: "fri-mon").
    static func days(_ text: String) -> Set<Int>? {
        func index(_ s: Substring) -> Int? {
            let t = s.trimmingCharacters(in: .whitespaces).lowercased()
            guard t.count >= 3, t.count <= 9 else { return nil }
            return weekdays.firstIndex { t.hasPrefix($0) }
        }
        var out: Set<Int> = []
        for part in text.split(separator: ",", omittingEmptySubsequences: false) {
            let ends = part.split(separator: "-", omittingEmptySubsequences: false)
            switch ends.count {
            case 1:
                guard let d = index(ends[0]) else { return nil }
                out.insert(d)
            case 2:
                guard let a = index(ends[0]), let b = index(ends[1]) else { return nil }
                var d = a
                out.insert(d)
                while d != b { d = (d + 1) % 7; out.insert(d) }
            default: return nil
            }
        }
        return out.isEmpty ? nil : out
    }

    /// "22:00-07:00" as minutes after midnight.
    static func window(_ text: String) -> (from: Int, to: Int)? {
        let parts = text.split(separator: "-", omittingEmptySubsequences: false).map { Trigger.minuteOfDay(parsing: String($0)) }
        guard parts.count == 2, let a = parts[0], let b = parts[1] else { return nil }
        return (a, b)
    }
}

/// An event with its value: what sets a trigger off.
public struct Trigger: Codable, Hashable, Sendable {
    public var event: TriggerEvent
    /// The event's one argument as text (see the table in the kit format). `nil`: none, or the default.
    public var value: String?

    public init(_ event: TriggerEvent, value: String? = nil) { self.event = event; self.value = value }

    public static let keys = Trigger(.keys)
    public static func click(_ n: Int) -> Trigger { Trigger(.click, value: String(n)) }

    /// A fresh trigger of `event` with sensible values to edit.
    public static func starter(_ event: TriggerEvent) -> Trigger {
        switch event {
        case .click: .click(1)
        case .near: Trigger(.near, value: "0")
        case .at: Trigger(.at, value: "09:00")
        case .every: Trigger(.every, value: "60")
        case .idle: Trigger(.idle, value: String(defaultIdleSeconds))
        case .back: Trigger(.back, value: "5")
        case .battery: Trigger(.battery, value: "20")
        case .busy: Trigger(.busy, value: "85")
        case .charger: Trigger(.charger, value: "plugged")
        case .network: Trigger(.network, value: "offline")
        case .app: Trigger(.app, value: "")
        case .website: Trigger(.website, value: "")
        default: Trigger(event)
        }
    }

    /// How long the Imp is left alone before it falls asleep, unless the user changes that trigger.
    public static let defaultIdleSeconds = 240
    public static let idleRange = 5...86_400
    public static let maxClicks = 3
    public static let nearRange = 0...3_600

    public var clicks: Int { TriggerValue.int(value, 1, 1...Self.maxClicks) }
    /// near: seconds the pointer rests.
    public var nearSeconds: Int { TriggerValue.int(value, 0, Self.nearRange) }
    /// battery / busy: percent.
    public var percent: Int { TriggerValue.int(value, event == .busy ? 85 : 20, 1...99) }
    public var idleSeconds: Int { TriggerValue.int(value, Self.defaultIdleSeconds, Self.idleRange) }
    /// every: minutes. back: minutes away.
    public var minutes: Int { TriggerValue.int(value, event == .back ? 5 : 60, 1...(24 * 60)) }
    /// at: minutes after midnight.
    public var minuteOfDay: Int { value.flatMap { Self.minuteOfDay(parsing: $0) } ?? 0 }
    public var word: String { (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
    /// charger: plugged in (else unplugged). network: goes offline (else comes back).
    public var isOn: Bool {
        switch event {
        case .charger: word.lowercased() != "unplugged"
        default: word.lowercased() != "online"
        }
    }

    /// In a few words, for lists: "Battery below 20 %", "Safari comes to the front".
    public var summary: String {
        switch event {
        case .keys: String(localized: "Keys")
        case .click: clicks == 1 ? String(localized: "1 click on the Imp") : String(localized: "\(clicks) clicks on the Imp")
        case .poke, .hold, .drag, .drop, .shake, .stroke, .tickle, .circle, .swish, .rush, .dangle: event.hint
        case .near: nearSeconds == 0 ? String(localized: "The cursor comes close") : String(localized: "The cursor rests beside it for \(Self.seconds(nearSeconds))")
        case .away: String(localized: "The cursor moves away")
        case .start: String(localized: "Imp starts")
        case .at: String(localized: "Every day at \(Self.shownClock(minuteOfDay))")
        case .every:
            if minutes % 60 != 0 { String(localized: "Every \(Self.span(minutes))") }
            else if minutes == 60 { String(localized: "Every hour") }
            else { String(localized: "Every \(minutes / 60) hours") }
        case .idle: String(localized: "Left alone for \(Self.seconds(idleSeconds))")
        case .back: String(localized: "Back after \(Self.span(minutes)) away")
        case .wake: String(localized: "The Mac wakes up")
        case .app: word.isEmpty ? String(localized: "Any app comes to the front") : String(localized: "\(word) comes to the front")
        case .website: word.isEmpty ? String(localized: "Any website") : String(localized: "On \(word)")
        case .battery: String(localized: "Battery below \(percent) %")
        case .charger: isOn ? String(localized: "Charger plugged in") : String(localized: "Charger unplugged")
        case .busy: String(localized: "Processor above \(percent) %")
        case .hot: String(localized: "The Mac runs hot")
        case .network: isOn ? String(localized: "Network goes away") : String(localized: "Network comes back")
        }
    }

    /// "09:05".
    /// A number of minutes as the user's language writes a duration: "15 min", "1 hr 30 min".
    static func span(_ minutes: Int) -> String {
        Duration.seconds(minutes * 60).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated))
    }

    /// A number of seconds as the user's language writes a duration: "4 min", "90 sec".
    public static func seconds(_ seconds: Int) -> String {
        Duration.seconds(seconds).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .abbreviated))
    }

    /// A time of day the way the user's region writes it ("9:05 PM" or "21:05"), for showing.
    static func shownClock(_ minuteOfDay: Int) -> String {
        let day = Calendar.current.startOfDay(for: Date())
        return (Calendar.current.date(byAdding: .minute, value: minuteOfDay, to: day) ?? day).formatted(date: .omitted, time: .shortened)
    }

    public static func clock(_ minuteOfDay: Int) -> String {
        String(format: "%02d:%02d", minuteOfDay / 60, minuteOfDay % 60)
    }

    /// Minutes after midnight from "9:05", "21:30", "9pm", "7:15 am". Nil if it isn't a time.
    public static func minuteOfDay(parsing text: String) -> Int? {
        var s = text.lowercased().trimmingCharacters(in: .whitespaces)
        let twelveHour = s.hasSuffix("am") || s.hasSuffix("pm")
        let offset = s.hasSuffix("pm") ? 12 * 60 : 0
        if twelveHour { s = String(s.dropLast(2)).trimmingCharacters(in: .whitespaces) }
        let parts = s.split(separator: ":").map { Int($0) }
        guard (1...2).contains(parts.count), let h = parts[0], let m = parts.count > 1 ? parts[1] : 0,
              (0..<60).contains(m), (0..<24).contains(h) else { return nil }
        if twelveHour {
            guard (1...12).contains(h) else { return nil }
            return (h % 12) * 60 + m + offset
        }
        return h * 60 + m
    }
}

/// One thing that must hold when a trigger goes off.
public struct Condition: Codable, Hashable, Sendable {
    public var state: TriggerState
    public var value: String?

    public init(_ state: TriggerState, value: String? = nil) { self.state = state; self.value = value }

    public static func starter(_ state: TriggerState) -> Condition {
        switch state {
        case .battery: Condition(.battery, value: "20")
        case .busy: Condition(.busy, value: "85")
        case .charger: Condition(.charger, value: "plugged")
        case .network: Condition(.network, value: "offline")
        case .app, .website: Condition(state, value: "")
        case .hours: Condition(.hours, value: "09:00-18:00")
        case .days: Condition(.days, value: "mon-fri")
        case .asleep: Condition(.asleep, value: "true")
        case .hot: Condition(.hot)
        }
    }

    public var percent: Int { TriggerValue.int(value, state == .busy ? 85 : 20, 1...99) }
    public var word: String { (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
    /// charger: plugged in. network: offline. asleep: asleep.
    public var isOn: Bool {
        switch state {
        case .charger: word.lowercased() != "unplugged"
        case .network: word.lowercased() != "online"
        default: word.lowercased() != "false"
        }
    }
    /// hours: where the window starts and ends (minutes after midnight).
    public var window: (from: Int, to: Int) { value.flatMap(TriggerValue.window) ?? (0, 0) }
    /// days: 0 = Monday … 6 = Sunday.
    public var days: Set<Int> { value.flatMap(TriggerValue.days) ?? [] }

    /// The same, as a condition: "the battery is below 20 %".
    public var summary: String {
        switch state {
        case .battery: String(localized: "Battery below \(percent) %")
        case .charger: isOn ? String(localized: "On the charger") : String(localized: "On battery")
        case .app: word.isEmpty ? String(localized: "Any app in front") : String(localized: "\(word) is in front")
        case .website: word.isEmpty ? String(localized: "Any website open") : String(localized: "\(word) is open")
        case .busy: String(localized: "Processor above \(percent) %")
        case .hot: String(localized: "The Mac is hot")
        case .network: isOn ? String(localized: "Offline") : String(localized: "Online")
        case .hours: String(localized: "Between \(Trigger.shownClock(window.from)) and \(Trigger.shownClock(window.to))")
        case .days: word
        case .asleep: isOn ? String(localized: "Asleep") : String(localized: "Awake")
        }
    }
}

// MARK: What happens on the Mac

/// How the Mac and the Imp are right now, as far as triggers care. Nil fields aren't known (no
/// battery, no browser extension connected…).
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
    /// Day of the week, 0 = Monday … 6 = Sunday.
    public var weekday = 0
    /// The Imp is asleep.
    public var asleep = false

    public init(battery: Int? = nil, charging: Bool? = nil, frontApp: String? = nil, frontAppID: String? = nil,
                page: String? = nil, pageTitle: String? = nil, cpu: Int? = nil, hot: Bool = false, offline: Bool = false,
                minuteOfDay: Int = 0, weekday: Int = 0, asleep: Bool = false) {
        self.battery = battery; self.charging = charging; self.frontApp = frontApp; self.frontAppID = frontAppID
        self.page = page; self.pageTitle = pageTitle; self.cpu = cpu; self.hot = hot; self.offline = offline
        self.minuteOfDay = minuteOfDay; self.weekday = weekday; self.asleep = asleep
    }
}

/// Something that just happened.
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
    /// The Imp has been left alone: the seconds since it was last touched, before and now.
    /// (Sent as the clock moves, so a trigger goes off once, as the time passes its number.)
    case idle(from: Double, to: Double)
    /// The person clicked the Imp this many times in a row.
    case click(Int)
    /// The person did a pointer gesture to the Imp (one of `TriggerEvent.gestures`).
    case gesture(TriggerEvent)
    /// The pointer has rested next to the Imp: seconds before and now (`from` is -1 when it just came up).
    case near(from: Double, to: Double)
    /// The pointer moved away from the Imp.
    case away

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
        case .idle(_, let to): "Nobody has touched the Imp for \(Int(to)) seconds."
        case .click(let n): n == 1 ? "The user clicked the Imp." : "The user clicked the Imp \(n) times."
        case .gesture(let g): "The user did this to the Imp: \(g.rawValue)."
        case .near: "The cursor came up to the Imp."
        case .away: "The cursor moved away from the Imp."
        }
    }
}

extension Trigger {
    /// Whether this trigger goes off for `event`.
    public func matches(_ happened: MacEvent) -> Bool {
        switch (event, happened) {
        case (.battery, .battery(let from, let to)): from >= percent && to < percent
        case (.charger, .charger(let on)): on == isOn
        case (.app, .app(let name, let id)): Self.sameApp(word, name: name, id: id)
        case (.website, .page(let url, _)): Self.onSite(word, url: url)
        case (.at, .minute(let m, _)): m == minuteOfDay
        case (.every, .minute(_, let absolute)): absolute % minutes == 0
        case (.back, .back(let away)): away >= minutes
        case (.wake, .wake), (.start, .start), (.hot, .hot), (.away, .away): true
        case (.busy, .busy(let load)): load >= percent
        case (.network, .network(let offline)): offline == isOn
        case (.idle, .idle(let from, let to)): from < Double(idleSeconds) && to >= Double(idleSeconds)
        case (.click, .click(let n)): n == clicks
        case (.near, .near(let from, let to)): from < Double(nearSeconds) && to >= Double(nearSeconds)
        case (let e, .gesture(let g)) where e.isGesture: e == g
        default: false
        }
    }
}

extension Condition {
    /// Whether this condition holds in `state`.
    public func holds(in s: MacState) -> Bool {
        switch state {
        case .battery: s.battery.map { $0 < percent } ?? false
        case .charger: s.charging.map { $0 == isOn } ?? false
        case .app: s.frontApp.map { Trigger.sameApp(word, name: $0, id: s.frontAppID ?? "") } ?? false
        case .website: s.page.map { Trigger.onSite(word, url: $0) } ?? false
        case .busy: s.cpu.map { $0 >= percent } ?? false
        case .hot: s.hot
        case .network: s.offline == isOn
        case .hours: Trigger.within(s.minuteOfDay, from: window.from, to: window.to)
        case .days: days.contains(s.weekday)
        case .asleep: s.asleep == isOn
        }
    }
}

extension Trigger {
    /// A minute of the day inside a window that may wrap past midnight (22:00 to 07:00).
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
    /// Goes off for `event` in `state`: it is on, its event matches and every condition holds.
    public func fires(on event: MacEvent, in state: MacState) -> Bool {
        isEnabled && trigger.matches(event) && conditions.allSatisfy { $0.holds(in: state) }
    }
}
