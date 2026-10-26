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
                    Keycaps(hotkey: action.hotkey, small: true).fixedSize()
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
                .help(action.isEnabled ? "On: its keys work" : "Off: kept, but its keys do nothing")
        }
        .padding(.vertical, 3)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension Shortcut {
    /// On the clipboard, or the instruction alone.
    var symbol: String { usesClipboard ? "doc.on.clipboard" : "text.bubble" }

    /// One line about what it does.
    var summary: String {
        let p = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if p.isEmpty { return usesClipboard ? "Responds to what you copied" : "No instruction yet" }
        return p
    }
}

/// A ready-made shortcut to start from.
struct ShortcutIdea: Identifiable {
    let name: String
    let icon: String
    let prompt: String
    var usesClipboard = true
    var id: String { name }

    static let all: [ShortcutIdea] = [
        ShortcutIdea(name: "Translate", icon: "character.bubble",
                     prompt: "Translate this into English. If it's already English, translate it into Spanish. Reply with the translation only."),
        ShortcutIdea(name: "Fix grammar", icon: "checkmark.seal",
                     prompt: "Fix the spelling and grammar, keeping the meaning and tone. Copy the corrected text to the clipboard and show it."),
        ShortcutIdea(name: "Summarize", icon: "text.alignleft", prompt: "Summarize this in two or three short sentences."),
        ShortcutIdea(name: "Explain", icon: "lightbulb", prompt: "Explain this simply in one short paragraph."),
        ShortcutIdea(name: "Read aloud", icon: "speaker.wave.2", prompt: "Read this aloud, word for word."),
        ShortcutIdea(name: "Plan my day", icon: "sun.max", prompt: "Look at my calendar and reminders for today, if you can, and give me a short plan.",
                     usesClipboard: false),
        ShortcutIdea(name: "Pep talk", icon: "sparkles", prompt: "Give me a one-line pep talk to get going.", usesClipboard: false),
    ]
}

/// Adding or editing a shortcut, on a copy: an idea to start from, name, keys, what goes in,
/// what to do. Short on words, quick to fill in. Nothing changes until Add or Save.
struct ShortcutSheet: View {
    @Environment(\.impTint) private var tint
    let model: AppModel
    @State var shortcut: Shortcut
    let isNew: Bool
    let save: (Shortcut) -> Void
    let duplicate: (Shortcut) -> Void
    let delete: () -> Void
    let close: () -> Void
    @State private var confirmingDelete = false

    var body: some View {
        SheetScaffold(icon: shortcut.symbol, title: isNew ? "New shortcut" : "Edit shortcut",
                      info: "Press the keys anywhere on your Mac and \(performerName) does what the prompt says: with what you copied (text or a picture), or with the prompt alone.") {
            IconButton(icon: "play.fill", help: "Try it now", size: 28) { model.trigger(shortcut) }
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
                FieldRow("Keys") {
                    HStack(spacing: 8) {
                        HotkeyField(hotkey: $shortcut.hotkey)
                        if let warning = keyWarning {
                            StatusText(text: warning, symbol: "exclamationmark.triangle.fill", color: .orange).help(warning)
                        }
                        Spacer(minLength: 0)
                    }
                }
                FieldRow("Input") {
                    EvenGrid(minWidth: 140, spacing: 6) {
                        ChoiceChip(title: "Clipboard + prompt", icon: "doc.on.clipboard", picked: shortcut.usesClipboard) {
                            shortcut.usesClipboard = true
                        }
                        .help("Sends what you copied, with your prompt")
                        ChoiceChip(title: "Prompt only", icon: "text.bubble", picked: !shortcut.usesClipboard) {
                            shortcut.usesClipboard = false
                        }
                        .help("Sends only your prompt")
                    }
                }
                EditorWell(text: $shortcut.prompt,
                           placeholder: shortcut.usesClipboard ? "What should \(performerName) do with it?" : "What should \(performerName) do?",
                           height: 110)
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

    private var performerName: String {
        let name = shortcut.performer.flatMap { model.profile($0)?.name } ?? ""
        return name.isEmpty ? "Imp" : name
    }

    /// Keys macOS or another of your shortcuts already uses (only the first in the list runs).
    private var keyWarning: String? {
        guard let hk = shortcut.hotkey else { return nil }
        if model.failedHotkeys.contains(hk) { return "Taken by macOS or another app" }
        let other = model.prefs.shortcuts.first { $0.id != shortcut.id && $0.hotkey == hk && $0.isEnabled }
        return other.map { "Also used by “\($0.displayName)”" }
    }
}
