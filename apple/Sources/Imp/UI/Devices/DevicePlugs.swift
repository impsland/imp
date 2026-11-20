import ImpDesign
import ImpKit
import SwiftUI

/// One capability as a plug: what it is called and pictured as, whether it is plugged in, and whether something
/// outside the board holds it back (a lock). The boards of the sheets are made of these.
struct PlugItem: Identifiable, Equatable {
    var id: String
    var symbol: String
    var title: String
    var plugged: Bool
    var locked = false

    /// The plugs of a device's access, "Talk & files" first. A tool shows as plugged only while the device is trusted,
    /// as that is when the Imps here really have it.
    static func items(of access: DeviceAccess) -> [PlugItem] {
        access.capabilities.map { PlugItem(id: $0.id, symbol: $0.symbol, title: $0.title, plugged: access.isPlugged($0.id)) }
    }
}

/// The plugs of a thing laid out as a socket strip: capabilities as plugs above the outlet, and the ones that are
/// plugged in sit in it. A tap plugs or unplugs, and so does pulling a plug down into the socket or up out of it.
/// The rows are even and full width: a short last row shares the width among its plugs instead of leaving a gap.
/// Without `change` the board only shows (a screen reader still reads each plug's state).
struct PlugBoard: View {
    let items: [PlugItem]
    /// Called with the plug and whether it should now be plugged in.
    var change: ((PlugItem, Bool) -> Void)?

    /// How many plugs fit across before the board makes another row.
    static let columns = 3

    /// How many plugs are in each row: as few rows as the columns allow, balanced (four go two and two).
    static func rowLengths(_ count: Int) -> [Int] { RowBalance.lineLengths(count: count, fit: columns) }

    /// The plugs of each row, in order.
    static func rows(_ items: [PlugItem]) -> [[PlugItem]] {
        var rest = items[...]
        return rowLengths(items.count).map { length in
            defer { rest = rest.dropFirst(length) }
            return Array(rest.prefix(length))
        }
    }

    var body: some View {
        VStack(spacing: Spacing.small) {
            ForEach(Array(Self.rows(items).enumerated()), id: \.offset) { _, row in
                VStack(spacing: 0) {
                    HStack(spacing: Spacing.small) {
                        ForEach(row) { item in PlugView(item: item, change: change).frame(maxWidth: .infinity) }
                    }
                    Socket(plugged: row.map(\.plugged))
                }
            }
        }
        .frame(maxWidth: .infinity)
    }
}

/// The outlet under a row of plugs: a rounded well with a pair of small holes under each plug, which light up when
/// that plug is in.
private struct Socket: View {
    let plugged: [Bool]
    @Environment(\.impTint) private var tint

    var body: some View {
        HStack(spacing: Spacing.small) {
            ForEach(Array(plugged.enumerated()), id: \.offset) { _, on in
                HStack(spacing: Spacing.snug) {
                    ForEach(0..<2, id: \.self) { _ in
                        Capsule().fill(on ? AnyShapeStyle(TintFill(tint)) : AnyShapeStyle(Tone.faint)).frame(width: Spacing.tight, height: Spacing.small)
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
        .frame(height: Spacing.large)
        .background(RoundedRectangle(cornerRadius: Radius.tiny, style: .continuous).fill(Tone.surface))
        .impAnimation(ImpDesign.Motion.quick, value: plugged)
        .accessibilityHidden(true)
    }
}

/// One plug: a body with its picture and short name and two prongs under it. Unplugged it rests above the outlet with
/// its prongs showing, quiet on a card. Plugged it has slid down so the prongs are in the socket, filled with the tint the
/// app's main buttons use, so what is in reads at a glance.
private struct PlugView: View {
    let item: PlugItem
    let change: ((PlugItem, Bool) -> Void)?
    @Environment(\.impTint) private var tint
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pressed = false

    private enum Metrics {
        static let prongWidth: CGFloat = 3
        static let prongGap: CGFloat = 8
        static let pull: CGFloat = 14
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Radius.small, style: .continuous)
        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                // The room the plug has to lift into, so a row is as tall plugged as unplugged.
                Color.clear.frame(height: Sizing.control + Spacing.small)
                VStack(spacing: 0) {
                    plug(shape)
                    prongs.opacity(item.plugged ? 0 : 1)
                }
                .offset(y: item.plugged ? Spacing.small : 0)
                .scaleEffect(pressed && !reduceMotion ? 0.96 : 1)
            }
        }
        .contentShape(Rectangle())
        .impAnimation(ImpDesign.Motion.pop, value: item.plugged)
        .modifier(PlugGestures(item: item, change: change, pressed: $pressed))
        .help(item.title)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: item.title))
        .accessibilityValue(Text(item.plugged ? "devices.plug.on" : "devices.plug.off"))
        .accessibilityAddTraits(change == nil ? [] : [.isButton, .isToggle])
    }

    private func plug(_ shape: RoundedRectangle) -> some View {
        HStack(spacing: Spacing.snug) {
            Image(systemName: item.symbol).font(.icon(.small))
            Text(verbatim: item.title).font(Typeface.label).lineLimit(1).truncationMode(.tail)
            if item.locked { Image(systemName: "lock.fill").font(.icon(.tiny)) }
        }
        .foregroundStyle(item.plugged ? AnyShapeStyle(OnTint(tint)) : AnyShapeStyle(Tone.muted))
        .padding(.horizontal, Spacing.small)
        .frame(maxWidth: .infinity)
        .frame(height: Sizing.control)
        .background(shape.fill(item.plugged ? AnyShapeStyle(TintFill(tint)) : AnyShapeStyle(Tone.card)))
        .overlay { if !item.plugged { shape.strokeBorder(Tone.faint, lineWidth: Stroke.hairline) } }
    }

    private var prongs: some View {
        HStack(spacing: Metrics.prongGap) {
            ForEach(0..<2, id: \.self) { _ in
                UnevenRoundedRectangle(bottomLeadingRadius: Radius.tiny / 2, bottomTrailingRadius: Radius.tiny / 2)
                    .fill(Tone.muted).frame(width: Metrics.prongWidth, height: Spacing.small)
            }
        }
        .opacity(Opacity.dimmed)
    }
}

/// Plugging by a tap, and by pulling the plug down into the socket or up out of it.
private struct PlugGestures: ViewModifier {
    let item: PlugItem
    let change: ((PlugItem, Bool) -> Void)?
    @Binding var pressed: Bool

    func body(content: Content) -> some View {
        if let change {
            content
                .onTapGesture { change(item, !item.plugged) }
                .simultaneousGesture(DragGesture(minimumDistance: Spacing.medium)
                    .onChanged { _ in pressed = true }
                    .onEnded { drag in
                        pressed = false
                        let down = drag.translation.height > Spacing.medium
                        let up = drag.translation.height < -Spacing.medium
                        if down && !item.plugged { change(item, true) } else if up && item.plugged { change(item, false) }
                    })
                .pointerStyle(.link)
        } else {
            content
        }
    }
}

/// A board for the access of a linked device to this Mac's Imps: its plugs are the ones in `DeviceAccess`, and
/// a change is written as the trust and the tool limits.
struct DevicePlugBoard: View {
    let model: AppModel
    let peer: DeviceLink.Peer
    var editable = true

    var body: some View {
        let access = DeviceAccess.of(peer: peer.id, trusted: peer.isTrusted, prefs: model.prefs)
        PlugBoard(items: PlugItem.items(of: access), change: editable ? { item, on in apply(access.plugging(item.id, on)) } : nil)
    }

    private func apply(_ next: DeviceAccess) {
        let limits = next.limits(applying: model.prefs.deviceToolLimits, peer: peer.id)
        if limits != model.prefs.deviceToolLimits { model.prefs.deviceToolLimits = limits }
        if next.trusted != peer.isTrusted { model.link.setTrusted(peer.id, next.trusted) }
    }
}
