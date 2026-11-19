import ImpDesign
import ImpKit
import SwiftUI

/// Every MCP server and the Imps that use it (a dot each): change it in the tool editor, share it as a kit (keys are
/// left out), turn it off. A new one is for no Imp until an Imp's Tools list picks it.
struct SharingTools: View {
    @Bindable var model: AppModel
    @State private var editing: ToolsPanel.Draft?

    var body: some View {
        let listed = model.prefs.sharableServers
        SharingSection("tools.title", symbol: ImpSetting.tools.symbol, info: "sharing.tools.info", add: "tools.add",
                       onAdd: { editing = .init(server: MCPServerConfig(name: "", transport: .http), isNew: true) },
                       count: listed.count, kit: Kit(name: words("tools.title"), servers: listed.map(\.server)),
                       rows: { ForEach(listed) { row($0) } })
        .settingAnchor(.sharingTools)
        .sheet(item: $editing) { draft in
            ServerEditor(draft: draft.server, isNew: draft.isNew, hub: model.assistant.hub) { saved in
                if let i = model.prefs.mcpServers.firstIndex(where: { $0.id == saved.id }) {
                    model.prefs.mcpServers[i] = saved
                } else {
                    model.prefs.mcpServers.append(saved)
                }
            }
        }
    }

    private func row(_ item: SharedServer) -> some View {
        let server = item.server
        return SharingRow(
            title: server.name,
            kit: Kit(name: server.name, servers: [server]),
            isOn: Binding(get: { model.prefs.mcpServers.first { $0.id == server.id }?.isEnabled ?? false },
                          set: { model.prefs.setEnabled($0, server: server.id) }),
            edit: { editing = .init(server: server, isNew: false) },
            leading: { IconTile(systemName: server.transport == .stdio ? "terminal.fill" : "globe") },
            detail: { users(item.users) })
    }

    /// The Imps that use it, as dots in their colours (never the colour alone: each has its name as help and label).
    @ViewBuilder private func users(_ ids: [UUID]) -> some View {
        let imps = ids.compactMap(model.profile)
        if imps.isEmpty {
            Text("sharing.tools.unused").font(Typeface.small).foregroundStyle(Tone.muted).lineLimit(1)
        } else {
            HStack(spacing: Spacing.snug) {
                ForEach(imps) { imp in
                    Circle().fill(Color.imp(imp.hue)).frame(width: Spacing.cozy, height: Spacing.cozy)
                        .help(Text(verbatim: imp.callName))
                        .accessibilityElement().accessibilityLabel(Text(verbatim: imp.callName))
                }
            }
        }
    }
}
