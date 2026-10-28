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
                            .help("Only if " + action.conditions.map(\.conditionSummary).joined(separator: ", "))
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
            Toggle("", isOn: $action.isEnabled).labelsHidden().toggleStyle(.switch).controlSize(.mini)
                .fixedSize()
                .help(action.isEnabled ? "On" : "Off: kept, but it doesn't go off")
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
        if p.isEmpty { return usesClipboard ? "Responds to what you copied" : "Responds in its own way" }
        return p
    }
}

/// A ready-made trigger to start from.
struct ShortcutIdea: Identifiable {
    let name: String
    let icon: String
    let prompt: String
    var usesClipboard = true
    var trigger: Trigger = .keys
    var id: String { name }

    var detail: String {
        trigger.kind == .keys ? (usesClipboard ? "Keys + clipboard" : "Keys") : trigger.summary
    }

    var shortcut: Shortcut {
        Shortcut(name: name, prompt: prompt, usesClipboard: usesClipboard, trigger: trigger)
    }

    static let all: [ShortcutIdea] = [
        ShortcutIdea(name: "Translate", icon: "character.bubble",
                     prompt: "Translate this into English. If it's already English, translate it into Spanish. Reply with the translation only."),
        ShortcutIdea(name: "Fix grammar", icon: "checkmark.seal",
                     prompt: "Fix the spelling and grammar, keeping the meaning and tone. Copy the corrected text to the clipboard and show it."),
        ShortcutIdea(name: "Summarize", icon: "text.alignleft", prompt: "Summarize this in two or three short sentences."),
        ShortcutIdea(name: "Read aloud", icon: "speaker.wave.2", prompt: "Read this aloud, word for word."),
        ShortcutIdea(name: "Plan my day", icon: "sun.max", prompt: "Look at my calendar and reminders for today, if you can, and give me a short plan.",
                     usesClipboard: false, trigger: Trigger(.time, number: 9 * 60)),
        ShortcutIdea(name: "Low battery", icon: "battery.25percent",
                     prompt: "The battery is getting low. Tell me in one line, with a worried little animation, and suggest one thing that saves power right now.",
                     usesClipboard: false, trigger: Trigger(.battery, number: 20)),
        ShortcutIdea(name: "Welcome back", icon: "figure.walk.arrival",
                     prompt: "I just came back to my Mac. Greet me warmly in a few words, and act it out.",
                     usesClipboard: false, trigger: Trigger(.back, number: 20)),
        ShortcutIdea(name: "Stretch break", icon: "figure.cooldown",
                     prompt: "Remind me to stand up and stretch, playfully, with a little dance.",
                     usesClipboard: false, trigger: Trigger(.every, number: 60)),
        ShortcutIdea(name: "Busy Mac", icon: "cpu",
                     prompt: "The Mac has been working hard for a while. Check what's open and tell me what's probably to blame.",
                     usesClipboard: false, trigger: Trigger(.busy, number: 85)),
        ShortcutIdea(name: "Shopping guard", icon: "cart",
                     prompt: "I'm trying not to spend money. Hop onto the “Add to Cart” button on the page so I can't click it, and tell me off, playfully.",
                     usesClipboard: false, trigger: Trigger(.website, text: "amazon.com")),
    ]
}

/// Adding or editing a trigger, on a copy: an idea to start from, its name, when it goes off (and
/// only if…), what it does, and for whom. Short on words, quick to fill in. Nothing changes until
/// Add or Save.
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
                      info: "When it goes off, \(performerName) gets the instruction along with what happened, and decides what to do with its tools. Or it just opens something, like a click opening the text box.") {
            IconButton(icon: "play.fill", help: "Try it now", size: 28) { model.trigger(shortcut, trying: true) }
                .disabled(!shortcut.isRunnable)
        } content: {
            VStack(alignment: .leading, spacing: 12) {
                if isNew {
                    EvenGrid(minWidth: 100, spacing: 6) {
                        ForEach(ShortcutIdea.all) { idea in
                            ChoiceChip(title: idea.name, icon: idea.icon, picked: shortcut.prompt == idea.prompt) {
                                withAnimation(.snappy(duration: 0.2)) {
                                    shortcut.name = idea.name
                                    shortcut.prompt = idea.prompt
                                    shortcut.usesClipboard = idea.usesClipboard
                                    shortcut.trigger = idea.trigger
                                    shortcut.command = .ask
                                }
                            }
                            .help(idea.prompt)
                        }
                    }
                    CardDivider()
                }
                FieldRow("Name") {
                    TextField(shortcut.suggestedName == "Untitled" ? "Name" : shortcut.suggestedName, text: $shortcut.name).impField()
                }
                FieldRow("When") {
                    HStack(spacing: 8) {
                        kindMenu(selection: shortcut.trigger.kind, kinds: Trigger.Kind.allCases.filter(\.isEvent)) { kind in
                            shortcut.trigger = .starter(kind)
                            if kind.isAmbient { shortcut.usesClipboard = false }
                        }
                        TriggerFields(trigger: $shortcut.trigger, hotkey: $shortcut.hotkey)
                        if let warning = keyWarning { IssueTip(text: warning) }
                        Spacer(minLength: 0)
                    }
                }
                conditions
                FieldRow("Do") {
                    CompactMenu(title: shortcut.command.title, symbol: shortcut.command.symbol) {
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
                            ChoiceChip(title: "Clipboard + prompt", icon: "doc.on.clipboard", picked: shortcut.usesClipboard) {
                                shortcut.usesClipboard = true
                            }
                            .help("Sends what you copied, with your prompt")
                            ChoiceChip(title: "Prompt only", icon: "text.bubble", picked: !shortcut.usesClipboard) {
                                shortcut.usesClipboard = false
                            }
                            .help("Sends only your prompt (and what happened)")
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
                        .help("Clicks go to the Imp you click, everything else to the one you talked to last")
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
        FieldRow("Only if", info: "Conditions that must all be true at that moment, like “only if the battery is low” or “only between 22:00 and 07:00”.") {
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
        CompactMenu(title: condition ? selection.conditionTitle : selection.title, symbol: selection.symbol, maxWidth: 180) {
            ForEach(kinds) { k in
                Button { withAnimation(.snappy(duration: 0.2)) { pick(k) } } label: {
                    Label(condition ? k.conditionTitle : k.title, systemImage: k.symbol)
                }
            }
        }
    }

    private var impName: String {
        let name = model.profile(imp)?.name ?? ""
        return name.isEmpty ? "this Imp" : name
    }

    private var performerName: String {
        guard let p = shortcut.performer, let name = model.profile(p)?.name, !name.isEmpty else { return "Imp" }
        return name
    }

    /// Keys macOS or another of your shortcuts already uses (only the first in the list runs).
    private var keyWarning: String? {
        guard shortcut.trigger.kind == .keys, let hk = shortcut.hotkey else { return nil }
        if model.failedHotkeys.contains(hk) { return "\(hk.displayString) is taken by macOS or another app. Pick other keys." }
        let other = model.prefs.shortcuts.first { $0.id != shortcut.id && $0.keys == hk && $0.isEnabled }
        return other.map { "“\($0.displayName)” uses the same keys, and it comes first: this one won't go off." }
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
            CompactMenu(title: trigger.clicks == 1 ? "1 click" : "\(trigger.clicks) clicks") {
                ForEach(1...Trigger.maxClicks, id: \.self) { n in Button(n == 1 ? "1 click" : "\(n) clicks") { trigger.number = n } }
            }
        case .battery, .busy:
            Stepper(value: number(trigger.kind == .battery ? 20 : 85), in: 5...95, step: 5) {
                Text("\(trigger.kind == .battery ? "below" : "above") \(trigger.percent) %").monospacedDigit()
            }
            .fixedSize()
        case .charger:
            choice(on: asCondition ? "On the charger" : "Plugged in", off: asCondition ? "On battery" : "Unplugged")
        case .offline:
            choice(on: asCondition ? "Offline" : "Goes away", off: asCondition ? "Online" : "Comes back")
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
                TextField("amazon.com", text: text).impField().frame(width: 150)
                if !BrowserBridge.shared.isConnected {
                    IssueTip(text: "Imps only know which website you're on with the Imp browser extension, and it isn't connected. Add it in Settings › Tools › Browser (Chrome, Arc, Brave or Edge), and keep the browser open.",
                             symbol: "puzzlepiece.extension.fill")
                }
            }
        case .time:
            DatePicker("", selection: time(\.number), displayedComponents: .hourAndMinute).labelsHidden().fixedSize()
        case .hours:
            HStack(spacing: 4) {
                DatePicker("", selection: time(\.number), displayedComponents: .hourAndMinute).labelsHidden().fixedSize()
                Text("–").foregroundStyle(.secondary)
                DatePicker("", selection: time(\.until), displayedComponents: .hourAndMinute).labelsHidden().fixedSize()
            }
        case .every, .back:
            Stepper(value: number(trigger.kind == .every ? 60 : 15), in: 1...1440, step: trigger.minutes >= 60 ? 15 : 5) {
                Text(trigger.kind == .every ? "\(trigger.minutes) min" : "after \(trigger.minutes) min away").monospacedDigit()
            }
            .fixedSize()
        case .wake, .start, .hot:
            EmptyView()
        }
    }

    /// One of two values (plugged in or not, offline or not).
    private func choice(on: String, off: String) -> some View {
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

    private static var runningApps: [String] {
        Array(Set(NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }.compactMap(\.localizedName)))
            .filter { $0 != "Imp" }.sorted()
    }
}

extension Trigger.Kind {
    /// What a condition of this kind checks, as a menu title.
    var conditionTitle: String {
        switch self {
        case .battery: "Battery"
        case .charger: "Power"
        case .app: "App in front"
        case .website: "Website open"
        case .busy: "Processor"
        case .hot: "The Mac is hot"
        case .offline: "Network"
        case .hours: "Time of day"
        default: title
        }
    }
}
