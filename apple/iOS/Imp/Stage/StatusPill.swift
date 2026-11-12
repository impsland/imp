import ImpDesign
import ImpKit
import SwiftUI

/// The top of the main screen, one calm bar: the connection as a compact pill on the leading side
/// (a tap opens Devices) and one plain icon button on the trailing side that opens the menu.
struct StatusPill: View {
    let hub: LinkHub
    var hiddenCount = 0
    var devices: () -> Void
    var hatch: () -> Void
    var showHidden: () -> Void = {}
    var settings: () -> Void = {}

    var body: some View {
        HStack(spacing: Spacing.medium) {
            pill
            Spacer(minLength: Spacing.medium)
            Menu {
                Button(action: hatch) { Label("menu.canvas.new_imp", systemImage: "plus") }
                Button(action: devices) { Label("menu.canvas.devices", systemImage: "macbook.and.iphone") }
                if hiddenCount > 0 {
                    Button(action: showHidden) { Label(words("menu.canvas.show_hidden", hiddenCount), systemImage: "eye") }
                }
                Button(action: settings) { Label("menu.canvas.settings", systemImage: "gearshape") }
            } label: {
                // No container of its own: the glyph is `Tone.text`, which reads on the surface in both appearances.
                HoverGlyph(systemName: "ellipsis", tint: Tone.text)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("phone.more.label"))
        }
        .padding(.horizontal, Spacing.page)
        .frame(minHeight: Sizing.hit)
        .impAnimation(ImpDesign.Motion.smooth, value: hub.connectedPeers)
    }

    private var pill: some View {
        Button(action: devices) {
            HStack(spacing: Spacing.small) {
                dots
                if hub.connectedPeers.contains(where: { hub.viaHop.contains($0.id) }) {
                    Image(systemName: "globe").font(.icon(.medium, weight: .semibold)).foregroundStyle(Tone.muted)
                        .accessibilityLabel(Text("phone.status.internet"))
                }
                Text(text)
                    .font(Typeface.caption)
                    .foregroundStyle(Tone.text)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .padding(.horizontal, Spacing.cozy).padding(.vertical, Spacing.small)
            .background(Tone.card, in: Capsule())
            .frame(minHeight: Sizing.hit)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint(Text("phone.status.hint"))
    }

    /// A dot for each linked device (a few at most): lit while it is connected.
    @ViewBuilder private var dots: some View {
        if hub.links.isEmpty {
            dot(Tone.good)
        } else {
            HStack(spacing: Spacing.tight) {
                ForEach(hub.links.prefix(4)) { link in dot(hub.isConnected(link.id) ? Tone.good : Tone.accentBright) }
            }
        }
    }

    private func dot(_ color: Color) -> some View {
        Circle().fill(color).frame(width: Sizing.dot, height: Sizing.dot)
    }

    private var text: String {
        let links = hub.links
        switch links.count {
        case 0: return words("phone.status.alone")
        case 1: return hub.isConnected(links[0].id) ? words("phone.status.connected", links[0].device.name) : words("phone.status.looking")
        default: return words("phone.status.devices", links.count)
        }
    }
}
