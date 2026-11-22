import ImpDesign
import ImpKit
import SwiftUI

/// A small pill: a leading mark, a name and what goes after it. With `open` it is a button that opens another sheet (an
/// Imp or a device), without it only says something (an address). Used in a list that wraps, so every name is whole.
struct ChipButton<Leading: View>: View {
    let title: String
    var tint: Color?
    var strong = true
    /// An address or another name that is code, not a word.
    var mono = false
    /// What it says when hovered and to a screen reader, when the name alone does not say what it is.
    var help: LocalizedStringKey?
    var trailingSymbol: String?
    var trailingHelp: LocalizedStringKey?
    var trailing: (() -> Void)?
    @ViewBuilder var leading: Leading
    var open: (() -> Void)?

    var body: some View {
        HStack(spacing: Spacing.small) {
            if let open {
                Button(action: open) { label }
                    .buttonStyle(.plain)
                    .pointerStyle(.link)
            } else {
                label
            }
            if let trailingSymbol, let trailing {
                Button(action: trailing) { Image(systemName: trailingSymbol).font(.icon(.tiny)).foregroundStyle(Tone.muted) }
                    .buttonStyle(.plain).help(Text(trailingHelp ?? ""))
            }
        }
        .padding(.horizontal, Spacing.cozy).padding(.vertical, Spacing.snug)
        .background(Capsule().fill((tint ?? Tone.muted).opacity(tint != nil && strong ? Opacity.tintFillStrong : Opacity.tintFill)))
        .help(help ?? "")
    }

    private var label: some View {
        HStack(spacing: Spacing.small) {
            leading
            Text(verbatim: title).font(mono ? Typeface.mono : Typeface.label).foregroundStyle(Tone.text).lineLimit(1)
                .textSelection(.enabled)
        }
        .contentShape(Capsule())
    }
}

extension ChipButton where Leading == AnyView {
    /// An Imp: its colour, its name and, when it is on another device than its home, a walking mark. Ours have a way home.
    init(imp contact: DeviceMap.Contact, ours: Bool, away: Bool = false, arrow: String? = nil,
         home: (() -> Void)? = nil, help: LocalizedStringKey? = nil, open: @escaping () -> Void) {
        self.init(title: contact.name, tint: Color.imp(contact.hue), strong: ours, help: help, trailingSymbol: home == nil ? nil : "house",
                  trailingHelp: "settings.devices.call_home", trailing: home, leading: {
            AnyView(HStack(spacing: Spacing.tight) {
                Circle().fill(Color.imp(contact.hue)).frame(width: Spacing.cozy, height: Spacing.cozy)
                if let arrow { Image(systemName: arrow).font(.icon(.tiny)).foregroundStyle(Tone.muted) }
                else if away { Image(systemName: "figure.walk").font(.icon(.tiny)).foregroundStyle(Tone.muted) }
            })
        }, open: open)
    }

    /// A device: its picture and name.
    init(device symbol: String, name: String, help: LocalizedStringKey? = nil, open: @escaping () -> Void) {
        self.init(title: name, help: help, leading: { AnyView(Image(systemName: symbol).font(.icon(.tiny)).foregroundStyle(Tone.muted)) }, open: open)
    }

    /// Where a thing is reached: an address (as code) or the Hop's name, with its picture. Opens the line or the Hop when
    /// given `open`.
    init(route symbol: String, title: String, mono: Bool, help: LocalizedStringKey, open: (() -> Void)? = nil) {
        self.init(title: title, mono: mono, help: help, leading: { AnyView(Image(systemName: symbol).font(.icon(.tiny)).foregroundStyle(Tone.muted)) }, open: open)
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
