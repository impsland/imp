import AppKit
import ImpDesign
import ImpKit
import SwiftUI

extension AppModel {
    /// The tools each started MCP server reported, by server.
    var mcpToolNames: [UUID: [String]] {
        var names: [UUID: [String]] = [:]
        for server in prefs.mcpServers {
            if case .ready(_, let list)? = assistant.toolStatus[server.id] { names[server.id] = list }
        }
        return names
    }
}

/// The Imp's tools: the MCP servers it may use, each a group with a switch and "n of m on" that opens
/// to its tools. A tool that is off is never offered to the model: the count and the offer both come
/// from the registry's one filter. The built-in tools live in the sections they belong to.
struct ToolsPanel: View {
    @Bindable var model: AppModel
    @Binding var imp: ImpProfile
    @State private var opened: Set<String> = []
    @State private var editing: Draft?
    @State private var forgetting: MCPServerConfig?
    @State private var adding = false
    @State private var signInProblems: [UUID: String] = [:]
    @Environment(\.impTint) private var tint

    struct Draft: Identifiable {
        let server: MCPServerConfig
        let isNew: Bool
        var id: UUID { server.id }
    }

    private var servers: [MCPServerConfig] { model.prefs.mcpServers }

    var body: some View {
        PanelList("tools.title", icon: "puzzlepiece.extension.fill", info: "tools.help.mcp", accessory: {
            HStack(spacing: Spacing.small) {
                ImportKitButton(imp: imp.id)
                AgentToolsButton(imp: $imp, groups: [.tools])
                Button { adding = true } label: { FitLabel("tools.add", systemImage: "plus") }
                    .buttonStyle(.imp(.secondary, small: true))
            }
        }) {
            if servers.isEmpty {
                EmptyState("tools.empty", symbol: ImpSetting.tools.symbol, fills: true)
            } else {
                let groups = ToolGroups.mcp(for: imp, servers: servers, tools: model.mcpToolNames)
                VStack(spacing: Spacing.snug) {
                    ForEach(groups) { group in
                        groupRow(group)
                    }
                }
            }
        }
        .settingAnchor(.toolsServers)
        .sheet(isPresented: $adding) { AddToolsSheet(model: model, imp: $imp, edit: { editing = $0 }) }
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
            Button("common.remove", role: .destructive) { if let s = forgetting { model.prefs.removeServer(s.id) } }
        }
    }

    // MARK: Groups

    private func groupRow(_ group: ToolGroupState) -> some View {
        let title = title(of: group)
        let isOpen = opened.contains(group.id)
        return VStack(alignment: .leading, spacing: Spacing.small) {
            HStack(spacing: Spacing.cozy) {
                Button { toggleOpen(group.id) } label: {
                    HStack(spacing: Spacing.cozy) {
                        Image(systemName: "chevron.right").font(.icon(.small, weight: .bold)).foregroundStyle(Tone.muted)
                            .rotationEffect(.degrees(isOpen ? 90 : 0)).frame(width: Spacing.medium)
                        IconTile(systemName: symbol(of: group)).opacity(group.isOn ? 1 : Opacity.dimmed)
                        VStack(alignment: .leading, spacing: Spacing.hairline) {
                            Text(verbatim: title).font(Typeface.body).foregroundStyle(Tone.text).lineLimit(2)
                            caption(group)
                        }
                        Spacer(minLength: Spacing.small)
                    }
                    .frame(minHeight: Sizing.control)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(words(isOpen ? "tools.collapse" : "tools.expand", title))
                Toggle(isOn: groupBinding(group)) { Text(verbatim: title) }
                    .labelsHidden().toggleStyle(.impSwitchBare)
                    .accessibilityLabel(words("tools.group_switch", title))
            }
            if isOpen { toolRows(group) }
        }
        .pebble()
        .impAnimation(ImpDesign.Motion.expand, value: isOpen)
    }

    /// One short line under the name: a dot and a word for a server (plus the count), the count for
    /// a built-in group. It truncates rather than wraps, so a narrow window keeps every row one height.
    @ViewBuilder private func caption(_ group: ToolGroupState) -> some View {
        let count = group.isOn && group.total > 0 ? words("tools.group_count", group.on, group.total) : nil
        if case .server(let id) = group.source, let server = servers.first(where: { $0.id == id }) {
            HStack(spacing: Spacing.snug) {
                if group.isOn {
                    let (colour, word) = status(of: server)
                    Circle().fill(colour).frame(width: Spacing.snug, height: Spacing.snug).accessibilityHidden(true)
                    Text([word, count].compactMap { $0 }.joined(separator: " · "))
                } else {
                    Text("tools.group_off")
                }
            }
            .font(Typeface.small).foregroundStyle(Tone.muted).lineLimit(1)
        } else if let count {
            Text(count).font(Typeface.small).foregroundStyle(Tone.muted).lineLimit(1)
        } else {
            Text("tools.group_off").font(Typeface.small).foregroundStyle(Tone.muted).lineLimit(1)
        }
    }

    /// Never the colour alone: the word goes with it.
    private func status(of server: MCPServerConfig) -> (Color, String) {
        switch model.assistant.toolStatus[server.id] {
        case .ready?: (Tone.good, String(localized: "tools.mcp_connected"))
        case .failed?: (Tone.danger, String(localized: "tools.mcp_failed"))
        case .needsSignIn?: (Tone.muted, String(localized: "tools.mcp_needs_signin"))
        default: (Tone.muted, String(localized: "tools.mcp_starting"))
        }
    }

    private func toolRows(_ group: ToolGroupState) -> some View {
        VStack(alignment: .leading, spacing: Spacing.snug) {
            ForEach(group.tools) { tool in
                let name = tool.title.isEmpty ? tool.name : tool.title
                HStack(spacing: Spacing.small) {
                    Text(verbatim: name).font(Typeface.caption).foregroundStyle(Tone.text).lineLimit(2)
                    Spacer(minLength: Spacing.small)
                    Toggle(isOn: Binding(get: { imp.uses(tool: tool.id) }, set: { imp.setUses(tool: tool.id, $0) })) { Text(verbatim: name) }
                        .labelsHidden().toggleStyle(.impSwitchBare)
                        .accessibilityLabel(Text(verbatim: name))
                }
                .frame(minHeight: Sizing.hit)
            }
            if case .server(let id) = group.source, let server = servers.first(where: { $0.id == id }) {
                if group.isOn, case .failed? = model.assistant.toolStatus[server.id] {
                    Text(words("error.tool_failed", server.name)).font(Typeface.small).foregroundStyle(Tone.danger)
                        .fixedSize(horizontal: false, vertical: true)
                }
                serverActions(server)
            }
        }
        .padding(.leading, Spacing.wide)
        .opacity(group.isOn ? 1 : Opacity.disabled)
    }

    private func serverActions(_ server: MCPServerConfig) -> some View {
        HStack(spacing: Spacing.snug) {
            if server.transport == .http { signInButton(server) }
            ShareKitButton(kit: Kit(name: server.name, servers: [server]), help: "Share “\(server.name)” as a kit. Keys are left out.")
            HoverIconButton(systemName: "pencil", help: "Edit “\(server.name)”") { editing = Draft(server: server, isNew: false) }
            HoverIconButton(systemName: "trash", help: "Remove “\(server.name)” for every Imp", tint: Tone.muted) { forgetting = server }
        }
    }

    /// "Sign in" for a server that asks for it, "Sign out" once the person is signed in.
    @ViewBuilder private func signInButton(_ server: MCPServerConfig) -> some View {
        let assistant = model.assistant
        if case .needsSignIn? = assistant.toolStatus[server.id] {
            Button { Task { signInProblems[server.id] = await assistant.signInAndReconnect(server) } } label: { Text("tools.mcp_sign_in") }
                .buttonStyle(.secondary)
        } else if assistant.signedIn.contains(server.id) {
            Button { Task { await assistant.signOut(of: server) } } label: { Text("tools.mcp_sign_out") }
                .buttonStyle(.secondary)
        }
        if let problem = signInProblems[server.id] {
            Text(verbatim: problem).font(Typeface.small).foregroundStyle(Tone.danger)
        }
    }

    // MARK: Pieces

    private func toggleOpen(_ id: String) { if !opened.insert(id).inserted { opened.remove(id) } }

    private func title(of group: ToolGroupState) -> String {
        switch group.source {
        case .own(let g): g.title
        case .server(let id): servers.first { $0.id == id }?.name ?? ""
        }
    }

    private func symbol(of group: ToolGroupState) -> String {
        switch group.source {
        case .own(let g): g.symbol
        case .server(let id): servers.first { $0.id == id }?.transport == .stdio ? "terminal.fill" : "globe"
        }
    }

    private func groupBinding(_ group: ToolGroupState) -> Binding<Bool> {
        switch group.source {
        case .own(let g): Binding(get: { imp.uses(g) }, set: { imp.setUses(g, $0) })
        case .server(let id):
            Binding(get: { imp.servers.contains(id) }, set: { use in
                var p = model.prefs
                guard let i = p.imps.firstIndex(where: { $0.id == imp.id }) else { return }
                if use { if !p.imps[i].servers.contains(id) { p.imps[i].servers.append(id) } } else { p.imps[i].servers.removeAll { $0 == id } }
                model.changeByPerson(p)
            })
        }
    }

    /// An Imp asked the user to fill something in: open that tool's form.
    private func openRequestedServer(_ id: UUID?) {
        guard let id, let server = servers.first(where: { $0.id == id }) else { return }
        HomeWindow.shared.router.serverToEdit = nil
        editing = Draft(server: server, isNew: false)
    }

    /// Adds servers to the library and switches them on for this Imp.
    private func add(_ added: [MCPServerConfig]) {
        var p = model.prefs
        p.mcpServers.append(contentsOf: added)
        if let i = p.imps.firstIndex(where: { $0.id == imp.id }) { p.imps[i].servers.append(contentsOf: added.map(\.id)) }
        model.changeByPerson(p)
    }
}

/// "Add tools": ready-made MCP servers, or a local program or web server of your own.
struct AddToolsSheet: View {
    @Bindable var model: AppModel
    @Binding var imp: ImpProfile
    let edit: (ToolsPanel.Draft) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        SheetScaffold(icon: "wrench.and.screwdriver.fill", title: "tools.add") {
            EvenGrid(minWidth: Self.tileWidth, spacing: Spacing.small) {
                ForEach(MCPExamples.examples, id: \.server.name) { example in
                    let added = model.prefs.mcpServers.contains { $0.commandLine == example.server.commandLine }
                    AddToolTile(icon: example.icon, title: Text(verbatim: example.server.name),
                                detail: added ? Text("Added") : Text(example.blurb), done: added) {
                        if example.isComplete { add(example.server) } else { open(MCPServerConfig(name: example.server.name, transport: example.server.transport), from: example.server) }
                    }
                }
            }
            EvenGrid(minWidth: Self.tileWidth, spacing: Spacing.small) {
                AddToolTile(icon: "terminal.fill", title: Text("Local program"), detail: Text("Runs a command on this Mac")) {
                    open(MCPServerConfig(name: "", transport: .stdio))
                }
                AddToolTile(icon: "globe", title: Text("Web server"), detail: Text("Its https:// address")) {
                    open(MCPServerConfig(name: "", transport: .http))
                }
            }
        } footer: {
            EmptyView()
        }
    }

    private static var tileWidth: CGFloat { Sizing.menuTitle + Spacing.page }

    private func add(_ server: MCPServerConfig) {
        var p = model.prefs
        p.mcpServers.append(server)
        if let i = p.imps.firstIndex(where: { $0.id == imp.id }) { p.imps[i].servers.append(server.id) }
        model.changeByPerson(p)
    }

    private func open(_ server: MCPServerConfig, from example: MCPServerConfig? = nil) {
        dismiss()
        edit(ToolsPanel.Draft(server: example ?? server, isNew: true))
    }
}

/// A big, plain button for adding something (a tool).
struct AddToolTile: View {
    let icon: String
    let title: Text
    let detail: Text
    var done = false
    let action: () -> Void
    @Environment(\.impTint) private var tint
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: Spacing.cozy) {
                IconTile(systemName: done ? "checkmark" : icon).opacity(done ? Opacity.dimmed : 1)
                VStack(alignment: .leading, spacing: Spacing.hairline) {
                    title.font(Typeface.cardTitle).foregroundStyle(Tone.text).lineLimit(1)
                    detail.font(Typeface.small).foregroundStyle(Tone.muted).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Spacing.cozy).padding(.vertical, Spacing.small)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: Radius.tile, style: .continuous)
                .fill(hover && !done ? Tone.cardHover : Tone.card))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(done)
        .onHover { hover = $0 }
        .impAnimation(ImpDesign.Motion.hover, value: hover)
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
        // Built from source: apple/Sources/Imp/UI/Settings/ToolsPanel.swift → extension.
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("extension")
        return FileManager.default.fileExists(atPath: source.path) ? source : nil
    }
}
