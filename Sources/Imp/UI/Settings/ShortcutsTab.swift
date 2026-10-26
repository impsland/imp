import ImpKit
import SwiftUI

/// Keyboard shortcuts this Imp answers to: "press these keys, and it does this", with what you
/// copied or with the instruction alone. New ones start as a draft: nothing is added until you say so.
struct ShortcutsTab: View {
    @Bindable var model: AppModel
    let id: UUID
    @State private var draft: Draft?
    @State private var deleting: Shortcut?
    @Environment(\.impTint) private var tint

    /// A shortcut being added (`isNew`) or edited: a copy, saved only with Add or Save.
    struct Draft: Identifiable {
        var shortcut: Shortcut
        let isNew: Bool
        var id: UUID { shortcut.id }
    }

    private var name: String { model.profile(id).map { $0.name.isEmpty ? "this Imp" : $0.name } ?? "this Imp" }
    private var mine: [Shortcut] { model.prefs.shortcuts(of: id) }

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.gap) {
            Card("Shortcuts", icon: "keyboard.fill",
                 info: "Press your keys anywhere on your Mac and \(name) gets to work: on what you copied (text or a picture), or just on your instruction. You don't need one to chat: a click on \(name) opens a text box (⌘V pastes text or a picture), and ⌥-click lets you talk.") {
                HStack(spacing: 8) {
                    if model.profile(id)?.isActive == false && !mine.isEmpty {
                        StatusText(text: "Works once \(name) is out", symbol: "moon.zzz.fill", color: Dungeon.ember)
                            .help("Shortcuts work while \(name) is out on your desktop")
                    }
                    if !mine.isEmpty {
                        Button { start(from: nil) } label: { Label("Add", systemImage: "plus") }
                            .buttonStyle(.imp(.secondary, small: true))
                            .help("Add a shortcut")
                    }
                }
            } content: {
                if mine.isEmpty {
                    emptyState
                } else {
                    VStack(spacing: 6) {
                        ForEach(mine) { shortcut in row(shortcut) }
                    }
                }
            }
        }
        .sheet(item: $draft) { item in
            ShortcutSheet(model: model, shortcut: item.shortcut, isNew: item.isNew,
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
            Text("Its keys stop working. This can't be undone.")
        }
    }

    // MARK: List

    @ViewBuilder private func row(_ shortcut: Shortcut) -> some View {
        if let i = model.prefs.shortcuts.firstIndex(where: { $0.id == shortcut.id }) {
            Button { draft = Draft(shortcut: shortcut, isNew: false) } label: {
                HStack {
                    ShortcutRow(action: $model.prefs.shortcuts[i],
                                failed: shortcut.hotkey.map { model.failedHotkeys.contains($0) } ?? false)
                    Image(systemName: "chevron.right").font(.caption.weight(.bold)).foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .contextMenu {
                Button("Edit…") { draft = Draft(shortcut: shortcut, isNew: false) }
                Button("Run Now") { model.trigger(shortcut) }.disabled(!shortcut.isRunnable)
                Button("Duplicate") { duplicate(shortcut) }
                Divider()
                Button("Delete…", role: .destructive) { deleting = shortcut }
            }
            if shortcut.id != mine.last?.id { CardDivider() }
        }
    }

    /// Nothing yet: ideas to start from, one click each, or a blank one.
    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 10) {
            StatusText(text: "No shortcuts yet. Start from an idea, or from scratch; you'll pick the keys next.")
            EvenGrid(minWidth: 150, spacing: 8) {
                ForEach(ShortcutIdea.all) { idea in
                    AddToolTile(icon: idea.icon, title: idea.name,
                                detail: idea.usesClipboard ? "On what you copy" : "Just the instruction") { start(from: idea) }
                        .help(idea.prompt)
                }
                AddToolTile(icon: "plus", title: "From scratch", detail: "Your own instruction") { start(from: nil) }
            }
        }
    }

    // MARK: Changes

    private func start(from idea: ShortcutIdea?) {
        var s = Shortcut(name: idea?.name ?? "", prompt: idea?.prompt ?? "", performer: id,
                         usesClipboard: idea?.usesClipboard ?? true)
        s.id = UUID()
        draft = Draft(shortcut: s, isNew: true)
    }

    private func save(_ shortcut: Shortcut) {
        var s = shortcut
        if s.name.trimmingCharacters(in: .whitespaces).isEmpty { s.name = s.suggestedName }
        if let i = model.prefs.shortcuts.firstIndex(where: { $0.id == s.id }) {
            model.prefs.shortcuts[i] = s
        } else {
            model.prefs.shortcuts.append(s)
        }
        draft = nil
    }

    private func duplicate(_ shortcut: Shortcut) {
        var copy = shortcut
        copy.id = UUID()
        copy.name = shortcut.displayName + " copy"
        copy.hotkey = nil                       // two shortcuts on the same keys would just fight
        draft = Draft(shortcut: copy, isNew: true)
    }

    private func remove(_ shortcutID: UUID) {
        draft = nil
        deleting = nil
        model.prefs.shortcuts.removeAll { $0.id == shortcutID }
    }
}

extension Shortcut {
    var displayName: String { name.trimmingCharacters(in: .whitespaces).isEmpty ? "Untitled" : name }

    /// A name from the instruction's first words, for one saved without a name.
    var suggestedName: String {
        let words = prompt.split(whereSeparator: \.isWhitespace).prefix(4).joined(separator: " ")
        let trimmed = words.trimmingCharacters(in: .punctuationCharacters)
        return trimmed.isEmpty ? "Untitled" : trimmed
    }
}
