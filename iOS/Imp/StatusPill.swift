import ImpKit
import SwiftUI

/// The connection at a glance, and a menu: hatching an Imp, the Imps on the Mac, pairing and unpairing.
struct StatusPill: View {
    let client: LinkClient
    @Binding var confirmUnpair: Bool
    var hatch: () -> Void
    var pair: () -> Void

    var body: some View {
        Menu {
            Button(action: hatch) { Label("Hatch an Imp", systemImage: "plus.circle") }
            if client.pairing == nil {
                Button(action: pair) { Label("Pair with a Mac", systemImage: "macbook.and.iphone") }
            }
            if !client.others.isEmpty {
                Section("On your Mac") {
                    ForEach(client.others) { imp in
                        Label(imp.name, systemImage: "pawprint")
                    }
                }
            }
            if client.pairing != nil {
                Button(role: .destructive) { confirmUnpair = true } label: {
                    Label("Unpair from Mac", systemImage: "link.badge.minus")
                }
            }
        } label: {
            HStack(spacing: 8) {
                Circle().fill(dot).frame(width: 8, height: 8)
                    .shadow(color: dot.opacity(0.8), radius: 4)
                if client.viaHop && client.isConnected {
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
        .animation(.easeInOut(duration: 0.25), value: client.status)
    }

    private var mac: String { client.macName ?? String(localized: "your Mac") }

    private var text: String {
        if client.pairing == nil { return String(localized: "On this iPhone") }
        switch client.status {
        case .connected(let name): return String(localized: "Connected to \(name)")
        case .connecting: return String(localized: "Connecting to \(mac)…")
        case .searching, .unpaired: return String(localized: "Looking for \(mac)…")
        case .unknown: return String(localized: "\(mac) needs pairing again")
        }
    }

    private var dot: Color { client.isConnected || client.pairing == nil ? Dungeon.good : Dungeon.flame }
}
