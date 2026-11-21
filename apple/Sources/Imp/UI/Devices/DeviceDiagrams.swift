import ImpDesign
import ImpKit
import SwiftUI

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
    /// An Imp: its colour, its name and, when it is on another device than its home, a walking mark. Ours have a way home.
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
