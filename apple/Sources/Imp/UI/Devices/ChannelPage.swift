import ImpDesign
import ImpKit
import SwiftUI

/// A line between this Mac and a device: its two ends (each opens its sheet), the path it takes, and the Hop as a row
/// when it is dashed. How it stands is the pill in the header. Nothing here changes anything: what a device may do is in
/// its own sheet.
struct ChannelPage: View {
    let ctx: DeviceContext
    let channel: DeviceMap.Channel

    var body: some View {
        ForEach([channel.from, channel.to], id: \.self) { end in
            SheetLinkRow(title: ctx.name(of: end), symbol: ctx.symbol(of: end)) { ctx.select(.node(end)) }
        }
        if channel.path == .relay {
            SheetLinkRow(title: channel.address ?? String(localized: "servers.hop.title"), symbol: "arrow.triangle.swap", mono: channel.address != nil,
                         help: "servers.hop.title", trailing: channel.server) { ctx.hop() }
        } else {
            SheetRow(channel.address ?? ctx.map.tag(of: channel), symbol: "wifi", mono: channel.address != nil)
                .help(Text(verbatim: ctx.map.route(of: channel)))
        }
    }
}
