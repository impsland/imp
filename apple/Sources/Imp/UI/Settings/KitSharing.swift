import AppKit
import ImpDesign
import ImpKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Sharing

/// The version of the app that writes a kit (informational: the format version is the kit's own).
enum AppInfo {
    static var version: String? { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String }
}

extension Kit {
    /// With the app's version noted in it, as written to the clipboard or a file.
    var stamped: Kit {
        var kit = self
        if kit.app == nil { kit.app = AppInfo.version }
        return kit
    }
}

/// Copies a kit to the clipboard, as JSON or as an imp:// link when it is short enough to fit in one.
@MainActor
enum KitSharing {
    static func copy(_ kit: Kit) { Pasteboard.write(text: kit.stamped.json()) }
    static func copyLink(_ kit: Kit) { if let link = kit.stamped.link { Pasteboard.write(text: link) } }
}

/// A small share button: copies the kit or a link to it.
/// A tick says a copy worked.
struct ShareKitButton: View {
    let kit: Kit
    let help: LocalizedStringResource
    @State private var copied = false

    var body: some View {
        let linkable = kit.stamped.link != nil
        Menu {
            Button { done(KitSharing.copy(kit)) } label: { Label("Copy kit", systemImage: "shippingbox.fill") }
            Button { done(KitSharing.copyLink(kit)) } label: { Label(linkable ? "Copy link" : "Too long for a link", systemImage: "link") }
                .disabled(!linkable)
        } label: {
            HoverGlyph(systemName: copied ? "checkmark" : "square.and.arrow.up.on.square", tint: copied ? Tone.good : Tone.muted)
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        .help(Text(help))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(help))
    }

    private func done(_ action: @autoclosure () -> Void) {
        action()
        copied = true
        Task { try? await Task.sleep(for: .seconds(Behavior.copiedTickSeconds)); copied = false }
    }
}

// MARK: - Exporting Imps

/// Imps as kits: shared from the clipboard, or saved as a file (a backup, a move to another Mac).
@MainActor
enum ImpExport {
    /// The Imps `ids` with their triggers and tools (and `shared` triggers). Chats are read from
    /// each Imp's history when `chats` is set.
    static func kit(_ ids: Set<UUID>, model: AppModel, name: String, shared: Bool = false, chats: Bool = false) -> Kit {
        var history: [UUID: [Chat]] = [:]
        if chats { for id in ids { history[id] = chatHistory(id, model: model).savedChats() } }
        return Kit.exporting(imps: ids, from: model.prefs, name: name, shared: shared, chats: history).stamped
    }

    static func hasChats(_ ids: Set<UUID>, model: AppModel) -> Bool {
        ids.contains { id in chatHistory(id, model: model).chats.contains { $0.peer == nil } }
    }

    /// An Imp's chats: its live history while the Imp is loaded in the app, else the saved history in its folder.
    /// An Imp at home keeps chats too.
    private static func chatHistory(_ id: UUID, model: AppModel) -> ChatHistory {
        model.imp(id)?.history ?? ChatHistory(folder: ChatHistory.folder(for: id))
    }

    /// Asks where to save, with an "Include chats" tick when there are chats to include.
    static func save(_ ids: Set<UUID>, model: AppModel, name: String, fileName: String, shared: Bool = false) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = fileName + ".json"
        panel.message = String(localized: "Save \(name) as a kit file. Imp reads it back with Import, on this Mac or another. API keys are never saved.")
        panel.canCreateDirectories = true
        let box = NSButton(checkboxWithTitle: String(localized: "Include chats"), target: nil, action: nil)
        if hasChats(ids, model: model) {
            let holder = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 36))
            box.frame = NSRect(x: 20, y: 6, width: 260, height: 24)
            holder.addSubview(box)
            panel.accessoryView = holder
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let kit = kit(ids, model: model, name: name, shared: shared, chats: box.state == .on && panel.accessoryView != nil)
        let text = kit.json()
        do {
            guard text.utf8.count <= Kit.maxFileBytes else {
                throw KitError.download(String(localized: "That's too big to read back (the limit is \(Kit.maxFileBytes / 1_048_576) MB). Export without chats, or a few Imps at a time."))
            }
            try Data(text.utf8).write(to: url, options: .atomic)
        } catch {
            let alert = NSAlert()
            alert.messageText = String(localized: "Couldn't save the file")
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }
}
