import ImpDesign
import ImpKit
import SwiftUI

/// One animation: try it, what starts it, change it, and a switch. Plain values in, so a row only
/// redraws when something it shows changed (closures are never compared).
struct AnimationRow: View, Equatable {
    struct Item: Equatable {
        var key: String
        var title: String
        var summary: String
        var symbol: String
        var isEnabled: Bool
        /// The events of the triggers that play it.
        var starts: [TriggerEvent]
        /// Made for one Imp only: its name.
        var owner: String?
        var made: Bool
        /// Where it applies, shown under the name (an Imp's own list). With the Imp's name.
        var scope: SettingScope?
        var scopeName = ""
    }

    let item: Item
    let hue: Double
    var traits = ImpTraits.plain
    /// A hash of the animation the actions below were made from (its beats are not in `item`). Without it
    /// an equal row would keep an old `play` and `edit` after the animation was changed.
    var content = 0
    /// Set while it's being tried.
    let performance: Performance?
    let play: @MainActor () -> Void
    let finish: @MainActor (Performance) -> Void
    let edit: @MainActor () -> Void
    let setEnabled: @MainActor (Bool) -> Void
    /// Opens a new trigger that plays it. Not part of the comparison, like the other actions.
    var addTrigger: (@MainActor () -> Void)?
    /// Saves it as an animated sticker (`.tgs`, see `StickerExport`).
    var exportSticker: (@MainActor () -> Void)?

    /// Compares the plain values, never the closures themselves.
    nonisolated static func == (a: Self, b: Self) -> Bool {
        a.item == b.item && a.content == b.content && a.hue == b.hue && a.traits == b.traits
            && a.performance == b.performance
    }

    private var preview: some View {
        AnimationPreview(title: item.title, symbol: item.symbol, hue: hue, traits: traits, performance: performance,
                         play: play, finish: finish)
    }

    var body: some View {
        // One line when there is room: preview, name, the marks for what starts it, controls. Else the marks
        // go under the name (they are icons, so they stay on one line) and the name never gives way to the controls.
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: Spacing.medium) {
                preview
                VStack(alignment: .leading, spacing: Spacing.snug) {
                    HStack(spacing: Spacing.tight) { name; badges }
                    scopeLabel
                }
                Spacer(minLength: Spacing.small)
                marks
                controls
            }
            HStack(alignment: .center, spacing: Spacing.medium) {
                preview
                VStack(alignment: .leading, spacing: Spacing.snug) {
                    HStack(spacing: Spacing.tight) { name; badges }
                    scopeLabel
                    marks
                }
                Spacer(minLength: Spacing.small)
                controls
            }
            VStack(alignment: .leading, spacing: Spacing.snug) {
                HStack(spacing: Spacing.small) {
                    preview
                    name.layoutPriority(1)
                    Spacer(minLength: Spacing.tight)
                    controls
                }
                scopeLabel
                HStack(spacing: Spacing.snug) { badgeItems; marks }
            }
        }
        .padding(.vertical, Spacing.snug)
        .contextMenu {
            Button("Try") { play() }
            Button("Change…") { edit() }
            if let addTrigger { Button("triggers.hint.button") { addTrigger() } }
            if let exportSticker { Button("sticker.export") { exportSticker() } }
        }
    }

    private var name: some View {
        HStack(spacing: Spacing.tight) {
            Text(verbatim: item.title).font(Typeface.label).lineLimit(1)
            if !item.summary.isEmpty { InfoTip(verbatim: item.summary) }
        }
    }

    @ViewBuilder private var scopeLabel: some View {
        if let scope = item.scope { ScopeLabel(scope: scope, name: item.scopeName) }
    }

    private var badges: some View { HStack(spacing: Spacing.tight) { badgeItems } }

    @ViewBuilder private var badgeItems: some View {
        if let owner = item.owner { Tag(text: "\(owner) only", symbol: "person.fill").help("Only \(owner) plays this one.") }
    }

    /// What starts it, as small symbols: the events of the triggers that play it.
    private var marks: some View {
        HStack(spacing: Spacing.snug) {
            if item.starts.isEmpty {
                Mark(title: String(localized: "Only when tried"), symbol: "hand.tap", live: false)
                if let addTrigger { HoverIconButton(systemName: "bolt.fill", help: "triggers.hint.animation", action: addTrigger) }
            }
            ForEach(item.starts, id: \.self) { e in Mark(title: e.title, symbol: e.symbol, live: item.isEnabled) }
        }
        .fixedSize()
        .opacity(item.isEnabled ? 1 : Opacity.dimmed)
    }

    private var switchLabel: LocalizedStringKey {
        item.isEnabled ? "Turn off \(item.title)" : "Turn on \(item.title)"
    }

    private var controls: some View {
        HStack(spacing: Spacing.small) {
            if let exportSticker { HoverIconButton(systemName: "face.smiling.inverse", help: "sticker.export", action: exportSticker) }
            HoverIconButton(systemName: "pencil", help: "Change \(item.title)", action: edit)
            Toggle(switchLabel, isOn: Binding(get: { item.isEnabled }, set: { setEnabled($0) }))
                .labelsHidden().toggleStyle(.impSwitchBare)
                .help(item.isEnabled ? "Turn off \(item.title)" : "Turn on \(item.title)")
        }
        .fixedSize()
    }
}

/// The preview button of an animation: its symbol with a play mark, or a little Imp acting it out while it is
/// being tried. `compact` is the size of a row's icon (Sharing), otherwise the round tile of an animation row.
struct AnimationPreview: View {
    let title: String
    let symbol: String
    let hue: Double
    var traits = ImpTraits.plain
    var compact = false
    /// Set while it's being tried.
    let performance: Performance?
    let play: @MainActor () -> Void
    let finish: @MainActor (Performance) -> Void

    private var side: CGFloat { compact ? Sizing.iconTile : Sizing.marker }

    var body: some View {
        Button(action: play) {
            ZStack {
                Circle().fill(Tone.card)
                if let performance {
                    StageImp(hue: hue, performance: performance, traits: traits)
                        .frame(width: side + Spacing.small, height: side + Spacing.small)
                        .offset(y: -Spacing.tight)
                        .transition(.scale(scale: 0.4).combined(with: .opacity))
                        .task(id: performance.started) {
                            // Ends the try once the Imp has played it out, plus a short pause.
                            try? await Task.sleep(for: .seconds(performance.duration + 0.3))
                            finish(performance)
                        }
                } else {
                    Image(systemName: symbol).font(.icon(compact ? .small : .large, weight: .semibold)).foregroundStyle(Tone.muted)
                    Image(systemName: "play.fill").font(.icon(.tiny, weight: .black)).foregroundStyle(OnTint(Color.imp(hue)))
                        .padding(compact ? Spacing.hairline : Spacing.tight).background(Circle().fill(TintFill(Color.imp(hue))))
                        .offset(x: compact ? Spacing.small : Spacing.roomy, y: compact ? Spacing.small : Spacing.roomy)
                }
            }
            .frame(width: side, height: side)
            .contentShape(Circle())
            .impAnimation(ImpDesign.Motion.expand, value: performance != nil)
        }
        .buttonStyle(.plain)
        .help("Try \(title)")
        .accessibilityLabel("Try \(title)")
    }
}

/// A small note beside a title ("Changed", "Pip only").
private struct Tag: View {
    let text: LocalizedStringKey
    let symbol: String
    @Environment(\.impTint) private var tint

    var body: some View {
        Label(text, systemImage: symbol)
            .font(Typeface.small.weight(.semibold))
            .labelStyle(.titleAndIcon)
            .foregroundStyle(LegibleTint(tint))
            .lineLimit(1)
            .padding(.horizontal, Spacing.snug).padding(.vertical, Spacing.hairline)
            .background(Capsule().fill(tint.opacity(Opacity.tintFill)))
    }
}

/// One thing that starts an animation, as a symbol: lit with the tint when live, muted when off.
private struct Mark: View {
    let title: String
    let symbol: String
    var live = true
    @Environment(\.impTint) private var tint

    var body: some View {
        Image(systemName: symbol)
            .font(.icon(.small, weight: .semibold))
            .foregroundStyle(live ? AnyShapeStyle(LegibleTint(tint)) : AnyShapeStyle(Tone.muted))
            .opacity(live ? 1 : Opacity.dimmed)
            .help(title)
            .accessibilityLabel(title)
    }
}
