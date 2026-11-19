import ImpDesign
import ImpKit
import SwiftUI

/// A linked device: how it stands and is reached, whether it is Mine and what its asks may use, the Imps of this Mac
/// it holds with the way to call them home, and last Forget.
struct LinkedDevicePage: View {
    let ctx: DeviceContext
    let node: DeviceMap.Node

    var body: some View {
        let peer = ctx.peer(node.id)
        let channel = ctx.map.channels.first { $0.to == node.id }
        StatusLine(symbol: node.state.symbol, tone: node.state.tone,
                   text: ([node.state.word] + (node.state == .offline ? [] : channel.map { [ctx.map.tag(of: $0)] } ?? [])).joined(separator: " · "))
        if let peer {
            SwitchRow(symbol: "person.fill.checkmark", title: String(localized: "Mine"), info: "settings.devices.mine.info",
                      isOn: Binding(get: { peer.isTrusted }, set: { ctx.model.link.setTrusted(peer.id, $0) }))
            DeviceToolLimitsCard(ctx: ctx, peer: peer)
            HeldImpsCard(ctx: ctx, peer: peer)
        }
        if node.state != .connected, !node.addresses.isEmpty {
            PanelSection("devices.reach.last_seen", icon: "wifi") {
                ForEach(node.addresses, id: \.self) { SheetRow($0, symbol: "network", mono: true) }
            }
        }
        if let peer {
            SheetActions { SheetAction(title: "devices.forget.one", symbol: "xmark.circle", role: .destructive) { ctx.forget(peer) } }
        }
    }
}

/// The Imps of this Mac that a device holds, each with Call home, and one for all.
struct HeldImpsCard: View {
    let ctx: DeviceContext
    let peer: DeviceLink.Peer

    var body: some View {
        let held = ctx.model.prefs.imps.filter { peer.imps.contains($0.id) }
        if !held.isEmpty {
            PanelSection("devices.inspector.holds", icon: "house", accessory: {
                if held.count > 1 {
                    HoverIconButton(systemName: "house.fill", help: "devices.call_all_home") { held.forEach { ctx.model.callHome($0.id) } }
                }
            }, content: {
                ForEach(held, id: \.id) { imp in
                    SheetRow(title: imp.name, leading: {
                        Circle().fill(Color.imp(imp.hue)).frame(width: Spacing.cozy, height: Spacing.cozy)
                    }, trailing: {
                        HoverIconButton(systemName: "house", help: "settings.devices.call_home") { ctx.model.callHome(imp.id) }
                    })
                }
            })
        }
    }
}

/// The tools this Mac's Imps may use when a linked device asks them. Only a device marked Mine gets tools at all
/// (`AskOrigin`); this chooses which. The groups are the ones an Imp here uses, the commands tool and each tool
/// server that is on. Nothing is off until it is switched off, and the choice goes with the device when it is
/// forgotten (`DeviceToolLimits`).
struct DeviceToolLimitsCard: View {
    let ctx: DeviceContext
    let peer: DeviceLink.Peer

    private var tools: [ToolSwitch] {
        let prefs = ctx.model.prefs
        func tool(_ id: String, _ symbol: String, _ title: String) -> ToolSwitch {
            ToolSwitch(id: id, symbol: symbol, title: title, isOn: Binding(
                get: { ctx.model.prefs.deviceToolLimits.isAllowed(group: id, on: peer.id) },
                set: { ctx.model.prefs.deviceToolLimits.set($0, group: id, on: peer.id) }))
        }
        var tools = ImpToolGroup.allCases.filter { group in prefs.imps.contains { $0.uses(group) } }
            .map { tool(DeviceToolLimits.groupID($0), $0.symbol, $0.title) }
        if prefs.imps.contains(where: \.usesShell) {
            tools.append(tool(DeviceToolLimits.commands, "terminal.fill", String(localized: "devices.tools.commands")))
        }
        return tools + prefs.mcpServers.filter(\.isEnabled).map { tool(DeviceToolLimits.groupID(server: $0.id), "puzzlepiece.extension.fill", $0.name) }
    }

    var body: some View {
        if !peer.isTrusted {
            SheetRow(title: String(localized: "devices.tools.locked"), leading: { IconTile(systemName: "lock.fill") },
                     trailing: { InfoTip("devices.tools.not_mine") })
        } else if !tools.isEmpty {
            ToolSwitchCard(title: "devices.tools.title", info: "devices.tools.info", tools: tools)
        }
    }
}
