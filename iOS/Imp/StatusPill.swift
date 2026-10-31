import ImpKit
import SwiftUI

/// The links at a glance, and a menu: hatching an Imp, linking another device, forgetting one, and
/// calling home the Imps of this iPhone that other devices hold.
struct StatusPill: View {
    let hub: LinkHub
    let pocket: PocketRuntime
    @Binding var forgetting: LinkDevice?
    var hatch: () -> Void
    var pair: () -> Void

    var body: some View {
        Menu {
            Button(action: hatch) { Label("Hatch an Imp", systemImage: "plus.circle") }
            Button(action: pair) { Label("Link a Device", systemImage: "macbook.and.iphone") }
            if !awayImps.isEmpty {
                Section("Away") {
                    ForEach(awayImps, id: \.id) { imp in
                        Button { hub.callHome(imp.id) } label: { Label("Call \(imp.name) Home", systemImage: "house") }
                    }
                }
            }
            if !hub.links.isEmpty {
                Section("Linked") {
                    ForEach(hub.links) { link in
                        Button(role: .destructive) { forgetting = link.device } label: {
                            Label("Forget \(link.device.name)", systemImage: "link.badge.minus")
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 8) {
                Circle().fill(dot).frame(width: 8, height: 8)
                    .shadow(color: dot.opacity(0.8), radius: 4)
                if hub.connectedPeers.contains(where: { hub.viaHop.contains($0.id) }) {
                    Image(systemName: "globe").font(.system(size: 11, weight: .semibold)).foregroundStyle(Dungeon.muted)
                        .accessibilityLabel("Through the internet")
                }
                Text(text)
                    .font(.system(.footnote, design: .rounded, weight: .semibold))
                    .foregroundStyle(Dungeon.cream)
                    .lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold)).foregroundStyle(Dungeon.muted)
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(.black.opacity(0.3), in: Capsule())
            .overlay(Capsule().strokeBorder(Dungeon.cardEdge))
        }
        .animation(.easeInOut(duration: 0.25), value: hub.connectedPeers)
    }

    /// The Imps of this iPhone that another device holds.
    private var awayImps: [LinkImp] { pocket.looks.filter { hub.away.contains($0.id) } }

    private var text: String {
        let connected = hub.connectedPeers
        if hub.links.isEmpty { return String(localized: "On this iPhone") }
        switch connected.count {
        case 0:
            return hub.links.count == 1 ? String(localized: "Looking for \(hub.links[0].device.name)…") : String(localized: "Looking for your devices…")
        case 1: return String(localized: "Connected to \(connected[0].name)")
        default: return String(localized: "Connected to \(connected.count) devices")
        }
    }

    private var dot: Color { !hub.connectedPeers.isEmpty || hub.links.isEmpty ? Dungeon.good : Dungeon.flame }
}
