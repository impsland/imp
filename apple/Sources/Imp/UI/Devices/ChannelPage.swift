import ImpDesign
import ImpKit
import SwiftUI

/// A line between this Mac and a device: its two ends (each opens its sheet) and the way it goes, as chips in one flow.
/// When it is dashed the way is the Hop, which opens its sheet. How it stands is the pill in the header. Nothing here changes
/// anything: what a device may do is in its own sheet.
struct ChannelPage: View {
    let ctx: DeviceContext
    let channel: DeviceMap.Channel

    var body: some View {
        ChipFlow {
            ForEach([channel.from, channel.to], id: \.self) { end in
                ChipButton(device: ctx.symbol(of: end), name: ctx.name(of: end)) { ctx.select(.node(end)) }
            }
            if channel.path == .relay {
                ChipButton(route: "arrow.triangle.swap", title: channel.address ?? channel.server ?? String(localized: "servers.hop.title"),
                           mono: channel.address != nil, help: "servers.hop.title") { ctx.hop() }
            } else {
                ChipButton(route: "wifi", title: channel.address ?? ctx.map.tag(of: channel), mono: channel.address != nil,
                           help: LocalizedStringKey(ctx.map.route(of: channel)))
            }
        }
    }
}
