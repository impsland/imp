import AppKit
import ImpDesign
import ImpKit
import SwiftUI

extension Shortcut {
    /// What it does: opens something, or asks with the clipboard or the instruction alone.
    var symbol: String {
        if command != .ask { return command.symbol }
        return usesClipboard ? "doc.on.clipboard" : "text.bubble"
    }

    /// One line about what it does.
    var summary: String {
        if command != .ask { return command.title }
        let p = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if p.isEmpty { return usesClipboard ? String(localized: "Responds to what you copied") : String(localized: "Responds in its own way") }
        return p
    }
}

/// Adding or editing a trigger, on a copy: its name, when it goes off (and only if…), what it does,
/// and for whom. Short on words, quick to fill in. Nothing changes until Add or Save. "For" starts on
/// this Imp alone, also for a shared trigger: a change here is this Imp's unless Every Imp is picked.
struct ShortcutSheet: View {
    @Environment(\.impTint) private var tint
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(model: AppModel, imp: UUID, shortcut: Shortcut, isNew: Bool, scope: SettingScope,
         save: @escaping (Shortcut, ScopeTarget) -> Void, duplicate: @escaping (Shortcut) -> Void, delete: @escaping () -> Void) {
        self.model = model; self.imp = imp; self._shortcut = State(initialValue: shortcut); self.isNew = isNew; self.scope = scope
        self.save = save; self.duplicate = duplicate; self.delete = delete
        self._target = State(initialValue: .imp(imp))
    }

    var body: some View {
        SheetScaffold(icon: shortcut.trigger.kind.symbol, title: isNew ? "triggers.new" : "triggers.edit",
                      info: "When it goes off, \(performerName) acts on the instruction with its tools.") {
            HoverIconButton(systemName: "play.fill", help: "Try now", tint: tint) { model.trigger(shortcut, on: model.imp(imp), trying: true) }
                .disabled(!shortcut.isRunnable)
        } content: {
            VStack(alignment: .leading, spacing: Spacing.medium) {
                FieldRow("common.name", info: "triggers.help.name") {
                    TextField("common.name", text: $shortcut.name, prompt: shortcut.suggestedName.map { Text(verbatim: $0) } ?? Text("common.name")).impField()
                }
                FieldRow("When", info: "triggers.help.when") {
                    HStack(spacing: Spacing.small) {
                        kindMenu(selection: shortcut.trigger.kind, kinds: Trigger.Kind.allCases.filter(\.isEvent)) { kind in
                            shortcut.trigger = .starter(kind)
                            if kind.isAmbient { shortcut.usesClipboard = false }
                        }
                        TriggerFields(trigger: $shortcut.trigger, hotkey: $shortcut.hotkey)
                        if let warning = keyWarning { IssueTip(verbatim: warning) }
                        Spacer(minLength: 0)
                    }
                }
                conditions
                FieldRow("Do", info: "triggers.help.do") {
                    CompactMenu(verbatim: shortcut.command.title, symbol: shortcut.command.symbol) {
                        ForEach(Shortcut.Command.allCases) { c in
                            Button { withImpAnimation(ImpDesign.Motion.expand, reduceMotion: reduceMotion) { shortcut.command = c } } label: {
                                Label(c.title, systemImage: c.symbol)
                            }
                        }
                    }
                }
                if shortcut.command.usesAnimation {
                    FieldRow("Animation", info: animationInfo) { animationMenu }
                }
                if shortcut.command == .ask {
                    FieldRow("Input", info: "triggers.help.input") {
                        EvenGrid(minWidth: Sizing.menuTitle, spacing: Spacing.snug) {
                            ChoiceChip(title: "With clipboard", icon: "doc.on.clipboard", picked: shortcut.usesClipboard) {
                                shortcut.usesClipboard = true
                            }
                            .help("Sends what you copied along with your instruction")
                            ChoiceChip(title: "Instruction only", icon: "text.bubble", picked: !shortcut.usesClipboard) {
                                shortcut.usesClipboard = false
                            }
                            .help("Sends your instruction and what happened")
                        }
                    }
                    FieldRow("triggers.instruction", info: "triggers.help.instruction") {
                        EditorWell(text: $shortcut.prompt,
                                   placeholder: shortcut.usesClipboard ? "What should \(performerName) do with it?" : "What should \(performerName) do?",
                                   height: 96)
                    }
                }
                FieldRow("For", info: "triggers.help.for") {
                    VStack(alignment: .leading, spacing: Spacing.snug) {
                        EvenGrid(minWidth: Sizing.menuTitle, spacing: Spacing.snug) {
                            ChoiceChip(title: LocalizedStringKey(words("triggers.scope.just", impName)), icon: SettingScope.onlyThisImp.symbol,
                                       picked: target != .everyImp) {
                                target = .imp(imp)
                            }
                            ChoiceChip(title: "scope.every_imp", icon: SettingScope.everyImp.symbol, picked: target == .everyImp) {
                                target = .everyImp
                            }
                            .help("Clicks go to the Imp you click and everything else to the one you talked to last")
                        }
                        if let note = scopeNote {
                            Text(verbatim: note).font(Typeface.small).foregroundStyle(Tone.muted)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            .padding(Spacing.roomy)
            .impCard(radius: Radius.medium)
        } footer: {
            if !isNew {
                HoverIconButton(systemName: scope == .changed ? "arrow.uturn.backward" : "trash", help: deleteLabel, tint: Tone.danger) { confirmingDelete = true }
                HoverIconButton(systemName: "plus.square.on.square", help: "Duplicate") { duplicate(shortcut) }
            }
            Button(isNew ? "Add" : "Save") { save(shortcut, target) }
                .buttonStyle(.primary)
                .keyboardShortcut(.defaultAction)
                .disabled(!shortcut.isRunnable)
        }
        .confirmationDialog(deleteTitle, isPresented: $confirmingDelete) {
            Button(deleteLabel, role: .destructive) { delete() }
        }
    }

    // MARK: Parts

    /// "Only if…": conditions that must hold when it goes off.
    @ViewBuilder private var conditions: some View {
        let kinds = Trigger.Kind.allCases.filter(\.isCondition)
        FieldRow("Only if", info: "Every condition must be true when it goes off, like the battery being low or the time being late.") {
            VStack(alignment: .leading, spacing: Spacing.snug) {
                ForEach(shortcut.conditions.indices, id: \.self) { i in
                    HStack(spacing: Spacing.small) {
                        kindMenu(selection: shortcut.conditions[i].kind, kinds: kinds, condition: true) { kind in
                            shortcut.conditions[i] = .starter(kind)
                        }
                        TriggerFields(trigger: $shortcut.conditions[i], hotkey: .constant(nil), asCondition: true)
                        Spacer(minLength: 0)
                        HoverIconButton(systemName: "minus.circle", help: "Remove this condition") {
                            withImpAnimation(ImpDesign.Motion.expand, reduceMotion: reduceMotion) { _ = shortcut.conditions.remove(at: i) }
                        }
                    }
                }
                CompactMenu(title: shortcut.conditions.isEmpty ? "Always" : "Add", symbol: shortcut.conditions.isEmpty ? nil : "plus") {
                    ForEach(kinds) { k in
                        Button { withImpAnimation(ImpDesign.Motion.expand, reduceMotion: reduceMotion) { shortcut.conditions.append(.starter(k)) } } label: {
                            Label(k.conditionTitle, systemImage: k.symbol)
                        }
                    }
                }
            }
        }
    }

    private var animationInfo: LocalizedStringKey {
        switch shortcut.command {
        case .sleep: "Plays while it dozes off. It sleeps either way."
        case .wakeUp: "Plays as it wakes up. Without one, it stretches awake the usual way."
        default: "What it plays when this goes off."
        }
    }

    /// The animation a local action plays: none (or the usual wake-up), a built-in one, or one made for this Imp.
    private var animationMenu: some View {
        CompactMenu(verbatim: animationName(shortcut.animation), symbol: "play.circle") {
            Button(shortcut.command == .wakeUp ? "The usual wake-up" : "None") { shortcut.animation = nil }
            let made = model.prefs.originals(for: imp)
            if !made.isEmpty {
                Menu("Made by you") {
                    ForEach(made) { a in Button(a.title) { shortcut.animation = .custom(a.id) } }
                }
            }
            ForEach(Reaction.Family.allCases, id: \.self) { family in
                Menu(AnimationsPane.title(family)) {
                    ForEach(Reaction.allCases.filter { $0.family == family }) { r in
                        Button(r.title) { shortcut.animation = .preset(r) }
                    }
                }
            }
        }
    }

    private func animationName(_ ref: AnimationRef?) -> String {
        switch ref {
        case .preset(let r): r.title
        case .custom(let id): model.prefs.customAnimation(id, imp: imp)?.title ?? String(localized: "Missing animation")
        case nil: shortcut.command == .wakeUp ? String(localized: "The usual wake-up") : String(localized: "None")
        }
    }

    private func kindMenu(selection: Trigger.Kind, kinds: [Trigger.Kind], condition: Bool = false,
                          pick: @escaping (Trigger.Kind) -> Void) -> some View {
        CompactMenu(verbatim: condition ? selection.conditionTitle : selection.title, symbol: selection.symbol) {
            ForEach(kinds) { k in
                Button { withImpAnimation(ImpDesign.Motion.expand, reduceMotion: reduceMotion) { pick(k) } } label: {
                    Label(condition ? k.conditionTitle : k.title, systemImage: k.symbol)
                }
            }
        }
    }

    private var impName: String {
        model.profile(imp)?.callName ?? ImpProfile.stranger
    }

    private var performerName: String {
        guard target != .everyImp, let name = model.profile(imp)?.name, !name.isEmpty else { return String(localized: "Imp") }
        return name
    }

    /// What saving does to a trigger that exists already, when it isn't plain.
    private var scopeNote: String? {
        switch (scope, target) {
        case (.everyImp, .imp) where !isNew: words("triggers.scope.note_version", impName)
        case (.everyImp, .everyImp) where !isNew, (.changed, .everyImp): words("triggers.scope.note_every")
        default: nil
        }
    }

    /// Delete: this Imp's own trigger, its version (back to the shared one), or a shared one for every Imp.
    private var deleteLabel: LocalizedStringKey {
        switch scope {
        case .onlyThisImp: "Delete"
        case .changed: "triggers.use_shared"
        case .everyImp: "triggers.delete_every"
        }
    }

    private var deleteTitle: String {
        switch scope {
        case .onlyThisImp: String(localized: "Delete “\(shortcut.displayName)”?")
        case .changed: words("triggers.use_shared.title", shortcut.displayName)
        case .everyImp: words("triggers.delete_every.title", shortcut.displayName)
        }
    }

    /// Keys macOS or another of your triggers already uses (only the first in the list runs).
    private var keyWarning: String? {
        guard shortcut.trigger.kind == .keys, let hk = shortcut.hotkey else { return nil }
        if model.failedHotkeys.contains(hk) { return String(localized: "\(hk.displayString) is taken by macOS or another app. Pick other keys.") }
        let other = model.prefs.shortcuts.first { $0.id != shortcut.id && $0.keys == hk && $0.isEnabled }
        return other.map { String(localized: "“\($0.displayName)” uses the same keys and comes first, so this one won't go off.") }
    }
}

/// The values a trigger (or condition) needs: the keys, how many clicks, a percentage, an app,
/// a website, a time… Nothing for the ones that need nothing.
struct TriggerFields: View {
    @Binding var trigger: Trigger
    @Binding var hotkey: Hotkey?
    var asCondition = false

    var body: some View {
        switch trigger.kind {
        case .keys:
            HotkeyField(hotkey: $hotkey)
        case .clicks:
            ImpSegmented("Clicks", selection: Binding(get: { trigger.clicks }, set: { trigger.number = $0 }),
                         options: Array(1...Trigger.maxClicks), title: { String(localized: "\($0) clicks") },
                         symbol: { "\($0).circle" }, fills: false)
        case .battery, .busy:
            ImpStepper(value: number(trigger.kind == .battery ? 20 : 85), in: 5...95, step: 5) {
                (trigger.kind == .battery ? Text("below \(trigger.percent) %") : Text("above \(trigger.percent) %")).monospacedDigit()
            }
            .fixedSize()
        case .charger:
            choice(on: asCondition ? "On the charger" : "Plugged in", onSymbol: "powerplug.fill",
                   off: asCondition ? "On battery" : "Unplugged", offSymbol: "battery.50")
        case .offline:
            choice(on: asCondition ? "Offline" : "Goes away", onSymbol: "wifi.slash",
                   off: asCondition ? "Online" : "Comes back", offSymbol: "wifi")
        case .app:
            HStack(spacing: Spacing.tight) {
                TextField("Any app", text: text).impField().frame(width: Sizing.menuTitle)
                HoverIconMenu(systemName: "chevron.down", help: "Pick an open app") {
                    ForEach(Self.runningApps, id: \.self) { name in Button(name) { trigger.text = name } }
                }
            }
        case .website:
            HStack(spacing: Spacing.snug) {
                TextField(String("amazon.com"), text: text).impField().frame(width: Sizing.menuTitle)
                if !BrowserBridge.shared.isConnected {
                    IssueTip(text: "The browser extension isn't connected. Add it in Tools › Browser.",
                             symbol: "puzzlepiece.extension.fill")
                }
            }
        case .time:
            ImpTimeField(time: time(\.number))
        case .hours:
            HStack(spacing: Spacing.tight) {
                ImpTimeField(time: time(\.number))
                Text(verbatim: "–").foregroundStyle(Tone.muted)
                ImpTimeField(time: time(\.until))
            }
        case .every, .back:
            ImpStepper(value: number(trigger.kind == .every ? 60 : 15), in: 1...1440, step: trigger.minutes >= 60 ? 15 : 5) {
                (trigger.kind == .every ? Text(verbatim: Self.span(trigger.minutes)) : Text("after \(Self.span(trigger.minutes)) away")).monospacedDigit()
            }
            .fixedSize()
        case .idle:
            ImpStepper(value: number(Trigger.defaultIdleSeconds), in: Trigger.idleRange, step: idleStep) {
                Text("after \(Trigger.seconds(trigger.idleSeconds))").monospacedDigit()
            }
            .fixedSize()
        case .wake, .start, .hot, .enter, .leave:
            EmptyView()
        }
    }

    /// Bigger steps for longer waits: 5 seconds under a minute, then 30 seconds, then a minute.
    private var idleStep: Int { trigger.idleSeconds < 60 ? 5 : trigger.idleSeconds < 600 ? 30 : 60 }

    /// One of two values (plugged in or not, offline or not).
    private func choice(on: LocalizedStringResource, onSymbol: String, off: LocalizedStringResource, offSymbol: String) -> some View {
        ImpSegmented("Choice", selection: Binding(get: { trigger.isOn }, set: { trigger.flag = $0 }), options: [true, false],
                     title: { String(localized: $0 ? on : off) }, symbol: { $0 ? onSymbol : offSymbol }, fills: false)
    }

    private func number(_ fallback: Int) -> Binding<Int> {
        Binding(get: { trigger.number ?? fallback }, set: { trigger.number = $0 })
    }

    private var text: Binding<String> { Binding(get: { trigger.text ?? "" }, set: { trigger.text = $0 }) }

    /// Minutes after midnight, as a date today (for the time pickers).
    private func time(_ field: WritableKeyPath<Trigger, Int?>) -> Binding<Date> {
        Binding(get: {
            let m = ((trigger[keyPath: field] ?? 0) % 1440 + 1440) % 1440
            return Calendar.current.date(bySettingHour: m / 60, minute: m % 60, second: 0, of: Date()) ?? Date()
        }, set: { date in
            let c = Calendar.current.dateComponents([.hour, .minute], from: date)
            trigger[keyPath: field] = (c.hour ?? 0) * 60 + (c.minute ?? 0)
        })
    }

    /// "15 min", "1 hr 30 min": a number of minutes, the way the user's language writes it.
    private static func span(_ minutes: Int) -> String {
        Duration.seconds(minutes * 60).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated))
    }

    private static var runningApps: [String] {
        Array(Set(NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }.compactMap(\.localizedName)))
            .filter { $0 != "Imp" }.sorted()
    }
}

extension Trigger.Kind {
    /// What a condition of this kind checks, as a menu title.
    var conditionTitle: String {
        switch self {
        case .battery: String(localized: "Battery")
        case .charger: String(localized: "Power")
        case .app: String(localized: "App in front")
        case .website: String(localized: "Website open")
        case .busy: String(localized: "Processor")
        case .hot: String(localized: "The Mac is hot")
        case .offline: String(localized: "Network")
        case .hours: String(localized: "Time of day")
        default: title
        }
    }
}
