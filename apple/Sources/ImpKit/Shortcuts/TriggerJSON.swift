import Foundation

/// The trigger object of `docs/sharing/kits.md#triggers`, read and written in ONE place: kits, Imps
/// inside kits and the Imp's own tool `imp_add_trigger` all go through here.
///
///     { "name": "Ouch", "on": "poke", "if": [ { "state": "hours", "value": "09:00-18:00" } ],
///       "do": [ { "act": "play", "value": "Wiggle" }, { "act": "say", "value": "Ouch!" } ] }

/// A value as text: strings trimmed, numbers without a trailing ".0", booleans as true/false.
private func valueText(_ v: JSONValue?) -> String? {
    guard let v else { return nil }
    if let s = v.string { let t = s.trimmingCharacters(in: .whitespacesAndNewlines); return t.isEmpty ? nil : t }
    if let b = v.bool { return b ? "true" : "false" }
    if let d = v.double { return d == d.rounded() && abs(d) < 1e12 ? String(Int(d)) : String(d) }
    return nil
}

private func integer(_ text: String?, _ range: ClosedRange<Int>, _ what: String) throws -> Int? {
    guard let text else { return nil }
    guard let n = Int(text), range.contains(n) else {
        throw ToolArgumentError("\(what) must be a whole number from \(range.lowerBound) to \(range.upperBound), not “\(text)”.")
    }
    return n
}

private func required(_ text: String?, _ what: String) throws -> String {
    guard let text, !text.isEmpty else { throw ToolArgumentError("\(what) needs a `value`.") }
    return text
}

private func oneOf(_ text: String?, _ options: [String], _ what: String) throws -> String {
    let t = try required(text, what).lowercased()
    guard options.contains(t) else { throw ToolArgumentError("\(what): `value` must be \(options.joined(separator: " or ")), not “\(t)”.") }
    return t
}

private func oneOfEnum<T: RawRepresentable & CaseIterable>(_ type: T.Type, _ raw: String?, _ what: String) throws -> T where T.RawValue == String {
    let list = type.allCases.map(\.rawValue)
    let t = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard let found = type.allCases.first(where: { $0.rawValue == t }) else {
        throw ToolArgumentError("Unknown \(what) “\(raw ?? "")”: use one of \(list.joined(separator: ", ")).")
    }
    return found
}

extension Trigger {
    /// An event from its name and `value`, checked: unknown event, missing or out-of-range value.
    /// (`keys` keeps its value in `Shortcut.hotkey`.)
    public init(on name: String?, value raw: JSONValue?) throws {
        let event = try oneOfEnum(TriggerEvent.self, name, "event (`on`)")
        let v = valueText(raw)
        let what = "`\(event.rawValue)`"
        switch event {
        case .keys:
            self.init(.keys)
        case .click:
            self.init(.click, value: try integer(v, 1...Self.maxClicks, "\(what) clicks").map(String.init))
        case .near:
            self.init(.near, value: try integer(v, Self.nearRange, "\(what) seconds").map(String.init))
        case .every:
            self.init(.every, value: String(try integer(try required(v, what), 1...1440, "\(what) minutes")!))
        case .idle:
            self.init(.idle, value: String(try integer(try required(v, what), Self.idleRange, "\(what) seconds")!))
        case .back:
            self.init(.back, value: try integer(v, 1...1440, "\(what) minutes").map(String.init))
        case .battery, .busy:
            self.init(event, value: try integer(v, 1...99, "\(what) percent").map(String.init))
        case .at:
            guard let m = Self.minuteOfDay(parsing: try required(v, what)) else { throw ToolArgumentError("\(what) `value` is a time like \"09:00\".") }
            self.init(.at, value: Self.clock(m))
        case .app:
            self.init(.app, value: v ?? "")
        case .website:
            self.init(.website, value: try required(v, what))
        case .charger:
            self.init(.charger, value: try oneOf(v, ["plugged", "unplugged"], what))
        case .network:
            self.init(.network, value: try oneOf(v, ["offline", "online"], what))
        case .poke, .hold, .drag, .drop, .shake, .stroke, .tickle, .circle, .swish, .rush, .dangle, .away, .start, .wake, .hot:
            self.init(event)
        }
    }

    /// The `value` as the kit writes it: a number where the event takes one.
    var valueJSON: JSONValue? {
        guard let value, !value.isEmpty || event == .app else { return nil }
        if event.valueIsNumber, let n = Int(value) { return .number(Double(n)) }
        return event == .app && value.isEmpty ? nil : .string(value)
    }
}

extension Condition {
    public init(state name: String?, value raw: JSONValue?) throws {
        let state = try oneOfEnum(TriggerState.self, name, "state (`if`)")
        let v = valueText(raw)
        let what = "`if` `\(state.rawValue)`"
        switch state {
        case .battery, .busy:
            self.init(state, value: try integer(v, 1...99, "\(what) percent").map(String.init))
        case .charger:
            self.init(.charger, value: try oneOf(v, ["plugged", "unplugged"], what))
        case .network:
            self.init(.network, value: try oneOf(v, ["offline", "online"], what))
        case .app:
            self.init(.app, value: v ?? "")
        case .website:
            self.init(.website, value: try required(v, what))
        case .hot:
            self.init(.hot)
        case .hours:
            guard let w = TriggerValue.window(try required(v, what)) else { throw ToolArgumentError("\(what) `value` is like \"22:00-07:00\".") }
            self.init(.hours, value: Trigger.clock(w.from) + "-" + Trigger.clock(w.to))
        case .days:
            let text = try required(v, what).lowercased()
            guard TriggerValue.days(text) != nil else { throw ToolArgumentError("\(what) `value` is like \"mon-fri\" or \"sat,sun\".") }
            self.init(.days, value: text.replacingOccurrences(of: " ", with: ""))
        case .asleep:
            self.init(.asleep, value: try oneOf(v ?? "true", ["true", "false"], what))
        }
    }

    var kitJSON: JSONValue {
        var o: [String: JSONValue] = ["state": .string(state.rawValue)]
        if state != .hot, let value, !(value.isEmpty && state == .app) {
            if state.valueIsNumber, let n = Int(value) { o["value"] = .number(Double(n)) }
            else if state == .asleep { o["value"] = .bool(isOn) }
            else { o["value"] = .string(value) }
        }
        return .object(o)
    }
}

extension Step {
    public init(json: JSONValue) throws {
        let act = try oneOfEnum(Act.self, json["act"]?.string, "act")
        let v = valueText(json["value"])
        let what = "`\(act.rawValue)`"
        switch act {
        case .ask:
            let clip = json["clipboard"]?.bool == true
            guard v != nil || clip else { throw ToolArgumentError("\(what) needs a `value`: what to do, in plain words (or `clipboard`: true).") }
            self.init(.ask, value: v, clipboard: clip ? true : nil)
        case .say:
            self.init(.say, value: try required(v, what))
        case .play:
            self.init(.play, value: try required(v, what + " (the animation's name)"))
        case .sleep, .wake:
            self.init(act, value: v)
        case .follow:
            let mode = try oneOf(v, FollowMode.allCases.map(\.rawValue), what)
            if let s = json["speed"]?.double, !(0.5...2).contains(s) { throw ToolArgumentError("\(what) `speed` is from 0.5 to 2, not \(s).") }
            self.init(.follow, value: mode, speed: json["speed"]?.double)
        case .open:
            self.init(.open, value: try oneOf(v, Target.allCases.map(\.rawValue), what))
        }
    }

    var kitJSON: JSONValue {
        var o: [String: JSONValue] = ["act": .string(act.rawValue)]
        if !text.isEmpty { o["value"] = .string(text) }
        if handsOverClipboard { o["clipboard"] = .bool(true) }
        if act == .follow, let speed, speed != FollowMath.defaultSpeed { o["speed"] = .number(speed) }
        return .object(o)
    }
}

extension Shortcut {
    public static let maxNameLength = 60

    /// A trigger from the contract's object (a kit's, or `imp_add_trigger`'s arguments). `imp` is who
    /// it belongs to unless `for` says `every_imp`. `old` is the trigger it changes (it keeps its id,
    /// scope and switch). Throws a message the model or the person can act on.
    public init(tool json: JSONValue, imp: UUID, replacing old: Shortcut? = nil) throws {
        let trigger = try Trigger(on: json["on"]?.string, value: json["value"])
        var hotkey: Hotkey?
        if trigger.event == .keys {
            guard let text = valueText(json["value"]), let keys = Hotkey(parsing: text) else {
                throw ToolArgumentError("`keys` needs a `value` like \"ctrl+cmd+T\".")
            }
            guard keys.isValidGlobalShortcut else { throw ToolArgumentError("\(keys.displayString) needs ⌘, ⌥ or ⌃ (or a function key).") }
            hotkey = keys
        }
        var conditions: [Condition] = []
        if let list = json["if"] {
            guard let array = list.array else { throw ToolArgumentError("`if` is a list of {state, value}.") }
            for (i, item) in array.enumerated() {
                do { conditions.append(try Condition(state: item["state"]?.string, value: item["value"])) }
                catch { throw ToolArgumentError("if[\(i + 1)]: \(Self.message(error))") }
            }
        }
        guard let list = json["do"]?.array, (1...Step.maxPerTrigger).contains(list.count) else {
            throw ToolArgumentError("`do` is a list of 1 to \(Step.maxPerTrigger) steps {act, value}.")
        }
        var steps: [Step] = []
        for (i, item) in list.enumerated() {
            do { steps.append(try Step(json: item)) } catch { throw ToolArgumentError("do[\(i + 1)]: \(Self.message(error))") }
        }
        var name = json["name"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if name.count > Self.maxNameLength { throw ToolArgumentError("`name` has 1 to \(Self.maxNameLength) characters.") }
        if name.isEmpty { name = old?.name ?? String(trigger.summary.prefix(Self.maxNameLength)) }
        // Whose it is: as asked (`for`), else whose it was, else this Imp's.
        let performer: UUID? = if let who = json["for"]?.string?.lowercased() { who == "every_imp" ? nil : imp } else if let old { old.performer } else { imp }
        self.init(name: name, isEnabled: json["enabled"]?.bool ?? old?.isEnabled ?? true, hotkey: hotkey, performer: performer,
                  trigger: trigger, conditions: conditions, steps: steps)
        if let old { id = old.id; overrides = old.overrides }
    }

    private static func message(_ error: Error) -> String { (error as? LocalizedError)?.errorDescription ?? error.localizedDescription }

    /// The contract's object. Whose it is isn't part of it: whoever adds it decides.
    var kitJSON: JSONValue {
        var o: [String: JSONValue] = ["name": .string(name), "on": .string(trigger.event.rawValue)]
        if trigger.event == .keys, let hotkey { o["value"] = .string(hotkey.displayString) }
        else if let v = trigger.valueJSON { o["value"] = v }
        if !conditions.isEmpty { o["if"] = .array(conditions.map(\.kitJSON)) }
        o["do"] = .array(steps.map(\.kitJSON))
        if !isEnabled { o["enabled"] = .bool(false) }
        return .object(o)
    }

    var displayLabel: String { name.trimmingCharacters(in: .whitespaces).isEmpty ? "Untitled" : name }

    /// One line for the model (`imp_list_triggers`): the id, then the contract's object, then who has it.
    public func toolDescription() -> String {
        var o = kitJSON
        if case .object(var d) = o { d["id"] = .string(id.uuidString); d["for"] = .string(performer == nil ? "every_imp" : "me"); d["enabled"] = .bool(isEnabled); o = .object(d) }
        return o.jsonString
    }
}
