import ImpDesign
import ImpKit
import SwiftUI

/// The top of the main screen, one calm bar: the connection as a compact pill on the leading side
/// (a tap opens Devices) and, as on the Mac, the room's actions as icon buttons on the trailing side:
/// New Imp, Hidden (only while some are hidden, with how many) and Settings. One tap each, no menu.
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
            corner
        }
        // The pill sits `page` from the left; the last button's circle sits as far from the right.
        .padding(.leading, Spacing.page)
        .padding(.trailing, CornerInset.padding(visible: Spacing.page))
        .frame(minHeight: Sizing.hit)
        .impAnimation(ImpDesign.Motion.smooth, value: hub.connectedPeers)
    }

    private var corner: some View {
        HStack(spacing: Spacing.tight) {
            HoverIconButton(systemName: "plus", help: "menu.canvas.new_imp", tint: Tone.muted, action: hatch)
            if hiddenCount > 0 {
                HoverIconButton(systemName: "eye", help: "home.corner.show_hidden", tint: Tone.muted, action: showHidden)
                    .overlay(alignment: .topTrailing) {
                        Text(hiddenCount, format: .number)
                            .font(Typeface.small)
                            .foregroundStyle(OnTint(Color.imp))
                            .padding(.horizontal, Spacing.snug)
                            .background(Capsule().fill(TintFill(Color.imp)))
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                    .accessibilityValue(Text(hiddenCount, format: .number))
                    .transition(.opacity)
            }
            HoverIconButton(systemName: "gearshape", help: "menu.canvas.settings", tint: Tone.muted, action: settings)
        }
        .impAnimation(ImpDesign.Motion.fade, value: hiddenCount > 0)
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
