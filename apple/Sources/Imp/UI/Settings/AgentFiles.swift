import AppKit
import ImpDesign
import ImpKit
import ImpCore
import SwiftUI

/// Open or show a file of the shared configuration in the Finder or the person's editor.
enum FileActions {
    static func reveal(_ url: URL) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
    static func open(_ url: URL) { NSWorkspace.shared.open(url) }
}

/// The Imp's agent file (the same file `imp` reads): open it in an editor, or show it in the Finder. The
/// current settings are written first, so the file is what the screen says.
struct AgentFileButtons: View {
    let model: AppModel
    let imp: UUID

    var body: some View {
        HStack(spacing: Spacing.small) {
            HoverIconButton(systemName: "doc.text", help: "agentfile.open") { act(FileActions.open) }
            HoverIconButton(systemName: "folder", help: "agentfile.reveal") { act(FileActions.reveal) }
        }
    }

    private func act(_ action: (URL) -> Void) {
        model.flushSave()
        if let url = model.config?.agentFile(for: imp) { action(url) }
    }
}

/// What `~/.agents` holds for every Imp, read only: each skill with what it is for, and each command as
/// `/name`, with a button that shows its file.
struct LibraryPanel: View {
    let model: AppModel
    @State private var library: ConfigLibrary?

    var body: some View {
        let skills = library?.skills ?? [], commands = library?.commands ?? []
        Group {
            if !skills.isEmpty || !commands.isEmpty {
                PanelList("library.title", icon: "books.vertical.fill", info: "library.help") {
                    VStack(spacing: Spacing.snug) {
                        ForEach(skills, id: \.path) { row("sparkles", $0.name, $0.description, $0.path) }
                        ForEach(commands, id: \.path) { row("slash.circle", "/\($0.name)", $0.description, $0.path) }
                    }
                }
            }
        }
        .task { library = model.config?.library() }
    }

    private func row(_ symbol: String, _ name: String, _ detail: String, _ path: String) -> some View {
        HStack(spacing: Spacing.small) {
            IconTile(systemName: symbol)
            VStack(alignment: .leading, spacing: Spacing.hairline) {
                Text(verbatim: name).font(Typeface.body).foregroundStyle(Tone.text).lineLimit(1).truncationMode(.tail)
                Text(verbatim: detail.isEmpty ? " " : detail).font(Typeface.small).foregroundStyle(Tone.muted).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HoverIconButton(systemName: "folder", help: "library.reveal") { FileActions.reveal(URL(fileURLWithPath: path)) }
        }
        .frame(minHeight: Sizing.control)
        .pebble()
        .help(Text(verbatim: detail))
    }
}
