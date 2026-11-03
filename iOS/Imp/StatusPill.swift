import ImpDesign
import ImpKit
import SwiftUI

/// The links at a glance: a dot for each linked device (lit while it is connected). A tap opens the
/// Devices sheet; the plus beside it hatches an Imp on this iPhone.
struct StatusPill: View {
    let hub: LinkHub
    var devices: () -> Void
    var hatch: () -> Void

    var body: some View {
        ZStack {
            Button(action: devices) {
                HStack(spacing: 8) {
                    dots
                    if hub.connectedPeers.contains(where: { hub.viaHop.contains($0.id) }) {
                        Image(systemName: "globe").font(.system(size: 11, weight: .semibold)).foregroundStyle(Dungeon.muted)
                            .accessibilityLabel("Through the internet")
                    }
                    Text(text)
                        .font(.system(.footnote, design: .rounded, weight: .semibold))
                        .foregroundStyle(Dungeon.cream)
                        .lineLimit(1)
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold)).foregroundStyle(Dungeon.muted)
                }
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(.black.opacity(0.3), in: Capsule())
                .overlay(Capsule().strokeBorder(Dungeon.cardEdge))
            }
            .buttonStyle(.plain)
            .accessibilityHint("Opens your devices")
            HStack {
                Spacer()
                Button(action: hatch) {
                    Image(systemName: "plus").font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Dungeon.cream)
                        .frame(width: 32, height: 32)
                        .background(.black.opacity(0.3), in: Circle())
                        .overlay(Circle().strokeBorder(Dungeon.cardEdge))
                        .frame(width: Sizing.hit, height: Sizing.hit)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Hatch an Imp")
            }
            .padding(.trailing, 16)
        }
        .animation(.easeInOut(duration: 0.25), value: hub.connectedPeers)
    }

    /// A dot for each linked device (a few at most): lit while it is connected.
    @ViewBuilder private var dots: some View {
        if hub.links.isEmpty {
            dot(Dungeon.good)
        } else {
            HStack(spacing: 4) {
                ForEach(hub.links.prefix(4)) { link in dot(hub.isConnected(link.id) ? Dungeon.good : Dungeon.flame) }
            }
        }
    }

    private func dot(_ color: Color) -> some View {
        Circle().fill(color).frame(width: 8, height: 8).shadow(color: color.opacity(0.8), radius: 4)
    }

    private var text: String {
        let links = hub.links
        switch links.count {
        case 0: return String(localized: "On this iPhone")
        case 1:
            return hub.isConnected(links[0].id) ? String(localized: "Connected to \(links[0].device.name)")
                : String(localized: "Looking for \(links[0].device.name)…")
        default: return String(localized: "\(links.count) devices")
        }
    }
}
