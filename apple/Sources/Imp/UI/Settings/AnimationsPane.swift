import ImpDesign
import ImpKit
import SwiftUI

/// Every animation an Imp can play: try it, change it, turn it off, choose what starts it, or make
/// a new one.
///
/// What came from the Den or was made here (nothing is built in). The pane
/// reads the preferences once per render and hands each row plain values, and rows only re-render
/// when their own values change (`Equatable`).
struct AnimationsPane: View {
    @Bindable var model: AppModel
    /// The Imp previews are played by (its colour and character), from the window's selection.
    var imp: UUID?
    @State private var playing: Performance?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var query = ""
    @State private var editing: AnimationDraft?
    @State private var triggerFor: AnimationName?
    /// Open groups, kept between visits ("made" is open out of the box).
    @AppStorage("animationGroupsOpen") private var openGroups = "made"

    private var profile: ImpProfile? { imp.flatMap(model.profile) }
    private var hue: Double { profile?.hue ?? 0 }
    private var favorite: Bool { profile.map { $0.isFavorite($0.hue) } ?? false }

    var body: some View {
        let prefs = model.prefs
        let searching = !query.trimmingCharacters(in: .whitespaces).isEmpty
        VStack(alignment: .leading, spacing: Spacing.medium) {
            searchBar(searching: searching)
            madeCard(prefs: prefs, searching: searching)
        }
        .sheet(item: $editing) { draft in AnimationEditor(model: model, draft: draft) }
        .addTriggerSheet(model: model, imp: imp, animation: $triggerFor)
    }

    // MARK: Parts

    /// The search: its clear action is inside the field. "New animation" is the made card's own action.
    private func searchBar(searching: Bool) -> some View {
        FieldWell(symbol: "magnifyingglass") {
            TextField("animations.search", text: $query)
        } actions: {
            if searching { FieldAction(systemName: "xmark.circle.fill", help: "Clear") { query = "" } }
        }
    }

    // MARK: Groups

    private func isOpen(_ key: String) -> Bool { openGroups.split(separator: ",").contains { $0 == key } }

    private func toggle(_ key: String) {
        var keys = Set(openGroups.split(separator: ",").map(String.init))
        if keys.contains(key) { keys.remove(key) } else { keys.insert(key) }
        withImpAnimation(ImpDesign.Motion.expand, reduceMotion: reduceMotion) { openGroups = keys.sorted().joined(separator: ",") }
    }

    private func matches(_ texts: String...) -> Bool {
        let q = query.trimmingCharacters(in: .whitespaces)
        return q.isEmpty || texts.contains { $0.localizedCaseInsensitiveContains(q) }
    }

    /// What was made: animations the Imp or you made, shared or this Imp's.
    @ViewBuilder
    private func madeCard(prefs: ImpPreferences, searching: Bool) -> some View {
        let own = profile.map { p in p.animations.map { ($0, Optional(p.id)) } } ?? []
        let made = (own + prefs.animationLibrary.map { ($0, UUID?.none) }).filter { matches($0.0.title, $0.0.about) }
        if !searching || !made.isEmpty {
            FoldCard(title: "animations.from_den", icon: "wand.and.stars", info: madeInfo, count: made.count,
                     open: searching || isOpen("made"), toggle: { toggle("made") }) {
                if !made.isEmpty {
                    let kit = Kit(name: String(localized: "Animations"), animations: made.map(\.0))
                    ShareKitButton(kit: kit, help: "Share these animations as a kit")
                }
                Button { editing = .new(owner: nil, model: model, previewImp: imp) } label: { FitLabel("animations.new", systemImage: "plus") }
                    .buttonStyle(.imp(.secondary, small: true))
                    .help("Make an animation of your own, beat by beat")
            } content: {
                if made.isEmpty {
                    EmptyState("sheets.animations.nothing_yet", symbol: "wand.and.stars")
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(made.enumerated()), id: \.element.0.id) { i, item in
                            madeRow(item.0, owner: item.1, prefs: prefs)
                        }
                    }
                }
            }
            .settingAnchor(.animationsMade)
        }
    }

    private var madeInfo: LocalizedStringKey {
        "Shared ones play for every Imp. One made for a single Imp plays only for it and wins over a shared one."
    }

    private func madeRow(_ a: MadeAnimation, owner: UUID?, prefs: ImpPreferences) -> some View {
        let tempo = (owner ?? imp).flatMap(model.profile)?.traits.tempo ?? 1
        let ownerName = owner.flatMap(model.profile)?.callName
        let add: (@MainActor () -> Void)? = imp == nil ? nil : { @MainActor in triggerFor = AnimationName(id: a.title) }
        return AnimationRow(
            item: .init(key: a.id.uuidString, title: a.title, summary: a.about,
                        symbol: a.symbol, isEnabled: a.isEnabled,
                        starts: imp.map { prefs.triggers(for: $0) }?.filter { $0.isEnabled && $0.steps.contains { $0.animationName == a.title } }.map(\.trigger.event) ?? [],
                        owner: ownerName, made: true),
            hue: hue, traits: profile?.traits ?? .plain, content: a.hashValue,
            performance: playing?.key == "made-\(a.id)" ? playing : nil,
            play: { playing = Performance(key: "made-\(a.id)", steps: Antics.paced(a.beats.map(AnticStep.init), tempo: tempo)) },
            finish: finish,
            edit: { editing = AnimationDraft(made: a, owner: owner, isNew: false, previewImp: imp) },
            setEnabled: { on in model.prefs.setEnabled(on, animation: a.id) },
            addTrigger: add,
            exportSticker: { [model] in
                let maker = (owner ?? imp).flatMap(model.profile) ?? .imp
                StickerExport.save(a.beats, name: a.title, hue: maker.hue, traits: maker.traits)
            })
        .equatable()
    }

    private func finish(_ done: Performance) {
        if playing == done { withImpAnimation(ImpDesign.Motion.smooth, reduceMotion: reduceMotion) { playing = nil } }
    }

}

/// A card whose content folds away: the header (chevron, icon, title, count) opens and closes it.
private struct FoldCard<Accessory: View, Content: View>: View {
    let title: LocalizedStringKey
    let icon: String
    var info: LocalizedStringKey?
    var count: Int
    var off = 0
    var open: Bool
    var toggle: () -> Void
    @ViewBuilder var accessory: Accessory
    @ViewBuilder var content: Content
    @Environment(\.impTint) private var tint

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.medium) {
            HStack(spacing: Spacing.small) {
                Button(action: toggle) {
                    HStack(spacing: Spacing.small) {
                        Image(systemName: "chevron.right")
                            .font(Typeface.small.weight(.bold)).foregroundStyle(Tone.muted)
                            .rotationEffect(.degrees(open ? 90 : 0))
                            .frame(width: Spacing.cozy)
                        IconTile(systemName: icon)
                        Text(title).font(Typeface.cardTitle).lineLimit(1)
                        Text(verbatim: "\(count)")
                            .font(Typeface.small.weight(.semibold)).foregroundStyle(Tone.muted)
                            .padding(.horizontal, Spacing.snug).padding(.vertical, Spacing.hairline)
                            .background(Capsule().fill(Tone.card))
                        if off > 0 {
                            Text("\(off) off").font(Typeface.small.weight(.medium)).foregroundStyle(Tone.muted)
                        }
                        Spacer(minLength: Spacing.small)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(.isHeader)
                .accessibilityValue(open ? Text("Open") : Text("Folded"))
                .accessibilityHint(Text("Shows or hides these animations"))
                accessory
                if let info { InfoTip(info) }
            }
            .frame(minHeight: Sizing.glyph)
            if open { content.transition(.opacity) }
        }
        .padding(Spacing.roomy)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Radius.medium, style: .continuous).fill(Tone.card))
    }
}

/// Which switches are on, as far as a trigger's chip is concerned.
/// One animation: try it, what starts it, change it, and a switch. Plain values in, so a row only
/// redraws when something it shows changed (closures are not compared, only whether `setTrigger` is set).
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

    /// Compares the plain values and which optional actions are set, never the closures themselves.
    nonisolated static func == (a: Self, b: Self) -> Bool {
        a.item == b.item && a.content == b.content && a.hue == b.hue && a.traits == b.traits
            && a.performance == b.performance
    }

    var body: some View {
        // One line when there is room: preview, name, the marks for what starts it, controls. Else the marks
        // go under the name (they are icons, so they stay on one line) and the name never gives way to the controls.
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: Spacing.medium) {
                preview
                VStack(alignment: .leading, spacing: Spacing.snug) {
                    HStack(spacing: Spacing.tight) { name; badges }
                }
                Spacer(minLength: Spacing.small)
                marks
                controls
            }
            HStack(alignment: .center, spacing: Spacing.medium) {
                preview
                VStack(alignment: .leading, spacing: Spacing.snug) {
                    HStack(spacing: Spacing.tight) { name; badges }
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

    /// The preview button: the animation's symbol, or a little Imp acting it out while it is being tried.
    private var preview: some View {
        Button(action: play) {
            ZStack {
                Circle().fill(Tone.card)
                if let performance {
                    StageImp(hue: hue, performance: performance, traits: traits)
                        .frame(width: Sizing.marker + Spacing.small, height: Sizing.marker + Spacing.small)
                        .offset(y: -Spacing.tight)
                        .transition(.scale(scale: 0.4).combined(with: .opacity))
                        .task(id: performance.started) {
                            // Ends the try once the Imp has played it out, plus a short pause.
                            try? await Task.sleep(for: .seconds(performance.duration + 0.3))
                            finish(performance)
                        }
                } else {
                    Image(systemName: item.symbol).font(.icon(.large, weight: .semibold)).foregroundStyle(Tone.muted)
                    Image(systemName: "play.fill").font(.icon(.tiny, weight: .black)).foregroundStyle(OnTint(Color.imp(hue)))
                        .padding(Spacing.tight).background(Circle().fill(TintFill(Color.imp(hue))))
                        .offset(x: Spacing.roomy, y: Spacing.roomy)
                }
            }
            .frame(width: Sizing.marker, height: Sizing.marker)
            .contentShape(Circle())
            .impAnimation(ImpDesign.Motion.expand, value: performance != nil)
        }
        .buttonStyle(.plain)
        .help("Try \(item.title)")
        .accessibilityLabel("Try \(item.title)")
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
