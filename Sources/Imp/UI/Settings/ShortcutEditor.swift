import AppKit
import ImpKit
import SwiftUI

struct ShortcutRow: View {
    @Environment(\.impTint) private var tint
    @Binding var action: Shortcut
    let failed: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: action.symbol)
                .foregroundStyle(action.isEnabled ? tint : .secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 3) {
                Text(action.displayName)
                    .lineLimit(1).truncationMode(.tail)
                    .foregroundStyle(action.isEnabled ? .primary : .secondary)
                HStack(spacing: 6) {
                    if action.trigger.kind == .keys {
                        Keycaps(hotkey: action.hotkey, small: true).fixedSize()
                    } else {
                        Label(action.trigger.summary, systemImage: action.trigger.kind.symbol)
                            .font(.caption.weight(.medium)).foregroundStyle(Dungeon.cream.opacity(0.85))
                            .lineLimit(1).fixedSize()
                    }
                    if !action.conditions.isEmpty {
                        Image(systemName: "line.3.horizontal.decrease.circle").font(.caption)
                            .foregroundStyle(.secondary)
                            .help("Only if \(action.conditions.map(\.conditionSummary).joined(separator: ", "))")
                    }
                    if failed { Image(systemName: "exclamationmark.triangle.fill").font(.caption2).foregroundStyle(.orange) }
                    Text(action.summary)
                        .font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.tail)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .clipped()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Toggle(String(""), isOn: $action.isEnabled).labelsHidden().toggleStyle(.switch).controlSize(.mini)
                .fixedSize()
                .help(action.isEnabled ? "On" : "Off. Kept, but it never goes off.")
        }
        .padding(.vertical, 3)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

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
/// and for whom. Short on words, quick to fill in. Nothing changes until Add or Save.
struct ShortcutSheet: View {
    @Environment(\.impTint) private var tint
    let model: AppModel
    /// The Imp whose settings these are.
    let imp: UUID
    @State var shortcut: Shortcut
    let isNew: Bool
    let save: (Shortcut) -> Void
    let duplicate: (Shortcut) -> Void
    let delete: () -> Void
    let close: () -> Void
    @State private var confirmingDelete = false

    var body: some View {
        SheetScaffold(icon: shortcut.trigger.kind.symbol, title: isNew ? "New trigger" : "Edit trigger",
                      info: "When it goes off, \(performerName) gets the instruction and what happened, then decides what to do with its tools. Or it just opens something, like the text box.") {
            IconButton(icon: "play.fill", help: "Try now", size: 28) { model.trigger(shortcut, trying: true) }
                .disabled(!shortcut.isRunnable)
        } content: {
            VStack(alignment: .leading, spacing: 12) {
                FieldRow("Name") {
                    TextField("Name", text: $shortcut.name, prompt: shortcut.suggestedName.map { Text(verbatim: $0) } ?? Text("Name")).impField()
                }
                FieldRow("When") {
                    HStack(spacing: 8) {
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
                FieldRow("Do") {
                    CompactMenu(verbatim: shortcut.command.title, symbol: shortcut.command.symbol) {
                        ForEach(Shortcut.Command.allCases) { c in
                            Button { withAnimation(.snappy(duration: 0.2)) { shortcut.command = c } } label: {
                                Label(c.title, systemImage: c.symbol)
                            }
                        }
                    }
                }
                if shortcut.command == .ask {
                    FieldRow("Input") {
                        EvenGrid(minWidth: 140, spacing: 6) {
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
                    EditorWell(text: $shortcut.prompt,
                               placeholder: shortcut.usesClipboard ? "What should \(performerName) do with it?" : "What should \(performerName) do?",
                               height: 96)
                }
                FieldRow("For") {
                    EvenGrid(minWidth: 140, spacing: 6) {
                        ChoiceChip(title: "Just \(impName)", icon: "person.fill", picked: shortcut.performer != nil) {
                            shortcut.performer = imp
                        }
                        ChoiceChip(title: "Every Imp", icon: "person.3.fill", picked: shortcut.performer == nil) {
                            shortcut.performer = nil
                        }
                        .help("Clicks go to the Imp you click and everything else to the one you talked to last")
                    }
                }
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: Metrics.corner, style: .continuous).fill(Dungeon.card))
            .overlay(RoundedRectangle(cornerRadius: Metrics.corner, style: .continuous).strokeBorder(Dungeon.cardEdge))
        } footer: {
            if !isNew {
                HoverIconButton(systemName: "trash", help: "Delete", tint: .red) { confirmingDelete = true }
                HoverIconButton(systemName: "plus.square.on.square", help: "Duplicate") { duplicate(shortcut) }
            }
            Spacer()
            Button("Cancel", action: close).buttonStyle(.quiet).keyboardShortcut(.cancelAction)
            Button(isNew ? "Add" : "Save") { save(shortcut) }
                .buttonStyle(.primary)
                .keyboardShortcut(.defaultAction)
                .disabled(!shortcut.isRunnable)
        }
        .confirmationDialog("Delete “\(shortcut.displayName)”?", isPresented: $confirmingDelete) {
            Button("Delete", role: .destructive) { delete() }
        }
    }

    // MARK: Parts

    /// "Only if…": conditions that must hold when it goes off.
    @ViewBuilder private var conditions: some View {
        let kinds = Trigger.Kind.allCases.filter(\.isCondition)
        FieldRow("Only if", info: "Every condition must be true when it goes off, like the battery being low or the time being late.") {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(shortcut.conditions.indices, id: \.self) { i in
                    HStack(spacing: 8) {
                        kindMenu(selection: shortcut.conditions[i].kind, kinds: kinds, condition: true) { kind in
                            shortcut.conditions[i] = .starter(kind)
                        }
                        TriggerFields(trigger: $shortcut.conditions[i], hotkey: .constant(nil), asCondition: true)
                        Spacer(minLength: 0)
                        HoverIconButton(systemName: "minus.circle", help: "Remove this condition") {
                            withAnimation(.snappy(duration: 0.2)) { _ = shortcut.conditions.remove(at: i) }
                        }
                    }
                }
                CompactMenu(title: shortcut.conditions.isEmpty ? "Always" : "Add", symbol: shortcut.conditions.isEmpty ? nil : "plus") {
                    ForEach(kinds) { k in
                        Button { withAnimation(.snappy(duration: 0.2)) { shortcut.conditions.append(.starter(k)) } } label: {
                            Label(k.conditionTitle, systemImage: k.symbol)
                        }
                    }
                }
            }
        }
    }

    private func kindMenu(selection: Trigger.Kind, kinds: [Trigger.Kind], condition: Bool = false,
                          pick: @escaping (Trigger.Kind) -> Void) -> some View {
        CompactMenu(verbatim: condition ? selection.conditionTitle : selection.title, symbol: selection.symbol, maxWidth: 180) {
            ForEach(kinds) { k in
                Button { withAnimation(.snappy(duration: 0.2)) { pick(k) } } label: {
                    Label(condition ? k.conditionTitle : k.title, systemImage: k.symbol)
                }
            }
        }
    }

    private var impName: String {
        model.profile(imp)?.callName ?? ImpProfile.stranger
    }

    private var performerName: String {
        guard let p = shortcut.performer, let name = model.profile(p)?.name, !name.isEmpty else { return String(localized: "Imp") }
        return name
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
            CompactMenu(title: "^[\(trigger.clicks) click](inflect: true)") {
                ForEach(1...Trigger.maxClicks, id: \.self) { n in Button("^[\(n) click](inflect: true)") { trigger.number = n } }
            }
        case .battery, .busy:
            Stepper(value: number(trigger.kind == .battery ? 20 : 85), in: 5...95, step: 5) {
                (trigger.kind == .battery ? Text("below \(trigger.percent) %") : Text("above \(trigger.percent) %")).monospacedDigit()
            }
            .fixedSize()
        case .charger:
            choice(on: asCondition ? "On the charger" : "Plugged in",
                   off: asCondition ? "On battery" : "Unplugged")
        case .offline:
            choice(on: asCondition ? "Offline" : "Goes away",
                   off: asCondition ? "Online" : "Comes back")
        case .app:
            HStack(spacing: 4) {
                TextField("Any app", text: text).impField().frame(width: 140)
                Menu {
                    ForEach(Self.runningApps, id: \.self) { name in Button(name) { trigger.text = name } }
                } label: { Image(systemName: "chevron.down") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .help("Pick an open app")
            }
        case .website:
            HStack(spacing: 6) {
                TextField(String("amazon.com"), text: text).impField().frame(width: 150)
                if !BrowserBridge.shared.isConnected {
                    IssueTip(text: "The browser extension isn't connected. Add it in Tools › Browser.",
                             symbol: "puzzlepiece.extension.fill")
                }
            }
        case .time:
            DatePicker(String(""), selection: time(\.number), displayedComponents: .hourAndMinute).labelsHidden().fixedSize()
        case .hours:
            HStack(spacing: 4) {
                DatePicker(String(""), selection: time(\.number), displayedComponents: .hourAndMinute).labelsHidden().fixedSize()
                Text(verbatim: "–").foregroundStyle(.secondary)
                DatePicker(String(""), selection: time(\.until), displayedComponents: .hourAndMinute).labelsHidden().fixedSize()
            }
        case .every, .back:
            Stepper(value: number(trigger.kind == .every ? 60 : 15), in: 1...1440, step: trigger.minutes >= 60 ? 15 : 5) {
                (trigger.kind == .every ? Text(verbatim: Self.span(trigger.minutes)) : Text("after \(Self.span(trigger.minutes)) away")).monospacedDigit()
            }
            .fixedSize()
        case .wake, .start, .hot:
            EmptyView()
        }
    }

    /// One of two values (plugged in or not, offline or not).
    private func choice(on: LocalizedStringKey, off: LocalizedStringKey) -> some View {
        CompactMenu(title: trigger.isOn ? on : off) {
            Button(on) { trigger.flag = true }
            Button(off) { trigger.flag = false }
        }
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
