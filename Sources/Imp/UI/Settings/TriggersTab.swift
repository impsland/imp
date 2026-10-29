import ImpKit
import SwiftUI

/// What sets this Imp off, and what it does then: keys you press, clicks on it, or something on
/// your Mac (a low battery, an app, a website, the time…), each with an instruction for its model
/// or something to open. Its own triggers first, then the ones every Imp shares. An Imp can add
/// and remove triggers itself when you ask it to. New ones start as a draft: nothing is added
/// until you say so.
struct TriggersTab: View {
    @Bindable var model: AppModel
    let id: UUID
    @State private var draft: Draft?
    @State private var deleting: Shortcut?
    @State private var copied = false
    @Environment(\.impTint) private var tint

    /// A trigger being added (`isNew`) or edited: a copy, saved only with Add or Save.
    struct Draft: Identifiable {
        var shortcut: Shortcut
        let isNew: Bool
        var id: UUID { shortcut.id }
    }

    private var name: String { model.profile(id)?.callName ?? ImpProfile.stranger }
    private var mine: [Shortcut] { model.prefs.shortcuts(of: id) }
    private var shared: [Shortcut] { model.prefs.sharedShortcuts }

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.gap) {
            Card("Triggers", icon: "bolt.fill",
                 info: "When something happens, \(name) gets your instruction and what happened, then decides what to do. Keys work anywhere on your Mac. You can also ask \(name) to set one up.") {
                HStack(spacing: 8) {
                    if model.profile(id)?.isActive == false && !mine.isEmpty {
                        StatusText(text: "Works once \(name) is out", symbol: "moon.zzz.fill", color: Dungeon.ember)
                            .help("Triggers work while \(name) is out on your desktop")
                    }
                    if copied { StatusText(text: "Kit copied", symbol: "checkmark.circle.fill", color: .green) }
                    if !(mine + shared).isEmpty {
                        ShareKitButton(kit: Kit(name: String(localized: "\(name)'s triggers"), triggers: mine + shared), help: "Share all triggers as a kit")
                    }
                    Button { importKit() } label: { Label("Import kit…", systemImage: "shippingbox") }
                        .buttonStyle(.imp(.quiet, small: true))
                        .help("Add triggers from a kit")
                    Button { start() } label: { Label("Add", systemImage: "plus") }
                        .buttonStyle(.imp(.secondary, small: true))
                        .help("Add a trigger")
                }
            } content: {
                if mine.isEmpty {
                    StatusText(text: "None yet. Add one or ask \(name).")
                } else {
                    list(mine)
                }
            }
            Card("Shared", icon: "person.3.fill",
                 info: "Triggers every Imp answers. Clicks go to the Imp you click and everything else to the one you talked to last.") {
                Button { start(shared: true) } label: { Label("Add", systemImage: "plus") }
                    .buttonStyle(.imp(.secondary, small: true))
                    .help("Add a trigger for every Imp")
            } content: {
                if shared.isEmpty {
                    StatusText(text: "None. Add a click trigger so clicking an Imp does something.")
                } else {
                    list(shared)
                }
            }
        }
        .sheet(item: $draft) { item in
            ShortcutSheet(model: model, imp: id, shortcut: item.shortcut, isNew: item.isNew,
                          save: { save($0) },
                          duplicate: { duplicate($0) },
                          delete: { remove(item.id) },
                          close: { draft = nil })
                .environment(\.impTint, tint)
                .tint(tint)
        }
        .confirmationDialog("Delete “\(deleting?.displayName ?? "")”?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            presenting: deleting) { shortcut in
            Button("Delete", role: .destructive) { remove(shortcut.id) }
        } message: { _ in
            Text("This can't be undone.")
        }
    }

    // MARK: List

    private func list(_ shortcuts: [Shortcut]) -> some View {
        VStack(spacing: 6) {
            ForEach(shortcuts) { shortcut in
                row(shortcut)
                if shortcut.id != shortcuts.last?.id { CardDivider() }
            }
        }
    }

    @ViewBuilder private func row(_ shortcut: Shortcut) -> some View {
        if let i = model.prefs.shortcuts.firstIndex(where: { $0.id == shortcut.id }) {
            Button { draft = Draft(shortcut: shortcut, isNew: false) } label: {
                HStack {
                    ShortcutRow(action: $model.prefs.shortcuts[i],
                                failed: shortcut.keys.map { model.failedHotkeys.contains($0) } ?? false)
                    Image(systemName: "chevron.right").font(.caption.weight(.bold)).foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .contextMenu {
                Button("Edit…") { draft = Draft(shortcut: shortcut, isNew: false) }
                Button("Try Now") { model.trigger(shortcut, trying: true) }.disabled(!shortcut.isRunnable)
                Button("Duplicate") { duplicate(shortcut) }
                Divider()
                Button("Share as Kit") { share(shortcut) }
                Button("Copy Kit Link") { share(shortcut, link: true) }.disabled(kit(of: shortcut).link == nil)
                Divider()
                Button("Delete…", role: .destructive) { deleting = shortcut }
            }
        }
    }

    // MARK: Changes

    private func start(shared: Bool = false) {
        var s = Shortcut(name: "", prompt: "", usesClipboard: true)
        s.performer = shared ? nil : id
        s.id = UUID()
        draft = Draft(shortcut: s, isNew: true)
    }

    private func save(_ shortcut: Shortcut) {
        var s = shortcut
        if s.name.trimmingCharacters(in: .whitespaces).isEmpty { s.name = s.suggestedName ?? String(localized: "Untitled") }
        if s.trigger.kind != .keys { s.hotkey = nil }
        if s.command != .ask { s.usesClipboard = false }
        if let i = model.prefs.shortcuts.firstIndex(where: { $0.id == s.id }) {
            model.prefs.shortcuts[i] = s
        } else {
            model.prefs.shortcuts.append(s)
        }
        draft = nil
    }

    private func importKit() { HomeWindow.shared.router.kitFlow = KitFlow(imp: id) }

    private func kit(of shortcut: Shortcut) -> Kit { Kit(name: shortcut.displayName, triggers: [shortcut]) }

    private func share(_ shortcut: Shortcut, link: Bool = false) {
        if link { KitSharing.copyLink(kit(of: shortcut)) } else { KitSharing.copy(kit(of: shortcut)) }
        copied = true
        Task { try? await Task.sleep(for: .seconds(1.6)); copied = false }
    }

    private func duplicate(_ shortcut: Shortcut) {
        var copy = shortcut
        copy.id = UUID()
        copy.name = String(localized: "\(shortcut.displayName) copy")
        copy.hotkey = nil                       // two triggers on the same keys would just fight
        draft = Draft(shortcut: copy, isNew: true)
    }

    private func remove(_ shortcutID: UUID) {
        draft = nil
        deleting = nil
        model.prefs.shortcuts.removeAll { $0.id == shortcutID }
    }
}

extension Shortcut {
    var displayName: String { name.trimmingCharacters(in: .whitespaces).isEmpty ? String(localized: "Untitled") : name }

    /// A name from the instruction's first words (or what it opens, or when), for one saved without a
    /// name. Nil when there is nothing to go on yet.
    var suggestedName: String? {
        if command != .ask { return command.title }
        let words = prompt.split(whereSeparator: \.isWhitespace).prefix(4).joined(separator: " ")
        let trimmed = words.trimmingCharacters(in: .punctuationCharacters)
        if !trimmed.isEmpty { return trimmed }
        return trigger.kind == .keys ? nil : trigger.summary
    }
}
