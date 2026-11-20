import ImpDesign
import ImpKit
import SwiftUI

/// A device in a sheet's picture: its symbol and name in a small tile, with an optional word above for what it is
/// to the thing being shown ("On", "Thinks on").
struct DiagramTile: View {
    let symbol: String
    let name: String
    var caption: LocalizedStringKey?

    private enum Metrics {
        static let width: CGFloat = 112
    }

    var body: some View {
        VStack(spacing: Spacing.tight) {
            if let caption { Text(caption).font(Typeface.small).foregroundStyle(Tone.muted).lineLimit(1) }
            VStack(spacing: Spacing.tight) {
                Image(systemName: symbol).font(.icon(.medium)).foregroundStyle(Tone.text)
                Text(verbatim: name).font(Typeface.small).foregroundStyle(Tone.text).lineLimit(2).multilineTextAlignment(.center)
            }
            .padding(.vertical, Spacing.cozy).padding(.horizontal, Spacing.small)
            .frame(width: Metrics.width)
            .background(RoundedRectangle(cornerRadius: Radius.tile, style: .continuous).fill(Tone.cardHover))
        }
        .accessibilityElement(children: .combine)
    }
}

/// The line between two tiles: in the colour of how it stands, dashed when it goes through the Hop, with its glyph (and
/// the Hop's name) in a small pill on the middle of it.
struct DiagramConnector: View {
    let symbol: String
    var tone: Color = Tone.muted
    var dashed = false
    var pill: String?

    private struct Line: Shape {
        func path(in rect: CGRect) -> Path {
            var path = Path()
            path.move(to: CGPoint(x: rect.minX, y: rect.midY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
            return path
        }
    }

    var body: some View {
        ZStack {
            Line().stroke(tone, style: StrokeStyle(lineWidth: Stroke.focus, lineCap: .round,
                                                  dash: dashed ? [Spacing.cozy, Spacing.small] : []))
                .frame(height: Stroke.focus)
            HStack(spacing: Spacing.tight) {
                Image(systemName: symbol).font(.icon(.tiny)).foregroundStyle(tone)
                if let pill { Text(verbatim: pill).font(Typeface.small).foregroundStyle(Tone.text).lineLimit(1).truncationMode(.middle) }
            }
            .padding(.horizontal, Spacing.small).padding(.vertical, Spacing.tight)
            .background(Capsule().fill(Tone.surface))
        }
        .frame(maxWidth: .infinity)
    }
}

/// A picture of what a sheet is about: its tiles joined by connectors, centred, with the connectors taking the room
/// between so the picture fills the card evenly.
struct Diagram<Content: View, Footer: View>: View {
    @ViewBuilder var content: Content
    @ViewBuilder var footer: Footer

    var body: some View {
        VStack(spacing: Spacing.small) {
            HStack(spacing: Spacing.small) { content }
            footer
        }
            .frame(maxWidth: .infinity)
            .padding(Spacing.medium)
            .background(RoundedRectangle(cornerRadius: Radius.large, style: .continuous).fill(Tone.card))
    }
}

extension Diagram where Footer == EmptyView {
    init(@ViewBuilder content: () -> Content) { self.init(content: content, footer: { EmptyView() }) }
}

/// A small pill that opens another sheet: a leading mark, a name and what goes after it. Used for Imps and devices
/// in a list that wraps, so every name is whole.
struct ChipButton<Leading: View>: View {
    let title: String
    var tint: Color?
    var strong = true
    var trailingSymbol: String?
    var trailingHelp: LocalizedStringKey?
    var trailing: (() -> Void)?
    @ViewBuilder var leading: Leading
    let open: () -> Void

    var body: some View {
        HStack(spacing: Spacing.small) {
            Button(action: open) {
                HStack(spacing: Spacing.small) {
                    leading
                    Text(verbatim: title).font(Typeface.label).foregroundStyle(Tone.text).lineLimit(1)
                }
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .pointerStyle(.link)
            if let trailingSymbol, let trailing {
                Button(action: trailing) { Image(systemName: trailingSymbol).font(.icon(.tiny)).foregroundStyle(Tone.muted) }
                    .buttonStyle(.plain).help(Text(trailingHelp ?? ""))
            }
        }
        .padding(.horizontal, Spacing.cozy).padding(.vertical, Spacing.snug)
        .background(Capsule().fill((tint ?? Tone.muted).opacity(tint != nil && strong ? Opacity.tintFillStrong : Opacity.tintFill)))
    }
}

extension ChipButton where Leading == AnyView {
    /// An Imp: its colour, its name and, when it is on another device than its home, a walking mark; ours have a way home.
    init(imp contact: DeviceMap.Contact, ours: Bool, away: Bool = false, arrow: String? = nil,
         home: (() -> Void)? = nil, open: @escaping () -> Void) {
        self.init(title: contact.name, tint: Color.imp(contact.hue), strong: ours, trailingSymbol: home == nil ? nil : "house",
                  trailingHelp: "settings.devices.call_home", trailing: home, leading: {
            AnyView(HStack(spacing: Spacing.tight) {
                Circle().fill(Color.imp(contact.hue)).frame(width: Spacing.cozy, height: Spacing.cozy)
                if let arrow { Image(systemName: arrow).font(.icon(.tiny)).foregroundStyle(Tone.muted) }
                else if away { Image(systemName: "figure.walk").font(.icon(.tiny)).foregroundStyle(Tone.muted) }
            })
        }, open: open)
    }

    /// A device: its picture and name.
    init(device symbol: String, name: String, open: @escaping () -> Void) {
        self.init(title: name, leading: { AnyView(Image(systemName: symbol).font(.icon(.tiny)).foregroundStyle(Tone.muted)) }, open: open)
    }
}

/// Chips that wrap, each as wide as its own name.
struct ChipFlow<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        FlowLayout(spacing: Spacing.small, lineSpacing: Spacing.small) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
