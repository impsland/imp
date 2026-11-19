import ImpDesign
import ImpKit
import SwiftUI

/// When something happens, the Imp does something: each trigger is a sentence, "When <event>, <action>",
/// with a switch and its scope (every Imp, changed for this Imp, or only this Imp, see `SettingScope`).
/// Every change here is for this Imp alone unless Every Imp is picked. Triggers run without a Brain, so
/// they work while the Imp sleeps. New ones start as a draft: nothing is added until you say so.
struct TriggersPanel: View {
    @Bindable var model: AppModel
    @Binding var imp: ImpProfile
    @State private var draft: Draft?
    @State private var deleting: Shortcut?
    @Environment(\.impTint) private var tint
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// A trigger being added (`isNew`) or edited: a copy, saved only with Add or Save.
    struct Draft: Identifiable {
        var shortcut: Shortcut
        let isNew: Bool
        var id: UUID { shortcut.id }
    }

    private var id: UUID { imp.id }
    private var name: String { imp.callName }
    /// This Imp's own triggers first, then the shared ones it has no version of.
    private var all: [Shortcut] { model.prefs.triggers(for: id) }
    private func scope(_ shortcut: Shortcut) -> SettingScope { model.prefs.scope(of: shortcut, for: id) }

    var body: some View {
        PanelList("triggers.title", icon: "bolt.fill", info: "triggers.help.list", accessory: {
            HStack(spacing: Spacing.small) {
                HoverIconButton(systemName: SectionAction.add, help: "New") { start(.click) }
                ImportKitButton(imp: id)
                AgentToolsButton(imp: $imp, groups: [.triggers])
            }
        }) {
            if all.isEmpty {
                EmptyState("triggers.empty", symbol: ImpSetting.triggers.symbol, fills: true)
            } else {
                VStack(spacing: Spacing.snug) {
                    ForEach(all) { shortcut in
                        row(shortcut)
                    }
                }
            }
        }
        .settingAnchor(.triggersList)
        .sheet(item: $draft) { item in
            ShortcutSheet(model: model, imp: id, shortcut: item.shortcut, isNew: item.isNew,
                          scope: item.isNew ? .onlyThisImp : scope(item.shortcut),
                          save: { save($0, for: $1) },
                          duplicate: { duplicate($0) },
                          delete: { remove(item.shortcut) })
                .environment(\.impTint, tint)
                .tint(tint)
        }
        .confirmationDialog(deleteTitle, isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            presenting: deleting) { shortcut in
            Button(scope(shortcut) == .changed ? "triggers.use_shared" : "Delete", role: .destructive) { remove(shortcut) }
        } message: { shortcut in
            Text(scope(shortcut) == .changed ? words("triggers.use_shared.message", name) : String(localized: "This can't be undone."))
        }
    }

    // MARK: Rows

    /// One trigger as a sentence with its switch, an edit button and a delete button.
    @ViewBuilder private func row(_ shortcut: Shortcut) -> some View {
        if model.prefs.shortcuts.contains(where: { $0.id == shortcut.id }) {
            let sentence = shortcut.sentence
            HStack(spacing: Spacing.small) {
                IconTile(systemName: shortcut.symbol).opacity(shortcut.isEnabled ? 1 : Opacity.dimmed)
                Button { draft = Draft(shortcut: shortcut, isNew: false) } label: {
                    VStack(alignment: .leading, spacing: Spacing.hairline) {
                        Text(verbatim: sentence).font(Typeface.body).foregroundStyle(Tone.text)
                            .multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                        ScopeLabel(scope: scope(shortcut), name: name)
                    }
                    .frame(maxWidth: .infinity, minHeight: Sizing.control, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(verbatim: sentence))
                .accessibilityHint(Text("triggers.edit"))
                switch scope(shortcut) {
                case .onlyThisImp: HoverIconButton(systemName: "trash", help: "triggers.delete", tint: Tone.muted) { deleting = shortcut }
                case .changed: HoverIconButton(systemName: "arrow.uturn.backward", help: "triggers.use_shared", tint: Tone.muted) { deleting = shortcut }
                case .everyImp: EmptyView()
                }
                // Looked up by id on every read: an index goes stale the moment a trigger is deleted, and
                // SwiftUI reads the binding once more before the row goes, and an index read there crashed the app.
                Toggle(isOn: Binding(get: { model.prefs.shortcuts.first { $0.id == shortcut.id }?.isEnabled ?? false },
                                     set: { model.prefs.setTrigger(shortcut.id, enabled: $0, for: id) })) { Text(verbatim: sentence) }
                    .labelsHidden().toggleStyle(.impSwitchBare)
                    .accessibilityLabel(words("triggers.switch", sentence))
            }
            .pebble()
            .contextMenu {
                Section {
                    Button("triggers.edit") { draft = Draft(shortcut: shortcut, isNew: false) }
                    Button("Try Now") { model.trigger(shortcut, on: model.imp(id), trying: true) }.disabled(!shortcut.isValid)
                    Button("Duplicate") { duplicate(shortcut) }
                    if shortcut.performer == nil {
                        Button(words("triggers.just_for", name)) { move(shortcut, to: .imp(id)) }
                    } else {
                        Button("triggers.share_every") { move(shortcut, to: .everyImp) }
                    }
                }
                Section {
                    Button("Share as Kit") { share(shortcut) }
                    Button("Copy Kit Link") { share(shortcut, link: true) }.disabled(kit(of: shortcut).link == nil)
                }
                switch scope(shortcut) {
                case .onlyThisImp: Button("triggers.delete", role: .destructive) { deleting = shortcut }
                case .changed: Button("triggers.use_shared", role: .destructive) { deleting = shortcut }
                case .everyImp: Button("triggers.delete_every", role: .destructive) { deleting = shortcut }
                }
            }
        }
    }

    /// Opens a new trigger straight in the editor: an event and no steps yet, so the first thing to do is
    /// pick one from the step tiles.
    private func start(_ event: TriggerEvent) {
        var s = Shortcut(name: "", trigger: .starter(event), steps: [])
        s.performer = id
        s.id = UUID()
        draft = Draft(shortcut: s, isNew: true)
    }

    // MARK: Changes

    /// What the confirmation asks: delete this Imp's own, go back to the shared one, or delete for every Imp.
    private var deleteTitle: String {
        guard let deleting else { return "" }
        switch scope(deleting) {
        case .onlyThisImp: return String(localized: "Delete “\(deleting.displayName)”?")
        case .changed: return words("triggers.use_shared.title", deleting.displayName)
        case .everyImp: return words("triggers.delete_every.title", deleting.displayName)
        }
    }

    private func save(_ shortcut: Shortcut, for target: ScopeTarget) {
        var s = shortcut
        if s.name.trimmingCharacters(in: .whitespaces).isEmpty { s.name = String(s.trigger.summary.prefix(Shortcut.maxNameLength)) }
        if s.trigger.event != .keys { s.hotkey = nil }
        model.prefs.saveTrigger(s, for: target)
        draft = nil
    }

    /// Shares a trigger with every Imp, or makes this Imp's own version of a shared one (the others keep it).
    private func move(_ shortcut: Shortcut, to target: ScopeTarget) {
        withImpAnimation(ImpDesign.Motion.expand, reduceMotion: reduceMotion) { _ = model.prefs.saveTrigger(shortcut, for: target) }
    }

    private func kit(of shortcut: Shortcut) -> Kit { model.prefs.kit(sharing: shortcut, named: shortcut.displayName, imp: id) }

    private func share(_ shortcut: Shortcut, link: Bool = false) {
        if link { KitSharing.copyLink(kit(of: shortcut)) } else { KitSharing.copy(kit(of: shortcut)) }
    }

    private func duplicate(_ shortcut: Shortcut) {
        var copy = shortcut
        copy.id = UUID()
        copy.performer = id
        copy.overrides = nil
        copy.name = String(localized: "\(shortcut.displayName) copy")
        copy.hotkey = nil                       // two triggers on the same keys would just fight
        draft = Draft(shortcut: copy, isNew: true)
    }

    /// This Imp's own one goes, its version of a shared one goes (the shared one applies again), and a
    /// shared one goes for every Imp (only ever asked as such).
    private func remove(_ shortcut: Shortcut) {
        draft = nil
        deleting = nil
        if shortcut.performer == nil { model.prefs.removeSharedTrigger(shortcut.id) } else { model.prefs.removeTrigger(shortcut.id, for: id) }
    }
}

/// Where a trigger or an animation applies, under its title: every Imp, changed for this Imp, or only this Imp.
struct ScopeLabel: View {
    let scope: SettingScope
    let name: String

    var body: some View {
        Label(title, systemImage: scope.symbol)
            .font(Typeface.small).foregroundStyle(Tone.muted).labelStyle(.titleAndIcon).lineLimit(1)
    }

    private var title: String {
        switch scope {
        case .everyImp: words("scope.every_imp")
        case .changed: words("scope.changed", name)
        case .onlyThisImp: words("scope.only", name)
        }
    }
}

extension SettingScope {
    var symbol: String {
        switch self {
        case .everyImp: "person.3.fill"
        case .changed: "pencil"
        case .onlyThisImp: "person.fill"
        }
    }
}

extension Shortcut {
    var displayName: String { name.trimmingCharacters(in: .whitespaces).isEmpty ? String(localized: "Untitled") : name }
}

extension Shortcut {
    /// A trigger as one line: "4 quick clicks · Between 9:00 AM and 6:00 PM → play “Wiggle” · say “Ouch!”".
    var sentence: String { triggerSummary + " → " + summary }
}
