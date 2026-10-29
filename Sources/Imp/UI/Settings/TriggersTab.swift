import ImpKit
import SwiftUI

/// What sets this Imp off, and what it does then: keys you press, clicks on it, or something on
/// your Mac (a low battery, an app, a website, the time…), each with an instruction for its model
/// or something to open. Its own triggers first, then the ones every Imp shares, in one card: each
/// group adds, shares and imports the same way, and a trigger moves between them. An Imp can add
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
        // One card, two groups that work the same way: each can be added to, shared as a kit and
        // filled from a kit. (Two cards with the kit buttons on only one left people wondering what
        // "Shared" was, and how to share or import those.)
        Card("Triggers", icon: "bolt.fill",
             info: "When something happens, the Imp gets your instruction and what happened, then decides what to do. Keys work anywhere on your Mac. You can also ask \(name) to set one up.") {
            HStack(spacing: 8) {
                if copied { StatusText(text: "Kit copied", symbol: "checkmark.circle.fill", color: .green) }
                if model.profile(id)?.isActive == false && !mine.isEmpty {
                    StatusText(text: "Works once \(name) is out", symbol: "moon.zzz.fill", color: Dungeon.ember)
                        .help("\(name)'s own triggers work while it's out on your desktop")
                }
            }
        } content: {
            VStack(alignment: .leading, spacing: 10) {
                group(.own)
                CardDivider().padding(.vertical, 2)
                group(.shared)
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

    // MARK: Groups

    /// This Imp's own triggers, or the ones every Imp answers.
    enum Kind { case own, shared }

    private func items(_ group: Kind) -> [Shortcut] { group == .own ? mine : shared }

    @ViewBuilder private func group(_ group: Kind) -> some View {
        let list = items(group)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: group == .own ? "person.fill" : "person.3.fill")
                    .font(.system(size: 10.5, weight: .semibold)).foregroundStyle(tint)
                    .frame(width: 28, height: 20)
                    .background(Capsule().fill(tint.opacity(0.14)))
                Group {
                    if group == .own { Text("Just \(name)") } else { Text("Every Imp") }
                }
                .font(.system(size: 13, weight: .semibold)).lineLimit(1)
                if !list.isEmpty {
                    Text(verbatim: "\(list.count)").font(.system(size: 11, weight: .semibold)).foregroundStyle(Dungeon.muted)
                }
                if group == .own {
                    InfoTip("Only \(name) answers these, while it's out on your desktop.")
                } else {
                    InfoTip("Every Imp answers these. Clicks go to the Imp you click, everything else to the one you talked to last.")
                }
                Spacer(minLength: 8)
                if !list.isEmpty {
                    ShareKitButton(kit: kit(of: group), help: group == .own ? "Share \(name)'s triggers as a kit" : "Share the triggers every Imp answers as a kit")
                }
                HoverIconButton(systemName: "shippingbox", help: group == .own ? "Import triggers from a kit, for \(name)" : "Import triggers from a kit, for every Imp") {
                    importKit(group)
                }
                Button { start(shared: group == .shared) } label: { Label("Add", systemImage: "plus") }
                    .buttonStyle(.imp(.secondary, small: true))
                    .help(group == .own ? "Add a trigger just for \(name)" : "Add a trigger for every Imp")
            }
            if list.isEmpty {
                Group {
                    if group == .own {
                        StatusText(text: "None yet. Add one, import a kit, or ask \(name).")
                    } else {
                        StatusText(text: "None. Add a click trigger so clicking any Imp does something.")
                    }
                }
                .padding(.leading, 28)
            } else {
                self.list(list)
            }
        }
    }

    private func kit(of group: Kind) -> Kit {
        group == .own
            ? Kit(name: String(localized: "\(name)'s triggers"), triggers: mine)
            : Kit(name: String(localized: "Triggers for every Imp"), triggers: shared)
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
                if shortcut.performer == nil {
                    Button("Move to Just \(name)") { move(shortcut, toShared: false) }
                } else {
                    Button("Move to Every Imp") { move(shortcut, toShared: true) }
                }
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

    private func importKit(_ group: Kind) {
        HomeWindow.shared.router.kitFlow = KitFlow(imp: id, forEveryImp: group == .shared)
    }

    /// Hands a trigger to every Imp, or to this one alone.
    private func move(_ shortcut: Shortcut, toShared: Bool) {
        guard let i = model.prefs.shortcuts.firstIndex(where: { $0.id == shortcut.id }) else { return }
        withAnimation(.snappy(duration: 0.2)) { model.prefs.shortcuts[i].performer = toShared ? nil : id }
    }

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
