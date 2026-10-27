import AppKit
import ImpKit
import SwiftUI

/// What an Imp can do beyond chatting: run commands on this Mac, and tools it borrows (MCP).
struct ToolsTab: View {
    @Bindable var model: AppModel
    @Binding var imp: ImpProfile
    @State private var editing: Draft?
    @State private var forgetting: MCPServerConfig?
    @Environment(\.impTint) private var tint

    private var name: String { imp.name.isEmpty ? "this Imp" : imp.name }

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.gap) {
            Card("Its own tools", icon: "sparkles",
                 info: "Tools that make \(name) itself: its body, its senses, setting itself up and talking to the other Imps. Its model decides when to use them, so a trigger only has to say what you want.") {
                VStack(spacing: 8) {
                    ForEach(ImpToolGroup.allCases) { group in
                        ownToolRow(group)
                        if group != ImpToolGroup.allCases.last { CardDivider() }
                    }
                }
            }

            browserCard

            Card("Shell", icon: "terminal.fill",
                 info: "\(name) does things by running commands on your Mac: opening apps, reading files, copying, speaking, calling web APIs for pictures or voices. Ask, and it works out how. Commands run with your permissions, without asking first.") {
                HStack(spacing: 6) {
                    HoverIconButton(systemName: "folder", help: "Show \(name)'s folder in Finder: where its commands start, and where pictures you hand it are saved") {
                        let folder = Workspace.directory(for: imp.id)
                        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                        NSWorkspace.shared.open(folder)
                    }
                    Toggle("", isOn: $imp.usesShell).labelsHidden().toggleStyle(.switch).controlSize(.small)
                        .help(imp.usesShell ? "On: \(name) can run commands" : "Off: \(name) only talks")
                }
            } content: {
                EmptyView()
            }

            Card("Borrowed tools", icon: "puzzlepiece.extension.fill",
                 info: "Ready-made tools (MCP servers) for files, notes, the web and more. Every Imp can borrow them; switch on the ones \(name) may use. They start when an Imp that's out needs them.") {
                if model.prefs.mcpServers.isEmpty {
                    StatusText(text: "None yet. Add one below.")
                }
                VStack(spacing: 8) {
                    ForEach(model.prefs.mcpServers) { server in
                        serverRow(server)
                        if server.id != model.prefs.mcpServers.last?.id { CardDivider() }
                    }
                }
            }

            Card("Add a tool", icon: "plus",
                 info: "Pick a ready-made one, or set up your own. In the form, Paste setup fills it in from what an MCP server's page tells you to copy.") {
                EvenGrid(minWidth: 170, spacing: 8) {
                    ForEach(MCPExamples.examples, id: \.server.name) { example in
                        let added = model.prefs.mcpServers.contains { $0.commandLine == example.server.commandLine }
                        AddToolTile(icon: example.icon, title: example.server.name, detail: added ? "Added" : example.blurb,
                                    done: added) {
                            if example.isComplete { add([example.server]) } else { editing = Draft(server: example.server, isNew: true) }
                        }
                    }
                }
                CardDivider()
                EvenGrid(minWidth: 170, spacing: 8) {
                    AddToolTile(icon: "terminal.fill", title: "Local program", detail: "Runs a command on this Mac") {
                        editing = Draft(server: MCPServerConfig(name: "", transport: .stdio), isNew: true)
                    }
                    AddToolTile(icon: "globe", title: "Web server", detail: "Its https:// address") {
                        editing = Draft(server: MCPServerConfig(name: "", transport: .http), isNew: true)
                    }
                }
            }
        }
        .sheet(item: $editing) { draft in
            ServerEditor(draft: draft.server, isNew: draft.isNew, hub: model.assistant.hub) { saved in
                if let i = model.prefs.mcpServers.firstIndex(where: { $0.id == saved.id }) {
                    model.prefs.mcpServers[i] = saved
                } else {
                    add([saved])
                }
            }
        }
        .onChange(of: HomeWindow.shared.router.serverToEdit, initial: true) { _, id in openRequestedServer(id) }
        .confirmationDialog("Remove “\(forgetting?.name ?? "")” for every Imp?", isPresented: Binding(
            get: { forgetting != nil }, set: { if !$0 { forgetting = nil } }), titleVisibility: .visible) {
            Button("Remove", role: .destructive) { if let s = forgetting { model.prefs.removeServer(s.id) } }
        }
    }

    /// An Imp asked the user to fill something in: open that tool's form.
    private func openRequestedServer(_ id: UUID?) {
        guard let id, let server = model.prefs.mcpServers.first(where: { $0.id == id }) else { return }
        HomeWindow.shared.router.serverToEdit = nil
        editing = Draft(server: server, isNew: false)
    }

    private func ownToolRow(_ group: ImpToolGroup) -> some View {
        HStack(spacing: 10) {
            Image(systemName: group.symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(imp.uses(group) ? tint : .secondary)
                .frame(width: 28, height: 28)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(tint.opacity(imp.uses(group) ? 0.16 : 0.05)))
            HStack(spacing: 4) {
                Text(group.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                InfoTip(group.summary)
            }
            Spacer(minLength: 8)
            Toggle("", isOn: Binding(get: { imp.uses(group) }, set: { imp.setUses(group, $0) }))
                .labelsHidden().toggleStyle(.switch).controlSize(.small)
                .help(imp.uses(group) ? "On: \(name) may use these" : "Off")
        }
    }

    /// The browser extension: lets Imps know the page you're on, and sit on things in it.
    private var browserCard: some View {
        let bridge = BrowserBridge.shared
        return Card("Browser", icon: "globe",
                    info: "Add the Imp extension to Chrome, Arc, Brave or Edge, and Imps know which website you're on (for triggers like “on amazon.com”) and can hop onto a button on the page. It talks only to Imp on this Mac, and sends only the active tab's address and title, plus what an Imp asks for. To add it: open chrome://extensions, switch on Developer mode, choose Load unpacked, and pick the folder Show opens.") {
            HStack(spacing: 8) {
                if bridge.isConnected {
                    StatusText(text: bridge.page.map { "Connected: \($0.browser)" } ?? "Connected", symbol: "checkmark.circle.fill", color: .green)
                } else {
                    StatusText(text: "Not connected", symbol: "circle.dashed")
                }
                HoverIconButton(systemName: "folder", help: "Show the extension's folder in Finder, to load it in your browser") {
                    ExtensionFolder.reveal()
                }
            }
        } content: {
            EmptyView()
        }
    }

    /// Adds servers to the library and switches them on for this Imp.
    private func add(_ servers: [MCPServerConfig]) {
        var p = model.prefs
        p.mcpServers.append(contentsOf: servers)
        if let i = p.imps.firstIndex(where: { $0.id == imp.id }) { p.imps[i].servers.append(contentsOf: servers.map(\.id)) }
        withAnimation(.snappy(duration: 0.2)) { model.prefs = p }
    }

    private func serverRow(_ server: MCPServerConfig) -> some View {
        let on = imp.servers.contains(server.id)
        return HStack(spacing: 10) {
            Image(systemName: server.transport == .stdio ? "terminal.fill" : "globe")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(on ? tint : .secondary)
                .frame(width: 28, height: 28)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(tint.opacity(on ? 0.16 : 0.05)))
            VStack(alignment: .leading, spacing: 2) {
                Text(server.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                if on {
                    ServerStatus(enabled: imp.isActive, status: model.assistant.toolStatus[server.id])
                } else {
                    StatusText(text: "Not used by \(name)")
                }
            }
            Spacer(minLength: 8)
            HoverIconButton(systemName: "pencil", help: "Edit “\(server.name)”") { editing = Draft(server: server, isNew: false) }
            HoverIconButton(systemName: "trash", help: "Remove “\(server.name)” for every Imp", tint: .red) { forgetting = server }
            Toggle("", isOn: Binding(get: { on }, set: { use in
                if use { imp.servers.append(server.id) } else { imp.servers.removeAll { $0 == server.id } }
            })).labelsHidden().toggleStyle(.switch).controlSize(.small)
                .help(on ? "\(name) may use it" : "Let \(name) use it")
        }
    }

    struct Draft: Identifiable {
        let server: MCPServerConfig
        let isNew: Bool
        var id: UUID { server.id }
    }
}

/// A big, plain button for adding something (a tool, a shortcut).
struct AddToolTile: View {
    let icon: String
    let title: String
    let detail: String
    var done = false
    let action: () -> Void
    @Environment(\.impTint) private var tint
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: done ? "checkmark" : icon)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(done ? Color.secondary : tint)
                    .frame(width: 28, height: 28)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(tint.opacity(done ? 0.05 : 0.16)))
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 13, weight: .semibold, design: .rounded)).lineLimit(1)
                    Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .frame(maxHeight: .infinity)
            .background(RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(Color.white.opacity(hover && !done ? 0.09 : 0.05)))
            .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(Dungeon.cardEdge))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(done)
        .onHover { hover = $0 }
        .animation(.easeOut(duration: 0.12), value: hover)
        .help(detail)
    }
}

/// The browser extension: shipped inside the app (or next to the sources, in a build from them)
/// and copied to Imp's folder in Application Support, where a browser's “Load unpacked” can pick
/// it (it can't look inside an app).
enum ExtensionFolder {
    static func reveal() {
        guard let source else { return }
        let fm = FileManager.default
        let target = URL.applicationSupportDirectory.appendingPathComponent("Imp/Browser Extension")
        try? fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? fm.removeItem(at: target)
        let ready = (try? fm.copyItem(at: source, to: target)) != nil
        NSWorkspace.shared.activateFileViewerSelecting([ready ? target : source])
    }

    private static var source: URL? {
        let bundled = Bundle.main.resourceURL?.appendingPathComponent("Browser Extension")
        if let bundled, FileManager.default.fileExists(atPath: bundled.path) { return bundled }
        // Built from source: Sources/Imp/UI/Settings/ToolsTab.swift → Extensions/Chrome.
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Extensions/Chrome")
        return FileManager.default.fileExists(atPath: source.path) ? source : nil
    }
}
