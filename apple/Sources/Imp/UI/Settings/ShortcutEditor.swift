import AppKit
import ImpDesign
import ImpKit
import SwiftUI

extension Shortcut {
    /// What it does first, as an icon.
    var symbol: String { steps.first?.act.symbol ?? trigger.event.symbol }

    /// One line about what it does, in the app's language.
    var summary: String { steps.map(\.shownSummary).joined(separator: " · ") }
}

extension Step {
    /// One step in a few words, in the app's language, for lists ("Play an animation: Wiggle").
    /// `Step.summary` is the English one the model reads.
    var shownSummary: String {
        var detail: String
        switch act {
        case .ask, .play, .sleep, .wake: detail = text
        case .say: detail = text.isEmpty ? "" : "“\(text)”"
        case .follow: detail = followMode.title + (followMode.movesBody ? String(format: " %.1f×", followSpeed) : "")
        case .open: detail = Step.Target(rawValue: text).map { String(localized: String.LocalizationValue("triggers.open.\($0.rawValue)")) } ?? text
        }
        if act == .ask, handsOverClipboard { detail += " (\(String(localized: "triggers.step.clipboard")))" }
        if act == .say, speaksAloud { detail += " (\(String(localized: "triggers.step.aloud")))" }
        return detail.isEmpty ? act.title : "\(act.title): \(detail)"
    }
}

/// Adding or editing a trigger, on a copy: its name, its event (and only if…), its steps, and for whom.
/// Nothing changes until Add or Save.
struct ShortcutSheet: View {
    @Environment(\.impTint) private var tint
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let model: AppModel
    /// The Imp whose settings these are.
    let imp: UUID
    @State var shortcut: Shortcut
    let isNew: Bool
    /// How the trigger applies to this Imp now.
    let scope: SettingScope
    let save: (Shortcut, ScopeTarget) -> Void
    let duplicate: (Shortcut) -> Void
    let delete: () -> Void
    @State private var confirmingDelete = false
    /// Who the change is for: this Imp, unless Every Imp is picked.
    @State private var target: ScopeTarget

    init(model: AppModel, imp: UUID, shortcut: Shortcut, isNew: Bool, scope: SettingScope,
         save: @escaping (Shortcut, ScopeTarget) -> Void, duplicate: @escaping (Shortcut) -> Void, delete: @escaping () -> Void) {
        self.model = model; self.imp = imp; self._shortcut = State(initialValue: shortcut); self.isNew = isNew; self.scope = scope
        self.save = save; self.duplicate = duplicate; self.delete = delete
        self._target = State(initialValue: .imp(imp))
    }

    var body: some View {
        SheetScaffold(icon: shortcut.trigger.event.symbol, title: isNew ? "triggers.new" : "triggers.edit",
                      info: "triggers.help.sheet") {
            HoverIconButton(systemName: "play.fill", help: "Try now", tint: tint) { model.trigger(shortcut, on: model.imp(imp), trying: true) }
                .disabled(!shortcut.isValid)
        } content: {
            VStack(alignment: .leading, spacing: Spacing.medium) {
                FieldRow("common.name", info: "triggers.help.name") {
                    TextField("common.name", text: $shortcut.name, prompt: Text(verbatim: shortcut.trigger.summary)).impField()
                }
                whenRow
                conditionsRow
                stepsRow
                FieldRow("triggers.f.for", info: "triggers.help.for") {
                    EvenGrid(minWidth: Sizing.menuTitle, spacing: Spacing.snug) {
                        ChoiceChip(title: LocalizedStringKey(words("triggers.scope.just", impName)), icon: SettingScope.onlyThisImp.symbol,
                                   picked: target != .everyImp) { target = .imp(imp) }
                        ChoiceChip(title: "scope.every_imp", icon: SettingScope.everyImp.symbol, picked: target == .everyImp) { target = .everyImp }
                    }
                }
                ForEach(messages, id: \.self) { m in
                    Label { Text(verbatim: m).fixedSize(horizontal: false, vertical: true) } icon: { Image(systemName: "exclamationmark.triangle.fill") }
                        .font(Typeface.small).foregroundStyle(Tone.warnText)
                }
            }
            .padding(Spacing.roomy)
            .impCard(radius: Radius.medium)
        } footer: {
            if !isNew {
                HoverIconButton(systemName: scope == .changed ? "arrow.uturn.backward" : "trash", help: "Delete", tint: Tone.danger) { confirmingDelete = true }
                HoverIconButton(systemName: "plus.square.on.square", help: "Duplicate") { duplicate(shortcut) }
            }
            Button(isNew ? "Add" : "Save") { save(shortcut, target) }
                .buttonStyle(.primary)
                .keyboardShortcut(.defaultAction)
                .disabled(!shortcut.isValid)
        }
        .confirmationDialog("Delete this trigger?", isPresented: $confirmingDelete) {
            Button("Delete", role: .destructive) { delete() }
        }
    }

    /// A part of the form that needs the whole width: its name above it.
    private func section<Content: View>(_ title: LocalizedStringKey, info: LocalizedStringKey, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Spacing.snug) {
            HStack(spacing: Spacing.hairline) {
                Text(title).font(Typeface.caption).foregroundStyle(Tone.muted).lineLimit(1).fixedSize()
                InfoTip(info)
            }
            content()
        }
    }

    private var impName: String { model.profile(imp)?.callName ?? ImpProfile.stranger }

    private func animate(_ change: () -> Void) { withImpAnimation(ImpDesign.Motion.expand, reduceMotion: reduceMotion, change) }

    // MARK: When

    private var whenRow: some View {
        section("triggers.f.when", info: "triggers.help.when") {
            VStack(alignment: .leading, spacing: Spacing.snug) {
                CompactMenu(verbatim: shortcut.trigger.event.title, symbol: shortcut.trigger.event.symbol) {
                    Section("triggers.group.you") {
                        eventButton(.keys); eventButton(.click)
                        Menu("triggers.gestures") { ForEach(TriggerEvent.gestures) { eventButton($0) } }
                        eventButton(.near); eventButton(.away)
                    }
                    Section("triggers.group.time") {
                        ForEach([TriggerEvent.start, .at, .every, .idle, .back, .wake]) { eventButton($0) }
                    }
                    Section("triggers.group.mac") {
                        ForEach([TriggerEvent.app, .website, .battery, .charger, .busy, .hot, .network]) { eventButton($0) }
                    }
                }
                let kind = ValueKind(event: shortcut.trigger.event)
                if kind != .none {
                    ValueControl(kind: kind, value: Binding(get: { shortcut.trigger.value }, set: { shortcut.trigger.value = $0 }),
                                 hotkey: $shortcut.hotkey)
                }
                if let w = keyWarning {
                    Text(verbatim: w).font(Typeface.small).foregroundStyle(Tone.warnText).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func eventButton(_ e: TriggerEvent) -> some View {
        Button { animate { shortcut.trigger = .starter(e) } } label: { Label(e.title, systemImage: e.symbol) }
    }

    // MARK: Only if

    private func condition(at i: Int) -> Binding<Condition> {
        Binding(get: { shortcut.conditions.indices.contains(i) ? shortcut.conditions[i] : .starter(.hot) },
                set: { if shortcut.conditions.indices.contains(i) { shortcut.conditions[i] = $0 } })
    }

    private var conditionsRow: some View {
        section("triggers.f.only_if", info: "triggers.help.only_if") {
            VStack(alignment: .leading, spacing: Spacing.snug) {
                ForEach(shortcut.conditions.indices, id: \.self) { i in
                    let c = condition(at: i)
                    VStack(alignment: .leading, spacing: Spacing.snug) {
                        HStack(spacing: Spacing.small) {
                            CompactMenu(verbatim: c.wrappedValue.state.title, symbol: "line.3.horizontal.decrease") {
                                ForEach(TriggerState.allCases) { s in
                                    Button(s.title) { animate { if shortcut.conditions.indices.contains(i) { shortcut.conditions[i] = .starter(s) } } }
                                }
                            }
                            Spacer(minLength: 0)
                            HoverIconButton(systemName: "minus.circle", help: "triggers.cond.remove") {
                                animate { if shortcut.conditions.indices.contains(i) { shortcut.conditions.remove(at: i) } }
                            }
                        }
                        let kind = ValueKind(state: c.wrappedValue.state)
                        if kind != .none {
                            ValueControl(kind: kind, value: Binding(get: { c.wrappedValue.value }, set: { c.wrappedValue.value = $0 }),
                                         hotkey: .constant(nil), asCondition: true)
                        }
                    }
                    .padding(Spacing.cozy)
                    .background(RoundedRectangle(cornerRadius: Radius.tile, style: .continuous).fill(Tone.well))
                }
                CompactMenu(title: shortcut.conditions.isEmpty ? "triggers.cond.always" : "triggers.cond.add", symbol: "plus") {
                    ForEach(TriggerState.allCases) { s in
                        Button(s.title) { animate { shortcut.conditions.append(.starter(s)) } }
                    }
                }
            }
        }
    }

    // MARK: Do

    private func step(at i: Int) -> Binding<Step> {
        Binding(get: { shortcut.steps.indices.contains(i) ? shortcut.steps[i] : Step(.sleep) },
                set: { if shortcut.steps.indices.contains(i) { shortcut.steps[i] = $0 } })
    }

    private var stepsRow: some View {
        section("triggers.f.do", info: "triggers.help.do") {
            VStack(alignment: .leading, spacing: Spacing.snug) {
                ForEach(shortcut.steps.indices, id: \.self) { i in stepCard(i) }
                if shortcut.steps.count < Step.maxPerTrigger {
                    CompactMenu(title: "triggers.step.add", symbol: "plus") {
                        ForEach(Step.Act.allCases) { a in
                            Button { animate { shortcut.steps.append(Self.fresh(a)) } } label: { Label(a.title, systemImage: a.symbol) }
                        }
                    }
                }
            }
        }
    }

    static func fresh(_ a: Step.Act) -> Step { Step(a, value: a == .follow ? "eyes" : a == .open ? "chat" : "") }

    private func stepCard(_ i: Int) -> some View {
        let s = step(at: i)
        return VStack(alignment: .leading, spacing: Spacing.snug) {
            HStack(spacing: Spacing.small) {
                CompactMenu(verbatim: s.wrappedValue.act.title, symbol: s.wrappedValue.act.symbol) {
                    ForEach(Step.Act.allCases) { a in
                        Button { animate { if shortcut.steps.indices.contains(i) { shortcut.steps[i] = Self.fresh(a) } } } label: { Label(a.title, systemImage: a.symbol) }
                    }
                }
                Spacer(minLength: 0)
                HoverIconButton(systemName: "arrow.up", help: "triggers.step.up") { move(i, by: -1) }.disabled(i == 0)
                HoverIconButton(systemName: "arrow.down", help: "triggers.step.down") { move(i, by: 1) }.disabled(i >= shortcut.steps.count - 1)
                HoverIconButton(systemName: "minus.circle", help: "triggers.step.remove") {
                    animate { if shortcut.steps.indices.contains(i) { shortcut.steps.remove(at: i) } }
                }
            }
            stepControls(s)
        }
        .padding(Spacing.cozy)
        .background(RoundedRectangle(cornerRadius: Radius.tile, style: .continuous).fill(Tone.well))
    }

    private func move(_ i: Int, by d: Int) {
        let j = i + d
        guard shortcut.steps.indices.contains(i), shortcut.steps.indices.contains(j) else { return }
        animate { shortcut.steps.swapAt(i, j) }
    }

    @ViewBuilder private func stepControls(_ s: Binding<Step>) -> some View {
        let text = Binding(get: { s.wrappedValue.value ?? "" }, set: { s.wrappedValue.value = $0 })
        switch s.wrappedValue.act {
        case .ask:
            EditorWell(text: text, placeholder: "triggers.step.ask_ph", height: 72)
            Toggle("triggers.step.clipboard", isOn: Binding(get: { s.wrappedValue.clipboard == true }, set: { s.wrappedValue.clipboard = $0 ? true : nil }))
                .toggleStyle(ImpToggleButtonStyle())
        case .say:
            TextField("triggers.step.say_ph", text: text).impField()
            Toggle("triggers.step.aloud", isOn: Binding(get: { s.wrappedValue.aloud == true }, set: { s.wrappedValue.aloud = $0 ? true : nil }))
                .toggleStyle(ImpToggleButtonStyle())
        case .play, .sleep, .wake:
            animationMenu(text, optional: s.wrappedValue.act != .play)
        case .follow:
            let mode = Binding(get: { s.wrappedValue.followMode }, set: { s.wrappedValue.value = $0.rawValue })
            ImpSegmented("triggers.follow", selection: mode, options: FollowMode.allCases, title: \.title, symbol: \.symbol)
            Row("triggers.step.speed", info: "triggers.help.speed") {
                RowSlider(value: Binding(get: { s.wrappedValue.followSpeed }, set: { s.wrappedValue.speed = FollowMath.clampedSpeed($0) }),
                          range: FollowMath.speedRange, step: 0.1, label: "triggers.step.speed",
                          shown: String(format: "%.1f×", s.wrappedValue.followSpeed), resets: FollowMath.defaultSpeed)
            }
            .disabled(!mode.wrappedValue.movesBody)
        case .open:
            let target = Binding(get: { s.wrappedValue.target ?? .chat }, set: { s.wrappedValue.value = $0.rawValue })
            ImpSegmented("triggers.open", selection: target, options: Step.Target.allCases, title: { Self.title($0) },
                        symbol: { ["text_box": "character.cursor.ibeam", "listen": "mic", "chat": "bubble.left", "settings": "gearshape"][$0.rawValue] ?? "circle" })
        }
    }

    static func title(_ t: Step.Target) -> String {
        switch t {
        case .textBox: String(localized: "triggers.open.text_box")
        case .listen: String(localized: "triggers.open.listen")
        case .chat: String(localized: "triggers.open.chat")
        case .settings: String(localized: "triggers.open.settings")
        }
    }

    /// The Imp's animations by name. Sleeping and waking may go without one.
    private func animationMenu(_ name: Binding<String>, optional: Bool) -> some View {
        let all = model.prefs.originals(for: imp)
        let shown = name.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return CompactMenu(verbatim: shown.isEmpty ? String(localized: optional ? "triggers.step.anim_none" : "triggers.step.pick_animation") : shown,
                           symbol: "play.circle", maxWidth: Sizing.menuTitle * 1.5) {
            if optional { Button("triggers.step.anim_none") { name.wrappedValue = "" } }
            if all.isEmpty {
                Text("triggers.step.no_animations")
            } else {
                ForEach(all) { a in Button { name.wrappedValue = a.title } label: { Label(a.title, systemImage: a.symbol) } }
            }
        }
    }

    // MARK: Checks

    /// What is missing or off, in plain words. While there is something missing, Save is off.
    private var messages: [String] {
        var out: [String] = []
        if shortcut.trigger.event == .keys, shortcut.hotkey == nil { out.append(String(localized: "triggers.problem.keys")) }
        if shortcut.steps.isEmpty { out.append(String(localized: "triggers.problem.no_steps")) }
        if shortcut.steps.count > Step.maxPerTrigger { out.append(String(localized: "triggers.problem.too_many")) }
        for s in shortcut.steps {
            switch s.act {
            case .ask where !s.isRunnable: out.append(String(localized: "triggers.problem.ask"))
            case .say where !s.isRunnable: out.append(String(localized: "triggers.problem.say"))
            case .play where !s.isRunnable: out.append(String(localized: "triggers.problem.play"))
            case .play, .sleep, .wake:
                if let n = s.animationName, model.prefs.ref(named: n, imp: imp) == nil { out.append(words("triggers.problem.missing", n)) }
            default: break
            }
        }
        var seen = Set<String>()
        return out.filter { seen.insert($0).inserted }
    }

    /// Keys macOS or another of your triggers already uses (only the first in the list runs).
    private var keyWarning: String? {
        guard shortcut.trigger.event == .keys, let hk = shortcut.hotkey else { return nil }
        if model.failedHotkeys.contains(hk) { return String(localized: "\(hk.displayString) is taken by macOS or another app. Pick other keys.") }
        let other = model.prefs.shortcuts.first { $0.id != shortcut.id && $0.keys == hk && $0.isEnabled }
        return other.map { String(localized: "“\($0.displayName)” uses the same keys and comes first, so this one won't go off.") }
    }
}

// MARK: - From an animation

/// An animation to play on an event, by name.
struct AnimationName: Identifiable { let id: String }

extension View {
    /// Opens a new trigger for `imp` that plays the picked animation. Nothing is added until Add.
    func addTriggerSheet(model: AppModel, imp: UUID?, animation: Binding<AnimationName?>) -> some View {
        sheet(item: animation) { picked in
            if let imp {
                var draft = Shortcut(name: "", performer: imp, trigger: .click(1), steps: [Step(.play, value: picked.id)])
                let _ = draft.id = UUID()
                ShortcutSheet(model: model, imp: imp, shortcut: draft, isNew: true, scope: .onlyThisImp,
                              save: { s, target in
                                  var s = s
                                  if s.name.trimmingCharacters(in: .whitespaces).isEmpty { s.name = String(s.trigger.summary.prefix(Shortcut.maxNameLength)) }
                                  if s.trigger.event != .keys { s.hotkey = nil }
                                  model.prefs.saveTrigger(s, for: target)
                                  animation.wrappedValue = nil
                              },
                              duplicate: { _ in }, delete: { animation.wrappedValue = nil })
            }
        }
    }
}

// MARK: - Values

/// What kind of control an event's or a condition's one value needs.
enum ValueKind: Equatable {
    case none, keys, clicks, seconds(default: Int, range: ClosedRange<Int>), minutes(default: Int), percent(default: Int)
    case time, hours, days, app, website
    /// Two words, the value of the first and of the second.
    case choice(Choice)

    enum Choice: Equatable { case plugged, network, asleep }

    init(event: TriggerEvent) {
        switch event {
        case .keys: self = .keys
        case .click: self = .clicks
        case .near: self = .seconds(default: 0, range: Trigger.nearRange)
        case .idle: self = .seconds(default: Trigger.defaultIdleSeconds, range: Trigger.idleRange)
        case .every: self = .minutes(default: 60)
        case .back: self = .minutes(default: 5)
        case .at: self = .time
        case .app: self = .app
        case .website: self = .website
        case .battery: self = .percent(default: 20)
        case .busy: self = .percent(default: 85)
        case .charger: self = .choice(.plugged)
        case .network: self = .choice(.network)
        default: self = .none
        }
    }

    init(state: TriggerState) {
        switch state {
        case .battery: self = .percent(default: 20)
        case .busy: self = .percent(default: 85)
        case .charger: self = .choice(.plugged)
        case .network: self = .choice(.network)
        case .asleep: self = .choice(.asleep)
        case .app: self = .app
        case .website: self = .website
        case .hours: self = .hours
        case .days: self = .days
        case .hot: self = .none
        }
    }
}

/// The control for one value, as text in and out: the keys, clicks, a length of time, a percentage,
/// a time of day, an app, a website, hours, days, or one of two words.
struct ValueControl: View {
    let kind: ValueKind
    @Binding var value: String?
    @Binding var hotkey: Hotkey?
    var asCondition = false

    var body: some View {
        switch kind {
        case .none: EmptyView()
        case .keys: HotkeyField(hotkey: $hotkey)
        case .clicks:
            ImpSegmented("triggers.v.clicks", selection: Binding(get: { Trigger(.click, value: value).clicks }, set: { value = String($0) }),
                         options: Array(1...Trigger.maxClicks), title: { String($0) }, symbol: { "\($0).circle" }, fills: false)
        case .seconds(let d, let range):
            let n = Self.read(value, d, range)
            ImpStepper(value: Binding(get: { n }, set: { value = String($0) }), in: range, step: Self.step(n)) {
                Text(verbatim: n == 0 ? String(localized: "triggers.v.at_once") : Trigger.seconds(n))
            }
            .fixedSize()
        case .minutes(let d):
            let n = Self.read(value, d, 1...1440)
            ImpStepper(value: Binding(get: { n }, set: { value = String($0) }), in: 1...1440, step: n >= 60 ? 15 : 5) {
                Text(verbatim: Trigger.seconds(n * 60))
            }
            .fixedSize()
        case .percent(let d):
            let n = Self.read(value, d, 1...99)
            ImpStepper(value: Binding(get: { n }, set: { value = String($0) }), in: 1...99, step: 5) { Text(verbatim: "\(n) %") }
                .fixedSize()
        case .time:
            ImpTimeField(time: Self.date(Binding(get: { Trigger(.at, value: value).minuteOfDay }, set: { value = Trigger.clock($0) })))
        case .hours:
            let w = Condition(.hours, value: value).window
            HStack(spacing: Spacing.tight) {
                ImpTimeField(time: Self.date(Binding(get: { w.from }, set: { value = Trigger.clock($0) + "-" + Trigger.clock(w.to) })))
                Text(verbatim: "–").foregroundStyle(Tone.muted)
                ImpTimeField(time: Self.date(Binding(get: { w.to }, set: { value = Trigger.clock(w.from) + "-" + Trigger.clock($0) })))
            }
        case .days: DaysControl(value: $value)
        case .app:
            HStack(spacing: Spacing.tight) {
                TextField("triggers.v.any_app", text: text).impField().frame(width: Sizing.menuTitle)
                HoverIconMenu(systemName: "chevron.down", help: "triggers.v.pick_app") {
                    ForEach(Self.runningApps, id: \.self) { name in Button(name) { value = name } }
                }
            }
        case .website:
            HStack(spacing: Spacing.snug) {
                TextField(String("amazon.com"), text: text).impField().frame(width: Sizing.menuTitle)
                if !BrowserBridge.shared.isConnected {
                    IssueTip(text: "The browser extension isn't connected. Add it in Tools › Browser.", symbol: "puzzlepiece.extension.fill")
                }
            }
        case .choice(let c):
            let (first, second) = Self.words(c, asCondition)
            ImpSegmented("triggers.v.choice", selection: Binding(get: { Self.isFirst(c, value) }, set: { value = $0 ? first.value : second.value }),
                         options: [true, false], title: { $0 ? first.title : second.title }, symbol: { $0 ? first.symbol : second.symbol }, fills: false)
        }
    }

    private var text: Binding<String> { Binding(get: { value ?? "" }, set: { value = $0 }) }

    fileprivate static let weekdays = ["mon", "tue", "wed", "thu", "fri", "sat", "sun"]
    private static func read(_ v: String?, _ fallback: Int, _ range: ClosedRange<Int>) -> Int {
        min(max(v.flatMap { Int($0) } ?? fallback, range.lowerBound), range.upperBound)
    }

    private static func step(_ n: Int) -> Int { n < 10 ? 1 : n < 60 ? 5 : n < 600 ? 30 : n < 3600 ? 300 : 1800 }

    /// A time of day (minutes after midnight) as the date the time field edits.
    private static func date(_ minutes: Binding<Int>) -> Binding<Date> {
        Binding(get: { Calendar.current.date(byAdding: .minute, value: minutes.wrappedValue, to: Calendar.current.startOfDay(for: Date())) ?? Date() },
                set: { let c = Calendar.current.dateComponents([.hour, .minute], from: $0); minutes.wrappedValue = (c.hour ?? 0) * 60 + (c.minute ?? 0) })
    }

    private static var runningApps: [String] {
        Array(Set(NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }.compactMap(\.localizedName))).sorted()
    }

    typealias Word = (value: String, title: String, symbol: String)

    private static func words(_ c: ValueKind.Choice, _ asCondition: Bool) -> (Word, Word) {
        switch c {
        case .plugged:
            asCondition ? (("plugged", String(localized: "triggers.v.on_charger"), "powerplug.fill"), ("unplugged", String(localized: "triggers.v.on_battery"), "battery.50"))
                        : (("plugged", String(localized: "triggers.v.plugged"), "powerplug.fill"), ("unplugged", String(localized: "triggers.v.unplugged"), "battery.50"))
        case .network:
            asCondition ? (("offline", String(localized: "triggers.v.offline"), "wifi.slash"), ("online", String(localized: "triggers.v.online"), "wifi"))
                        : (("offline", String(localized: "triggers.v.goes_offline"), "wifi.slash"), ("online", String(localized: "triggers.v.comes_online"), "wifi"))
        case .asleep:
            (("true", String(localized: "triggers.v.asleep"), "moon.zzz.fill"), ("false", String(localized: "triggers.v.awake"), "sun.max.fill"))
        }
    }

    private static func isFirst(_ c: ValueKind.Choice, _ value: String?) -> Bool {
        let v = (value ?? "").trimmingCharacters(in: .whitespaces).lowercased()
        switch c {
        case .plugged: return v != "unplugged"
        case .network: return v != "online"
        case .asleep: return v != "false"
        }
    }
}

/// Seven day buttons, Monday first. At least one stays on.
struct DaysControl: View {
    @Binding var value: String?

    var body: some View {
        let on = Condition(.days, value: value).days
        HStack(spacing: Spacing.hairline) {
            ForEach(0..<7, id: \.self) { d in
                Toggle(Calendar.current.shortWeekdaySymbols[(d + 1) % 7], isOn: Binding(
                    get: { on.contains(d) },
                    set: { isOn in
                        var days = on
                        if isOn { days.insert(d) } else if days.count > 1 { days.remove(d) }
                        value = days.sorted().map { ValueControl.weekdays[$0] }.joined(separator: ",")
                    }))
                .toggleStyle(ImpToggleButtonStyle())
            }
        }
    }
}
