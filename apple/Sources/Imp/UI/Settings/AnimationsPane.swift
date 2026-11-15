import ImpDesign
import ImpKit
import SwiftUI

/// Every animation an Imp can play: try it, change it, turn it off, choose what starts it, or make
/// a new one.
///
/// The five built-in animations come first, then what came from the Den or was made here. The pane
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
    /// Open groups, kept between visits ("made" is open out of the box).
    @AppStorage("animationGroupsOpen") private var openGroups = "made"

    /// The heading for one family of built-in animations: feelings or answers.
    static func title(_ family: Reaction.Family) -> LocalizedStringKey {
        switch family {
        case .expressions: "Feelings"
        case .gestures: "Answers"
        }
    }

    private var profile: ImpProfile? { imp.flatMap(model.profile) }
    private var hue: Double { profile?.hue ?? 0 }
    private var favorite: Bool { profile.map { $0.isFavorite($0.hue) } ?? false }

    var body: some View {
        let prefs = model.prefs
        let owners = Self.owners(prefs)
        let live = Live(idle: prefs.antics, cursor: prefs.mouseGames)
        let searching = !query.trimmingCharacters(in: .whitespaces).isEmpty
        VStack(alignment: .leading, spacing: Spacing.medium) {
            searchBar(searching: searching)
            madeCard(prefs: prefs, owners: owners, live: live, searching: searching)
            builtInCard(prefs: prefs, owners: owners, live: live, searching: searching)
            if !denReady { needsDen }
        }
        .sheet(item: $editing) { draft in AnimationEditor(model: model, draft: draft) }
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

    /// Puts every built-in animation back to its original version, as an icon in the built-in card's header.
    private func restoreButton(prefs: ImpPreferences) -> some View {
        HoverIconButton(systemName: "arrow.counterclockwise", help: "animations.restore") {
            withImpAnimation(ImpDesign.Motion.smooth, reduceMotion: reduceMotion) { model.prefs.resetAnimations() }
        }
        .disabled(prefs.animations.isEmpty)
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

    /// What was made: animations of their own and new versions of built-in ones, shared or this Imp's.
    @ViewBuilder
    private func madeCard(prefs: ImpPreferences, owners: [AnimationTrigger: String], live: Live, searching: Bool) -> some View {
        let own = profile.map { p in p.animations.map { ($0, Optional(p.id)) } } ?? []
        let made = (own + prefs.animationLibrary.map { ($0, UUID?.none) }).filter { matches($0.0.title, $0.0.about) }
        if !searching || !made.isEmpty {
            FoldCard(title: "animations.from_den", icon: "wand.and.stars", info: madeInfo, count: made.count,
                     open: searching || isOpen("made"), toggle: { toggle("made") }) {
                if !made.isEmpty {
                    let kit = Kit(name: String(localized: "Animations"), animations: made.map(\.0))
                    ShareKitButton(kit: kit, help: "Share these animations as a kit")
                }
                if denReady {
                    HoverIconButton(systemName: "books.vertical", help: "animations.find") { findMore() }
                }
                Button { editing = .new(owner: nil, model: model, previewImp: imp) } label: { FitLabel("animations.new", systemImage: "plus") }
                    .buttonStyle(.imp(.secondary, small: true))
                    .help("Make an animation of your own, beat by beat")
            } content: {
                if made.isEmpty {
                    StatusText(text: "sheets.animations.nothing_yet")
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(made.enumerated()), id: \.element.0.id) { i, item in
                            madeRow(item.0, owner: item.1, prefs: prefs, owners: owners, live: live)
                        }
                    }
                }
            }
            .settingAnchor(.animationsMade)
        }
    }

    private var madeInfo: LocalizedStringKey {
        "Shared ones play for every Imp. One made for a single Imp plays only for it and wins over a shared one. A new version of a built-in animation plays instead of it."
    }

    private func madeRow(_ a: MadeAnimation, owner: UUID?, prefs: ImpPreferences, owners: [AnimationTrigger: String], live: Live) -> some View {
        let tempo = (owner ?? imp).flatMap(model.profile)?.traits.tempo ?? 1
        let ownerName = owner.flatMap(model.profile)?.callName
        let model = model, reduceMotion = reduceMotion
        // An Imp's own version of a built-in one keeps the built-in one's starts.
        var setTrigger: (@MainActor (AnimationTrigger, Bool) -> Void)?
        if owner == nil || a.replaces == nil {
            setTrigger = { t, on in
                withImpAnimation(ImpDesign.Motion.expand, reduceMotion: reduceMotion) { model.prefs.setTrigger(t, on, animation: a.id) }
            }
        }
        return AnimationRow(
            item: .init(key: a.id.uuidString, title: a.title, summary: a.about.isEmpty ? (a.replaces?.summary ?? "") : a.about,
                        symbol: a.symbol, rule: prefs.rule(ofMade: a, owner: owner),
                        owner: ownerName, replaces: a.replaces?.title, edited: false, made: true),
            hue: hue, traits: profile?.traits ?? .plain, content: a.hashValue, locked: a.favoriteColorOnly && !favorite, live: live, owners: owners,
            performance: playing?.key == "made-\(a.id)" ? playing : nil,
            play: { playing = Performance(key: "made-\(a.id)", steps: Antics.paced(a.beats.map(AnticStep.init), tempo: tempo)) },
            finish: finish,
            edit: { editing = AnimationDraft(made: a, owner: owner, isNew: false, previewImp: imp) },
            restore: nil,
            setEnabled: { on in model.prefs.setEnabled(on, animation: a.id) },
            setTrigger: setTrigger)
        .equatable()
    }

    /// The five animations every copy of Imp carries.
    @ViewBuilder
    private func builtInCard(prefs: ImpPreferences, owners: [AnimationTrigger: String], live: Live, searching: Bool) -> some View {
        let members = Reaction.allCases.filter { matches($0.title, $0.summary) }
        if !searching || !members.isEmpty {
            Card(LocalizedStringKey("animations.built_in"), icon: "sparkles") {
                restoreButton(prefs: prefs)
            } content: {
                VStack(spacing: 0) {
                    ForEach(Array(members.enumerated()), id: \.element) { i, reaction in
                        presetRow(reaction, prefs: prefs, owners: owners, live: live)
                    }
                }
            }
            .settingAnchor(.animationsBuiltIn)
        }
    }

    /// The Den is set up, so more animations can be found there (from the made card's header).
    private var denReady: Bool {
        !model.prefs.den.trimmingCharacters(in: .whitespaces).isEmpty && DenServer(model.prefs.den) != nil
    }

    private func findMore() {
        let flow = KitFlow(imp: nil)
        flow.browsing = true
        flow.browseKind = "animation"
        HomeWindow.shared.router.kitFlow = flow
    }

    /// Without a Den there is nowhere to find more: a line that says so, with the way to set one up beside it.
    private var needsDen: some View {
        HStack(spacing: Spacing.cozy) {
            Text("animations.needs_den").font(Typeface.body).foregroundStyle(Tone.muted)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: Spacing.small)
            Button("state.servers.set_up_den") { HomeWindow.shared.router.open(group: .sharing) }
                .buttonStyle(.imp(.secondary, small: true))
        }
    }

    private func presetRow(_ reaction: Reaction, prefs: ImpPreferences, owners: [AnimationTrigger: String], live: Live) -> some View {
        let replacement = prefs.replacement(for: reaction, imp: imp)
        return AnimationRow(
            item: .init(key: reaction.rawValue, title: reaction.title, summary: reaction.summary, symbol: reaction.symbol,
                        rule: prefs.rule(for: reaction), owner: nil, replaces: nil, edited: replacement != nil, made: false),
            hue: hue, traits: profile?.traits ?? .plain, content: replacement?.hashValue ?? 0,
            locked: false, live: live, owners: owners,
            performance: playing?.key == reaction.rawValue ? playing : nil,
            play: { playing = Performance(.preset(reaction), prefs: model.prefs, imp: imp) },
            finish: finish,
            edit: {
                if let replacement, let owner = prefs.owner(ofAnimation: replacement.id) {
                    editing = AnimationDraft(made: replacement, owner: owner, isNew: false, previewImp: imp)
                } else {
                    editing = .replacing(reaction, owner: nil, model: model, previewImp: imp)
                }
            },
            restore: restore(replacement),
            setEnabled: { model.prefs.setEnabled($0, for: reaction) },
            setTrigger: { t, on in
                withImpAnimation(ImpDesign.Motion.expand, reduceMotion: reduceMotion) { model.prefs.setTrigger(t, on, for: reaction) }
            })
        .equatable()
    }

    private func restore(_ replacement: MadeAnimation?) -> (@MainActor () -> Void)? {
        guard let id = replacement?.id else { return nil }
        let model = model
        return { withImpAnimation(ImpDesign.Motion.smooth, reduceMotion: reduceMotion) { model.prefs.removeAnimation(id) } }
    }

    private func finish(_ done: Performance) {
        if playing == done { withImpAnimation(ImpDesign.Motion.smooth, reduceMotion: reduceMotion) { playing = nil } }
    }

    /// Which animation holds each gesture now (one per gesture), found once for every row: by title.
    private static func owners(_ prefs: ImpPreferences) -> [AnimationTrigger: String] {
        var owners: [AnimationTrigger: String] = [:]
        for r in Reaction.allCases {
            for t in prefs.rule(for: r).triggers where t.isExclusive { owners[t] = r.title }
        }
        for a in prefs.animationLibrary where a.replaces == nil && a.isEnabled {
            for t in a.triggers where t.isExclusive { owners[t] = a.title }
        }
        return owners
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
struct Live: Equatable {
    /// Doing things on its own.
    var idle: Bool
    /// Games with the cursor.
    var cursor: Bool

    func isLive(_ t: AnimationTrigger) -> Bool {
        if t == .idle { return idle }
        return t.watchesCursor ? cursor : true
    }
}

/// One animation: try it, what starts it, change it, and a switch. Plain values in, so a row only
/// redraws when something it shows changed (closures are not compared, only whether `restore` and `setTrigger` are set).
struct AnimationRow: View, Equatable {
    struct Item: Equatable {
        var key: String
        var title: String
        var summary: String
        var symbol: String
        var rule: AnimationRule
        /// Made for one Imp only: its name.
        var owner: String?
        /// A made one that plays instead of this built-in one.
        var replaces: String?
        /// A built-in one that has a new version.
        var edited: Bool
        var made: Bool
    }

    let item: Item
    let hue: Double
    var traits = ImpTraits.plain
    /// A hash of the animation the actions below were made from (its beats are not in `item`). Without it
    /// an equal row would keep an old `play` and `edit` after the animation was changed.
    var content = 0
    /// Dimmed with a lock: it plays only in its favourite colour, which this Imp isn't wearing.
    let locked: Bool
    let live: Live
    /// Who holds each gesture, for the trigger menu.
    let owners: [AnimationTrigger: String]
    /// Set while it's being tried.
    let performance: Performance?
    let play: @MainActor () -> Void
    let finish: @MainActor (Performance) -> Void
    let edit: @MainActor () -> Void
    /// Back to the built-in version (nil: it is the built-in version).
    let restore: (@MainActor () -> Void)?
    let setEnabled: @MainActor (Bool) -> Void
    /// Nil: the starts can't be changed here (an Imp's own version of a built-in one keeps its starts).
    let setTrigger: (@MainActor (AnimationTrigger, Bool) -> Void)?

    /// Compares the plain values and which optional actions are set, never the closures themselves.
    nonisolated static func == (a: Self, b: Self) -> Bool {
        a.item == b.item && a.content == b.content && a.hue == b.hue && a.traits == b.traits && a.locked == b.locked
            && a.live == b.live && a.owners == b.owners && a.performance == b.performance && (a.restore == nil) == (b.restore == nil)
            && (a.setTrigger == nil) == (b.setTrigger == nil)
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
        .opacity(locked ? Opacity.dimmed : 1)
        .contextMenu {
            Button("Try") { play() }
            Button(item.made ? "Change…" : "Make Your Own Version…") { edit() }
            if let restore { Button("Restore Original", role: .destructive) { restore() } }
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
        if item.edited { Tag(text: "Changed", symbol: "pencil").help("You made a new version of it. ✎ changes it again, or restore the original.") }
        if let owner = item.owner { Tag(text: "\(owner) only", symbol: "person.fill").help("Only \(owner) plays this one.") }
        if let replaces = item.replaces { Tag(text: "Instead of \(replaces)", symbol: "arrow.triangle.swap").help("Plays instead of the built-in \(replaces).") }
        if locked {
            Image(systemName: "lock.fill").font(.icon(.small, weight: .semibold)).foregroundStyle(Tone.muted)
                .help("Locked. It only does this in the colour it loves. You can still watch a preview.")
        }
    }

    /// What starts it, as small symbols: lit when live, dim when off. The words are the help and the VoiceOver label.
    private var marks: some View {
        let rule = item.rule
        return HStack(spacing: Spacing.snug) {
            if rule.triggers.isEmpty {
                Mark(title: String(localized: "Only when tried"), symbol: "hand.tap", live: false)
            }
            ForEach(AnimationTrigger.allCases.filter(rule.triggers.contains)) { t in
                let on = live.isLive(t)
                Mark(title: on ? t.title : String(localized: "\(t.title) is off"), symbol: t.symbol, live: rule.isEnabled && on)
            }
        }
        .fixedSize()
        .opacity(rule.isEnabled ? 1 : Opacity.dimmed)
    }

    private var switchLabel: LocalizedStringKey {
        item.rule.isEnabled ? "Turn off \(item.title)" : "Turn on \(item.title)"
    }

    private var controls: some View {
        HStack(spacing: Spacing.small) {
            HoverIconButton(systemName: "pencil", help: item.made ? "Change \(item.title)" : "Make your own version of \(item.title)", action: edit)
            triggerMenu
            Toggle(switchLabel, isOn: Binding(get: { item.rule.isEnabled }, set: { setEnabled($0) }))
                .labelsHidden().toggleStyle(.impSwitchBare)
                .help(item.rule.isEnabled ? "Turn off \(item.title)" : "Turn on \(item.title)")
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

    @ViewBuilder private var triggerMenu: some View {
        if let setTrigger { triggerMenu(setTrigger) }
    }

    private func triggerMenu(_ setTrigger: @escaping @MainActor (AnimationTrigger, Bool) -> Void) -> some View {
        let rule = item.rule
        return HoverIconMenu(systemName: "bolt.badge.clock", help: "What starts \(item.title)") {
            ForEach(AnimationTrigger.allCases) { t in
                Toggle(isOn: Binding(get: { rule.triggers.contains(t) }, set: { setTrigger(t, $0) })) {
                    Label(menuTitle(t), systemImage: t.symbol)
                }
            }
            if let restore {
                Section { Button("Restore Original", role: .destructive) { restore() } }
            }
        }
    }

    /// A gesture starts one animation: say which one has it now, since choosing it here moves it.
    private func menuTitle(_ t: AnimationTrigger) -> LocalizedStringKey {
        guard t.isExclusive, !item.rule.triggers.contains(t), let owner = owners[t], owner != item.title else { return LocalizedStringKey(t.title) }
        return "\(t.title) (now \(owner))"
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
