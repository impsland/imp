import ImpKit
import SwiftUI

/// The connection at a glance, and a menu: the Imps on the Mac, unpairing.
struct StatusPill: View {
    let client: LinkClient
    @Binding var confirmUnpair: Bool

    var body: some View {
        Menu {
            if !client.others.isEmpty {
                Section("On your Mac") {
                    ForEach(client.others) { imp in
                        Label(imp.name, systemImage: "pawprint")
                    }
                }
            }
            Button(role: .destructive) { confirmUnpair = true } label: {
                Label("Unpair from Mac", systemImage: "link.badge.minus")
            }
        } label: {
            HStack(spacing: 8) {
                Circle().fill(dot).frame(width: 8, height: 8)
                    .shadow(color: dot.opacity(0.8), radius: 4)
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
        .animation(.easeInOut(duration: 0.25), value: client.status)
    }

    private var mac: String { client.macName ?? String(localized: "your Mac") }

    private var text: String {
        switch client.status {
        case .connected(let name): String(localized: "Connected to \(name)")
        case .connecting: String(localized: "Connecting to \(mac)…")
        case .searching, .unpaired: String(localized: "Looking for \(mac)…")
        }
    }

    private var dot: Color { client.isConnected ? Dungeon.good : Dungeon.flame }
}
