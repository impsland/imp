import ImpDesign
import ImpKit
import SwiftUI

/// One of this Mac's Imps: where its body is (it always thinks and acts here), what can be done with it, its tools as
/// switches that open from a summary, and whom it can message.
struct ImpPage: View {
    let ctx: DeviceContext
    let entry: DeviceMap.ImpEntry

    private var model: AppModel { ctx.model }

    var body: some View {
        let away = entry.location != ctx.thisMac
        let holder = away ? ctx.peer(entry.location) : nil
        Diagram {
            if away {
                DiagramTile(symbol: ctx.symbol(of: entry.location), name: ctx.name(of: entry.location), caption: "devices.place.body")
                DiagramConnector(symbol: "arrow.right")
                DiagramTile(symbol: ctx.symbol(of: ctx.thisMac), name: ctx.name(of: ctx.thisMac), caption: "devices.place.mind")
            } else {
                DiagramTile(symbol: ctx.symbol(of: ctx.thisMac), name: ctx.name(of: ctx.thisMac), caption: "devices.imp.here")
            }
        }
        if let holder, !entry.tools.isEmpty {
            PanelSection("devices.imp.can_use", icon: "powerplug.fill", info: "devices.imp.can_use.info") {
                PlugBoard(items: entry.tools.map { tool in
                    let allowed = holder.isTrusted && model.prefs.deviceToolLimits.isAllowed(group: tool.id, on: holder.id)
                    return PlugItem(id: tool.id, symbol: tool.symbol, title: tool.title, plugged: allowed, locked: !allowed)
                }, change: { item, _ in
                    // A blocked tool is plugged in on the device's connection, so that is where to go.
                    if item.locked, let line = ctx.connection(to: entry.location) { ctx.select(.channel(line.id)) }
                })
            }
        }
        ToolSwitchCard(title: "devices.imp.tools", tools: tools)
        if !entry.talksTo.isEmpty {
            PanelSection("devices.imp.talks", icon: "bubble.left.and.bubble.right.fill", info: "devices.imp.talks.info") {
                ChipFlow {
                    ForEach(entry.talksTo) { contact in
                        ChipButton(imp: contact, ours: ctx.map.imp(contact.id) != nil) { ctx.select(.imp(contact.id, in: contact.location)) }
                    }
                }
            }
        }
        SheetActions {
            if away { SheetAction(verbatim: words("imp.a11y.call_home", entry.name), symbol: "house") { model.callHome(entry.id) } }
            SheetAction(title: "devices.imp.settings", symbol: "gearshape") { ctx.router.openSettings(entry.id) }
        }
    }

    /// Its tools: its own groups and the tool servers that are on, as switches that act on its settings.
    private var tools: [ToolSwitch] {
        let groups = ImpToolGroup.allCases.map { group in
            ToolSwitch(id: ToolRegistry.ownGroupID(group), symbol: group.symbol, title: group.title, isOn: Binding(
                get: { model.profile(entry.id)?.uses(group) ?? false },
                set: { on in change { $0.setUses(group, on) } }))
        }
        let servers = model.prefs.mcpServers.filter(\.isEnabled).map { server in
            ToolSwitch(id: "mcp.\(server.id.uuidString)", symbol: "puzzlepiece.extension.fill", title: server.name, isOn: Binding(
                get: { model.profile(entry.id)?.servers.contains(server.id) ?? false },
                set: { use in
                    change { imp in
                        if use { if !imp.servers.contains(server.id) { imp.servers.append(server.id) } } else { imp.servers.removeAll { $0 == server.id } }
                    }
                }))
        }
        return groups + servers
    }

    /// Changes this Imp's settings the way the Tools page does, so a server that is newly switched on may ask to sign in.
    private func change(_ edit: (inout ImpProfile) -> Void) {
        var prefs = model.prefs
        guard let index = prefs.imps.firstIndex(where: { $0.id == entry.id }) else { return }
        edit(&prefs.imps[index])
        model.changeByPerson(prefs)
    }
}

/// An Imp of another device: where its body is and where it thinks, what its device can use here (read only: it is
/// plugged on the device's line) and Send home when it is visiting this Mac.
struct VisitorPage: View {
    let ctx: DeviceContext
    let contact: DeviceMap.Contact

    var body: some View {
        let home = contact.home
        Diagram {
            DiagramTile(symbol: ctx.symbol(of: contact.location), name: ctx.name(of: contact.location), caption: "devices.place.body")
            DiagramConnector(symbol: "arrow.right")
            DiagramTile(symbol: home.map { ctx.symbol(of: $0) } ?? "questionmark",
                        name: home.map { ctx.name(of: $0) } ?? String(localized: "devices.unknown_device"), caption: "devices.place.mind")
        }
        if contact.location == ctx.thisMac, let home, let peer = ctx.peer(home) {
            PanelSection("devices.visitor.can_use", icon: "powerplug.fill") {
                DevicePlugBoard(model: ctx.model, peer: peer, editable: false)
            }
        }
        if contact.location == ctx.thisMac {
            SheetActions {
                SheetAction(title: "devices.visitor.send_home", symbol: "paperplane") { _ = ctx.model.link.sendHome(visitor: contact.id) }
            }
        }
    }
}
