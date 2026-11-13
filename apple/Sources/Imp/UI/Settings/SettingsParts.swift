import ImpDesign
import ImpKit
import SwiftUI

extension ImpSetting {
    /// The marker's name, and the panel's name in the bar.
    var title: LocalizedStringResource {
        switch self {
        case .brain: "imp_settings.marker.brain"
        case .look: "imp_settings.marker.look"
        case .personality: "imp_settings.marker.personality"
        case .tools: "imp_settings.marker.tools"
        case .triggers: "imp_settings.marker.triggers"
        case .moves: "imp_settings.marker.moves"
        }
    }
}

/// What a setting shows about itself, in as few marks as possible: a count on its marker, one short
/// value in the list, and the whole sentence for the tooltip and the screen reader.
struct SettingState {
    var summary: String
    /// A short value for the list row ("17/26", a model name).
    var value: String?
    /// A count on the marker (tools on, triggers).
    var badge: Int?
    /// The Brain's lantern: unlit while the Imp sleeps. Every other setting is always lit.
    var lit = true
}

/// A setting around the Imp: a round tile with its picture and a one-word title. The Brain's tile is a
/// lantern, lit when the Brain works and unlit (calm, not a warning) when the Imp sleeps. The picked
/// marker is filled with the Imp's colour.
struct SettingMarker: View {
    let setting: ImpSetting
    let profile: ImpProfile
    let state: SettingState
    let picked: Bool
    let action: () -> Void
    @Environment(\.impTint) private var tint
    @Environment(\.isFocused) private var focused
    @State private var hover = false

    private static let hoverScale = 1.06

    var body: some View {
        Button(action: action) {
            VStack(spacing: Spacing.snug) {
                tile
                Text(setting.title).font(Typeface.label).foregroundStyle(Tone.text).lineLimit(1)
            }
            .frame(maxWidth: .infinity, minHeight: Sizing.hit)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .impAnimation(ImpDesign.Motion.hover, value: hover)
        .help(Text(verbatim: state.summary))
        .accessibilityLabel(Text(setting.title))
        .accessibilityValue(a11yValue)
        .accessibilityAddTraits(picked ? .isSelected : [])
    }

    /// The icon is a third of the tile, so it is always well inside the round fill.
    private var tile: some View {
        Image(systemName: setting == .brain && !state.lit ? "lightbulb" : setting.symbol)
            .font(.icon(.big))
            .foregroundStyle(picked ? AnyShapeStyle(OnTint(tint)) : AnyShapeStyle(state.lit ? AnyShapeStyle(LegibleTint()) : AnyShapeStyle(Tone.muted)))
            .frame(width: Sizing.marker, height: Sizing.marker)
            .background(Circle().fill(fill))
            .focusRing(Circle(), shown: focused)
            .overlay(alignment: .topTrailing) {
                if let badge = state.badge, badge > 0 { CountBadge(count: badge) }
            }
            .scaleEffect(hover ? Self.hoverScale : 1)
            .accessibilityHidden(true)
    }

    private var fill: AnyShapeStyle {
        if picked { return AnyShapeStyle(TintFill(tint)) }
        return AnyShapeStyle(hover ? Tone.cardHover : Tone.card)
    }

    private var a11yValue: String {
        guard setting == .brain, !state.lit else { return state.summary }
        return words("imp_settings.brain_marker.asleep", profile.callName)
    }
}

/// A small number on a marker.
struct CountBadge: View {
    let count: Int

    var body: some View {
        Text(verbatim: "\(count)")
            .font(Typeface.small.weight(.bold).monospacedDigit())
            .foregroundStyle(Tone.onAccent)
            .padding(.horizontal, Spacing.snug).padding(.vertical, Spacing.hairline)
            .frame(minWidth: Spacing.large)
            .background(Capsule().fill(Tone.accent))
            .offset(x: Spacing.snug, y: -Spacing.tight)
    }
}

/// A setting as a row of the plain list: its own pebble with an icon bead, its title, one short value
/// and a chevron.
struct SettingListRow: View {
    let setting: ImpSetting
    let profile: ImpProfile
    let state: SettingState
    let action: () -> Void
    @Environment(\.isFocused) private var focused
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: Spacing.medium) {
                IconTile(systemName: setting == .brain && !state.lit ? "lightbulb" : setting.symbol)
                    .opacity(state.lit ? 1 : Opacity.dimmed)
                Text(setting.title).font(Typeface.body).foregroundStyle(Tone.text).lineLimit(1)
                Spacer(minLength: Spacing.small)
                if let value = state.value {
                    Text(verbatim: value).font(Typeface.small).foregroundStyle(Tone.muted).lineLimit(1)
                }
                Image(systemName: "chevron.right").font(.icon(.small, weight: .bold)).foregroundStyle(Tone.faint)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, Spacing.medium).padding(.vertical, Spacing.small)
            .frame(maxWidth: .infinity, minHeight: Sizing.control, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: Radius.tile, style: .continuous).fill(hover ? Tone.cardHover : Tone.card))
            .focusRing(RoundedRectangle(cornerRadius: Radius.tile, style: .continuous), shown: focused)
            .contentShape(RoundedRectangle(cornerRadius: Radius.tile, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .impAnimation(ImpDesign.Motion.hover, value: hover)
        .help(Text(verbatim: state.summary))
        .accessibilityLabel(Text(setting.title))
        .accessibilityValue(setting == .brain && !state.lit ? words("imp_settings.brain_marker.asleep", profile.callName) : state.summary)
    }
}

/// An open panel: a scrolling column of cards on the shared surface, under the window's one bar. It
/// has no header of its own: the bar names it, and beside the stage its marker is lit.
struct SettingsPanelFrame<Content: View>: View {
    let setting: ImpSetting
    @ViewBuilder var content: Content

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.medium) { content }
                    .padding(.horizontal, Spacing.large)
                    .padding(.top, Spacing.hairline)
                    .padding(.bottom, Spacing.page)
                    .frame(maxWidth: Sizing.column, alignment: .leading)
                    .frame(maxWidth: .infinity)
                    .scrollsToHighlightedSetting(proxy)
            }
            .id(setting)
            .scrollContentBackground(.hidden)
        }
        .impControls()
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(setting.title))
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

/// Sharing this Imp: in The Den when it is set up, or as a file.
struct ShareImpSheet: View {
    let model: AppModel
    let id: UUID
    @State private var publishing = false

    private var name: String { model.profile(id)?.callName ?? ImpProfile.stranger }
    private var denReady: Bool { ServerSetup(den: model.prefs.den, hop: model.prefs.hop).den != nil }

    var body: some View {
        SheetScaffold(icon: "square.and.arrow.up", title: LocalizedStringKey(words("share.title", name)), info: LocalizedStringKey("share.note")) {
            Card {
                shareRow("share.den", symbol: "globe") { publishing = true }
                    .disabled(!denReady)
                if !denReady { StatusText(text: "share.den_needs_setup", symbol: "info.circle") }
                shareRow("share.file", symbol: "square.and.arrow.down") {
                    ImpExport.save([id], model: model, name: name, fileName: name)
                }
            }
        } footer: {
            EmptyView()
        }
        .sheet(isPresented: $publishing) {
            DenPublishSheet(context: PublishContext(model: model, imp: id), kit: ImpExport.kit([id], model: model, name: name))
        }
    }

    private func shareRow(_ title: LocalizedStringKey, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: Spacing.medium) {
                IconTile(systemName: symbol)
                Text(title).font(Typeface.body).foregroundStyle(Tone.text).lineLimit(1)
                Spacer(minLength: Spacing.small)
                Image(systemName: "chevron.right").font(.icon(.small, weight: .bold)).foregroundStyle(Tone.faint)
                    .accessibilityHidden(true)
            }
            .frame(maxWidth: .infinity, minHeight: Sizing.control, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
