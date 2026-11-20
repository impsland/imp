import ImpDesign
import ImpKit
import SwiftUI

/// The Hop's sheet. The Hop is a setting, not a linked thing, so this sheet does not depend on the Hop having a node in
/// the map: it stays open while an address is being chosen. It has the Link popover's card without its title and with
/// its one state beside the address, and the devices reached through it as chips.
struct HopSheet: View {
    let model: AppModel
    let map: DeviceMap
    let swap: (DevicesSheet) -> Void
    /// For design scenes: the choice the card starts on.
    var choice: ServerChoice?

    var body: some View {
        DeviceSheetShell(model: model, icon: "arrow.triangle.swap", title: String(localized: "servers.hop.title")) {
            ServerCard(kind: .hop, text: Binding(get: { model.prefs.hop }, set: { model.prefs.hop = $0 }), choice: choice,
                       hosted: true, link: map.hop?.state ?? .offline)
                .settingAnchor(.devicesHop)
            let through = map.channels.filter { $0.via == DeviceMap.serverID }
            if !through.isEmpty {
                PanelSection("devices.inspector.through_hop", icon: "arrow.triangle.swap") {
                    ChipFlow {
                        ForEach(through) { channel in
                            let device = [channel.from, channel.to].first { $0 != DeviceMap.thisMacID } ?? channel.to
                            ChipButton(device: map.node(device)?.symbol ?? "questionmark", name: map.title(of: device)) {
                                swap(.opening(.node(device)))
                            }
                        }
                    }
                }
            }
        }
    }
}
