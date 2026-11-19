import ImpDesign
import ImpKit
import SwiftUI

extension ImpSetting {
    /// The section's name in the rail.
    var title: LocalizedStringResource {
        switch self {
        case .brain: "imp_settings.marker.brain"
        case .look: "imp_settings.marker.look"
        case .personality: "imp_settings.marker.personality"
        case .tools: "imp_settings.marker.tools"
        case .triggers: "imp_settings.marker.triggers"
        case .animations: "imp_settings.marker.animations"
        case .computer: "imp_settings.marker.computer"
        }
    }
}

/// A card of a panel: a title with its picture and help, an optional control on the right, and its rows.
struct PanelSection<Content: View, Accessory: View>: View {
    let title: LocalizedStringKey?
    var icon: String?
    var info: LocalizedStringKey?
    @ViewBuilder var accessory: Accessory
    @ViewBuilder var content: Content

    init(_ title: LocalizedStringKey? = nil, icon: String? = nil, info: LocalizedStringKey? = nil,
         @ViewBuilder accessory: () -> Accessory, @ViewBuilder content: () -> Content) {
        self.title = title
        self.icon = icon
        self.info = info
        self.accessory = accessory()
        self.content = content()
    }

    var body: some View {
        Card(title, icon: icon, info: info, accessory: { accessory }, content: { content })
    }
}

extension PanelSection where Accessory == EmptyView {
    init(_ title: LocalizedStringKey? = nil, icon: String? = nil, info: LocalizedStringKey? = nil, @ViewBuilder content: () -> Content) {
        self.init(title, icon: icon, info: info, accessory: { EmptyView() }, content: content)
    }
}

/// A list of things (services, chats, triggers, tools) under a header on the surface. Each item is
/// its own pebble, with a small gap between, so nothing needs a line to set it apart. Give each item
/// `.pebble(...)`.
struct PanelList<Content: View, Accessory: View>: View {
    let title: LocalizedStringKey
    var icon: String
    var info: LocalizedStringKey
    @ViewBuilder var accessory: Accessory
    @ViewBuilder var content: Content

    init(_ title: LocalizedStringKey, icon: String, info: LocalizedStringKey,
         @ViewBuilder accessory: () -> Accessory, @ViewBuilder content: () -> Content) {
        self.title = title
        self.icon = icon
        self.info = info
        self.accessory = accessory()
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.snug) {
            SectionHeader(title, icon: icon, info: info) { accessory }
            .padding(.horizontal, Spacing.small)
            .padding(.bottom, Spacing.tight)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension PanelList where Accessory == EmptyView {
    init(_ title: LocalizedStringKey, icon: String, info: LocalizedStringKey, @ViewBuilder content: () -> Content) {
        self.init(title, icon: icon, info: info, accessory: { EmptyView() }, content: content)
    }
}

extension View {
    /// One item of a `PanelList`: its own pebble, lit while the pointer is over it.
    func pebble(hover: Bool = false) -> some View {
        padding(.horizontal, Spacing.medium).padding(.vertical, Spacing.small)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: Radius.tile, style: .continuous).fill(hover ? Tone.cardHover : Tone.card))
    }
}

/// A slider and its value for a `Row`: wide enough to use, never wider than a few fingers.
struct RowSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double?
    let label: LocalizedStringKey
    let shown: String
    var resets: Double?

    var body: some View {
        HStack(spacing: Spacing.cozy) {
            Group {
                if let step { Slider(value: $value, in: range, step: step) } else { Slider(value: $value, in: range) }
            }
            .impSlider()
            .accessibilityLabel(Text(label))
            .accessibilityValue(shown)
            Text(verbatim: shown).font(Typeface.small.monospacedDigit()).foregroundStyle(Tone.muted)
                .frame(minWidth: Sizing.hit * 1.5, alignment: .trailing)
        }
        .frame(minWidth: Sizing.hit * 4, maxWidth: Sizing.hit * 7)
        .onTapGesture(count: 2) { if let resets { value = resets } }
    }
}
