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
        StatusLine(symbol: away ? "figure.walk.arrival" : "mappin.and.ellipse", tone: away ? Tone.warnText : Tone.good, text: ctx.name(of: entry.location))
        SheetActions {
            if away {
                SheetAction(title: "settings.devices.call_home", symbol: "house") { model.callHome(entry.id) }
                SheetAction(verbatim: ctx.name(of: entry.location), symbol: ctx.symbol(of: entry.location)) { ctx.select(.node(entry.location)) }
            }
            SheetAction(title: "devices.imp.settings", symbol: "gearshape") { ctx.router.openSettings(entry.id) }
        }
        ToolSwitchCard(title: "devices.imp.tools", tools: tools)
        if !entry.talksTo.isEmpty {
            PanelSection("devices.imp.talks", icon: "bubble.left.and.bubble.right.fill", info: "devices.imp.talks.info") {
                ForEach(entry.talksTo) { contact in
                    ImpJumpRow(contact: contact, place: ctx.name(of: contact.location), visitor: ctx.map.imp(contact.id) == nil) {
                        ctx.select(.imp(contact.id, in: contact.location))
                    }
                }
            }
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

/// An Imp of another device: where its body is and where it thinks, and Send home when it is visiting this Mac.
struct VisitorPage: View {
    let ctx: DeviceContext
    let contact: DeviceMap.Contact

    var body: some View {
        PlaceRows(ctx: ctx, on: contact.location, thinksOn: contact.home)
        if contact.location == ctx.thisMac {
            SheetActions {
                SheetAction(title: "devices.visitor.send_home", symbol: "paperplane") { _ = ctx.model.link.sendHome(visitor: contact.id) }
            }
        }
    }
}
