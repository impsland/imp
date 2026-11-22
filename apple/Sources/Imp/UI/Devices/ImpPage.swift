import ImpDesign
import ImpKit
import SwiftUI

/// One of this Mac's Imps, in the sheet's header: send it home when it is away, and open its settings.
struct ImpActions: View {
    let ctx: DeviceContext
    let entry: DeviceMap.ImpEntry

    var body: some View {
        if entry.location != ctx.thisMac {
            HeaderAction(symbol: "house.fill", help: LocalizedStringKey(words("imp.a11y.call_home", entry.name))) { ctx.model.callHome(entry.id) }
        }
        HeaderAction(symbol: "gearshape", help: "devices.imp.settings") { ctx.router.openSettings(entry.id) }
    }
}

/// One of this Mac's Imps: where its body is when it is away and its home (it always thinks and acts here), then whom it can
/// message, as chips in one flow, and its tools as switches.
struct ImpPage: View {
    let ctx: DeviceContext
    let entry: DeviceMap.ImpEntry

    private var model: AppModel { ctx.model }

    var body: some View {
        ChipFlow {
            if entry.location != ctx.thisMac {
                ChipButton(device: ctx.symbol(of: entry.location), name: ctx.name(of: entry.location), help: "devices.place.body") {
                    ctx.select(.node(entry.location))
                }
            }
            ChipButton(device: "house.fill", name: ctx.name(of: ctx.thisMac), help: "devices.place.mind") { ctx.select(.node(ctx.thisMac)) }
            ForEach(entry.talksTo) { contact in
                ChipButton(imp: contact, ours: ctx.map.imp(contact.id) != nil, help: "devices.imp.talks") { ctx.select(.imp(contact.id, in: contact.location)) }
            }
        }
        Card("devices.imp.tools", icon: "wrench.and.screwdriver.fill") {
            ToolGrid(items: tools, change: change)
        }
    }

    /// Its tools: its own groups and the tool servers that are on.
    private var tools: [ToolItem] {
        let profile = model.profile(entry.id)
        let groups = ImpToolGroup.allCases.map {
            ToolItem(id: ToolRegistry.ownGroupID($0), symbol: $0.symbol, title: $0.title, on: profile?.uses($0) ?? false)
        }
        let servers = model.prefs.mcpServers.filter(\.isEnabled).map {
            ToolItem(id: DeviceToolLimits.groupID(server: $0.id), symbol: ToolKind.server.symbol, title: $0.name, on: profile?.servers.contains($0.id) ?? false)
        }
        return groups + servers
    }

    /// Switches tools of this Imp the way the Tools page does, so a server that is newly switched on may ask to sign in.
    private func change(_ ids: [String], _ on: Bool) {
        var prefs = model.prefs
        guard let index = prefs.imps.firstIndex(where: { $0.id == entry.id }) else { return }
        for id in ids {
            if let group = ImpToolGroup.allCases.first(where: { ToolRegistry.ownGroupID($0) == id }) {
                prefs.imps[index].setUses(group, on)
            } else if let server = model.prefs.mcpServers.first(where: { DeviceToolLimits.groupID(server: $0.id) == id }) {
                prefs.imps[index].servers.removeAll { $0 == server.id }
                if on { prefs.imps[index].servers.append(server.id) }
            }
        }
        model.changeByPerson(prefs)
    }
}

/// An Imp of another device, in the sheet's header: send it home when it is visiting this Mac.
struct VisitorActions: View {
    let ctx: DeviceContext
    let contact: DeviceMap.Contact

    var body: some View {
        if contact.location == ctx.thisMac {
            HeaderAction(symbol: "house.fill", help: "devices.visitor.send_home") { _ = ctx.model.link.sendHome(visitor: contact.id) }
        }
    }
}

/// An Imp of another device: its home. Where it is now is the pill.
struct VisitorPage: View {
    let ctx: DeviceContext
    let contact: DeviceMap.Contact

    var body: some View {
        if let home = contact.home {
            ChipFlow {
                ChipButton(device: "house.fill", name: ctx.name(of: home), help: "devices.place.mind") { ctx.select(.node(home)) }
            }
        }
    }
}
