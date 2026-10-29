import ImpKit
import SwiftUI

/// Every animation an Imp can play: try it, change it, turn it off, choose what starts it, or make
/// a new one.
///
/// The list is long (dozens of rows), so it's built to be cheap: groups fold away (only open ones
/// build their rows; the page opens with them folded), the whole pane reads the preferences once
/// per render and hands each row plain values, and rows only re-render when their own values
/// change (`Equatable`). (Not lazy: lazy stacks re-guess the heights of rows above when a preview
/// starts, and the page jumped.)
struct AnimationsPane: View {
    @Bindable var model: AppModel
    /// The Imp previews are played by (its colour and character), from the window's selection.
    var imp: UUID?
    @State private var playing: Performance?
    @State private var query = ""
    @State private var editing: AnimationDraft?
    /// Open groups, kept between visits ("made" is open out of the box).
    @AppStorage("animationGroupsOpen") private var openGroups = "made"

    private var profile: ImpProfile? { imp.flatMap(model.profile) }
    private var hue: Double { profile?.hue ?? 0 }
    private var favorite: Bool { profile.map { $0.isFavorite($0.hue) } ?? false }

    var body: some View {
        let prefs = model.prefs
        let owners = Self.owners(prefs)
        let live = Live(idle: prefs.antics, cursor: prefs.mouseGames)
        let searching = !query.trimmingCharacters(in: .whitespaces).isEmpty
        VStack(alignment: .leading, spacing: Metrics.gap) {
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").font(.system(size: 12, weight: .semibold)).foregroundStyle(Dungeon.muted)
                    TextField("Find an animation", text: $query).textFieldStyle(.plain).font(.system(size: 13))
                    if searching {
                        Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(Dungeon.muted) }
                            .buttonStyle(.plain).help("Clear")
                    }
                }
                .padding(.horizontal, 10).frame(height: Metrics.control)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.white.opacity(0.06)))
                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Dungeon.cardEdge))
                Button { editing = .new(owner: nil, model: model, previewImp: imp) } label: { Label("New Animation", systemImage: "plus") }
                    .buttonStyle(.imp(.secondary, small: true))
                    .help("Make an animation of your own, beat by beat")
            }
            madeCard(prefs: prefs, owners: owners, live: live, searching: searching)
            ForEach(Reaction.Family.allCases, id: \.self) { family in
                familyCard(family, prefs: prefs, owners: owners, live: live, searching: searching)
            }
            HStack {
                Spacer()
                Button("Restore Defaults") { withAnimation(.snappy) { model.prefs.resetAnimations() } }
                    .buttonStyle(.imp(.quiet, small: true))
                    .disabled(prefs.animations.isEmpty)
                    .help("Turns every built-in animation on, with its original starts. What you made or changed stays.")
            }
        }
        .sheet(item: $editing) { draft in AnimationEditor(model: model, draft: draft) }
    }

    // MARK: Groups

    private func isOpen(_ key: String) -> Bool { openGroups.split(separator: ",").contains { $0 == key } }

    private func toggle(_ key: String) {
        var keys = Set(openGroups.split(separator: ",").map(String.init))
        if keys.contains(key) { keys.remove(key) } else { keys.insert(key) }
        withAnimation(.snappy(duration: 0.22)) { openGroups = keys.sorted().joined(separator: ",") }
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
            FoldCard(title: "Made by you", icon: "wand.and.stars", info: madeInfo, count: made.count,
                     open: searching || isOpen("made"), toggle: { toggle("made") }) {
                if !made.isEmpty {
                    let kit = Kit(name: String(localized: "Animations"), animations: made.map(\.0))
                    ShareKitButton(kit: kit, help: "Share these animations as a kit")
                }
            } content: {
                if made.isEmpty {
                    Text("Nothing yet. Make one with New Animation, or open any animation below with ✎ to make your own version of it.")
                        .font(.system(size: 12.5)).foregroundStyle(Dungeon.muted).fixedSize(horizontal: false, vertical: true)
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(made.enumerated()), id: \.element.0.id) { i, item in
                            if i > 0 { CardDivider().padding(.vertical, 2) }
                            madeRow(item.0, owner: item.1, prefs: prefs, owners: owners, live: live)
                        }
                    }
                }
            }
        }
    }

    private var madeInfo: LocalizedStringKey {
        "Shared ones play for every Imp. One made for a single Imp plays only for it and wins over a shared one. A new version of a built-in animation plays instead of it."
    }

    private func madeRow(_ a: MadeAnimation, owner: UUID?, prefs: ImpPreferences, owners: [AnimationTrigger: String], live: Live) -> some View {
        let tempo = (owner ?? imp).flatMap(model.profile)?.traits.tempo ?? 1
        let ownerName = owner.flatMap(model.profile)?.callName
        return AnimationRow(
            item: .init(key: a.id.uuidString, title: a.title, summary: a.about.isEmpty ? (a.replaces?.summary ?? "") : a.about,
                        symbol: a.symbol, rule: AnimationRule(isEnabled: a.replaces.map(prefs.isEnabled) ?? a.isEnabled,
                                                              triggers: a.replaces.map { prefs.rule(for: $0).triggers } ?? a.triggers),
                        owner: ownerName, replaces: a.replaces?.title, edited: false, made: true),
            hue: hue, traits: profile?.traits ?? .plain, locked: false, live: live, owners: owners,
            performance: playing?.key == "made-\(a.id)" ? playing : nil,
            play: { playing = Performance(key: "made-\(a.id)", steps: Antics.paced(a.beats.map(AnticStep.init), tempo: tempo)) },
            finish: finish,
            edit: { editing = AnimationDraft(made: a, owner: owner, isNew: false, previewImp: imp) },
            restore: nil,
            setEnabled: { on in
                if let r = a.replaces { model.prefs.setEnabled(on, for: r) } else { model.prefs.setEnabled(on, animation: a.id) }
            },
            setTrigger: { t, on in
                withAnimation(.snappy(duration: 0.2)) {
                    if let r = a.replaces { model.prefs.setTrigger(t, on, for: r) } else { model.prefs.setTrigger(t, on, animation: a.id) }
                }
            })
        .equatable()
    }

    @ViewBuilder
    private func familyCard(_ family: Reaction.Family, prefs: ImpPreferences, owners: [AnimationTrigger: String],
                            live: Live, searching: Bool) -> some View {
        let members = Reaction.allCases.filter { $0.family == family && matches($0.title, $0.summary) }
        if !searching || !members.isEmpty {
            let off = members.filter { !prefs.isEnabled($0) }.count
            FoldCard(title: Self.title(family), icon: Self.icon(family), info: Self.subtitle(family), count: members.count,
                     off: off, open: searching || isOpen(family.rawValue), toggle: { toggle(family.rawValue) }) {
                switch family {
                case .routines:
                    Toggle(String(""), isOn: $model.prefs.antics).labelsHidden().toggleStyle(.switch).controlSize(.small)
                        .help(prefs.antics ? "Turn off all routines" : "Turn on routines")
                case .favorite where !favorite:
                    Image(systemName: "lock.fill").font(.system(size: 11, weight: .semibold)).foregroundStyle(Dungeon.muted)
                        .help("This Imp isn't wearing the colour it loves")
                default:
                    EmptyView()
                }
            } content: {
                VStack(spacing: 0) {
                    ForEach(Array(members.enumerated()), id: \.element) { i, reaction in
                        if i > 0 { CardDivider().padding(.vertical, 2) }
                        presetRow(reaction, prefs: prefs, owners: owners, live: live)
                    }
                }
            }
        }
    }

    private func presetRow(_ reaction: Reaction, prefs: ImpPreferences, owners: [AnimationTrigger: String], live: Live) -> some View {
        let replacement = prefs.replacement(for: reaction, imp: imp)
        return AnimationRow(
            item: .init(key: reaction.rawValue, title: reaction.title, summary: reaction.summary, symbol: reaction.symbol,
                        rule: prefs.rule(for: reaction), owner: nil, replaces: nil, edited: replacement != nil, made: false),
            hue: hue, traits: profile?.traits ?? .plain,
            locked: reaction.unlocksWithFavoriteColor && !favorite, live: live, owners: owners,
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
                withAnimation(.snappy(duration: 0.2)) { model.prefs.setTrigger(t, on, for: reaction) }
            })
        .equatable()
    }

    private func restore(_ replacement: MadeAnimation?) -> (@MainActor () -> Void)? {
        guard let id = replacement?.id else { return nil }
        let model = model
        return { withAnimation(.snappy) { model.prefs.removeAnimation(id) } }
    }

    private func finish(_ done: Performance) {
        if playing == done { withAnimation(.snappy) { playing = nil } }
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

    static func title(_ f: Reaction.Family) -> LocalizedStringKey {
        switch f {
        case .expressions: "Feelings"
        case .gestures: "Answers"
        case .play: "Cursor games"
        case .handling: "Clicks and carrying"
        case .routines: "On its own"
        case .favorite: "Favourite colour"
        }
    }

    static func icon(_ f: Reaction.Family) -> String {
        switch f {
        case .expressions: "face.smiling"
        case .gestures: "hand.raised.fill"
        case .play: "cursorarrow.motionlines"
        case .handling: "hand.raised.fingers.spread.fill"
        case .routines: "hourglass"
        case .favorite: "heart.fill"
        }
    }

    private static func subtitle(_ f: Reaction.Family) -> LocalizedStringKey {
        switch f {
        case .expressions: "Feelings it shows. Some are how Imps respond to each other."
        case .gestures: "Body language for its answers: a nod, a shrug, a bow. None plays on its own, so give one a start or try it."
        case .play: "What it does when you play with the cursor: circle it, stroke its head, tickle it, stare at it. Stroking needs slow strokes to and fro."
        case .handling: "Pokes, presses, carrying it, shaking it and putting it down."
        case .routines: "Little things it does when it's quiet. The switch turns them all off."
        case .favorite: "Finding the colour it loves, and what it does only while it wears it. Previews always work."
        }
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
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Button(action: toggle) {
                    HStack(spacing: 8) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .bold)).foregroundStyle(Dungeon.muted)
                            .rotationEffect(.degrees(open ? 90 : 0))
                            .frame(width: 10)
                        Image(systemName: icon).font(.system(size: 12, weight: .semibold)).foregroundStyle(tint)
                            .frame(width: 24, height: 24)
                            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(tint.opacity(0.16)))
                        Text(title).font(.system(size: 14, weight: .bold, design: .rounded)).lineLimit(1)
                        Text(verbatim: "\(count)")
                            .font(.system(size: 11, weight: .semibold, design: .rounded)).foregroundStyle(Dungeon.muted)
                            .padding(.horizontal, 6).frame(height: 17)
                            .background(Capsule().fill(Color.white.opacity(0.07)))
                        if off > 0 {
                            Text("\(off) off").font(.system(size: 11, weight: .medium)).foregroundStyle(Dungeon.muted.opacity(0.8))
                        }
                        Spacer(minLength: 8)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(.isHeader)
                .accessibilityValue(open ? Text("Open") : Text("Folded"))
                .accessibilityHint(Text("Shows or hides these animations"))
                if let info { InfoTip(info) }
                accessory
            }
            .frame(minHeight: 26)
            if open { content.transition(.opacity) }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Metrics.corner, style: .continuous).fill(Dungeon.card))
        .overlay(RoundedRectangle(cornerRadius: Metrics.corner, style: .continuous).strokeBorder(Dungeon.cardEdge))
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
/// redraws when something it shows changed (the closures are ignored when comparing).
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
    let setTrigger: @MainActor (AnimationTrigger, Bool) -> Void

    nonisolated static func == (a: Self, b: Self) -> Bool {
        a.item == b.item && a.hue == b.hue && a.traits == b.traits && a.locked == b.locked
            && a.live == b.live && a.owners == b.owners && a.performance == b.performance && (a.restore == nil) == (b.restore == nil)
    }

    var body: some View {
        let rule = item.rule
        HStack(alignment: .center, spacing: 12) {
            preview
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 4) {
                    Text(verbatim: item.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    if !item.summary.isEmpty { InfoTip(verbatim: item.summary) }
                    if item.edited { Tag(text: "Changed", symbol: "pencil").help("You made a new version of it. ✎ changes it again, or restore the original.") }
                    if let owner = item.owner { Tag(text: "\(owner) only", symbol: "person.fill").help("Only \(owner) plays this one.") }
                    if let replaces = item.replaces { Tag(text: "Instead of \(replaces)", symbol: "arrow.triangle.swap").help("Plays instead of the built-in \(replaces).") }
                    if locked {
                        Image(systemName: "lock.fill").font(.system(size: 10, weight: .semibold)).foregroundStyle(Dungeon.muted)
                            .help("Locked. It only does this in the colour it loves. You can still watch a preview.")
                    }
                }
                FlowLayout(spacing: 5, lineSpacing: 5) {
                    if rule.triggers.isEmpty {
                        Chip(title: "Only when tried", symbol: "hand.tap", live: false)
                    }
                    ForEach(AnimationTrigger.allCases.filter(rule.triggers.contains)) { t in
                        let on = live.isLive(t)
                        Chip(title: LocalizedStringKey(t.title), symbol: t.symbol, live: rule.isEnabled && on)
                            .help(on ? Text(verbatim: t.title) : Text("\(t.title) is off"))
                    }
                }
                .opacity(rule.isEnabled ? 1 : 0.5)
            }
            Spacer(minLength: 8)
            HoverIconButton(systemName: "pencil", help: item.made ? "Change \(item.title)" : "Make your own version of \(item.title)", action: edit)
            triggerMenu
            Toggle(String(""), isOn: Binding(get: { rule.isEnabled }, set: { setEnabled($0) }))
                .labelsHidden().toggleStyle(.switch).controlSize(.small)
                .help(rule.isEnabled ? "Turn off \(item.title)" : "Turn on \(item.title)")
        }
        .padding(.vertical, 6)
        .opacity(locked ? 0.55 : 1)
        .contextMenu {
            Button("Try") { play() }
            Button(item.made ? "Change…" : "Make Your Own Version…") { edit() }
            if let restore { Button("Restore Original", role: .destructive) { restore() } }
        }
    }

    /// The symbol. While it's being tried, a little Imp acting it out.
    private var preview: some View {
        Button(action: play) {
            ZStack {
                Circle().fill(Color.white.opacity(0.06))
                if let performance {
                    StageImp(hue: hue, performance: performance, traits: traits)
                        .frame(width: 52, height: 52)
                        .offset(y: -3)
                        .transition(.scale(scale: 0.4).combined(with: .opacity))
                        .task(id: performance.started) {
                            try? await Task.sleep(for: .seconds(performance.duration + 0.3))
                            finish(performance)
                        }
                } else {
                    Image(systemName: item.symbol).font(.system(size: 15, weight: .semibold)).foregroundStyle(Dungeon.muted)
                    Image(systemName: "play.fill").font(.system(size: 7, weight: .black)).foregroundStyle(Dungeon.cream)
                        .padding(3).background(Circle().fill(Color.imp(hue)))
                        .offset(x: 14, y: 14)
                }
            }
            .frame(width: 44, height: 44)
            .contentShape(Circle())
            .animation(.snappy(duration: 0.2), value: performance != nil)
        }
        .buttonStyle(.plain)
        .help("Try \(item.title)")
        .accessibilityLabel("Try \(item.title)")
    }

    @ViewBuilder private var triggerMenu: some View {
        let rule = item.rule
        HoverIconMenu(systemName: "bolt.badge.clock", help: "What starts \(item.title)") {
            Section("Starts when…") {
                ForEach(AnimationTrigger.allCases) { t in
                    Toggle(isOn: Binding(get: { rule.triggers.contains(t) }, set: { setTrigger(t, $0) })) {
                        Label(menuTitle(t), systemImage: t.symbol)
                    }
                }
            }
            if let restore {
                Divider()
                Button("Restore Original", role: .destructive) { restore() }
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
            .font(.system(size: 10, weight: .semibold, design: .rounded))
            .labelStyle(.titleAndIcon)
            .foregroundStyle(tint)
            .lineLimit(1)
            .padding(.horizontal, 6).frame(height: 17)
            .background(Capsule().fill(tint.opacity(0.16)))
    }
}

/// What starts an animation, as a small tag.
private struct Chip: View {
    let title: LocalizedStringKey
    let symbol: String
    var live = true
    @Environment(\.impTint) private var tint

    var body: some View {
        Label(title, systemImage: symbol)
            .font(.system(size: 10.5, weight: .medium))
            .labelStyle(.titleAndIcon)
            .foregroundStyle(live ? Dungeon.cream.opacity(0.9) : Dungeon.muted.opacity(0.7))
            .padding(.horizontal, 7).padding(.vertical, 2.5)
            .background(Capsule().fill(live ? tint.opacity(0.22) : Color.white.opacity(0.05)))
            .overlay(Capsule().strokeBorder(live ? tint.opacity(0.35) : Dungeon.cardEdge, lineWidth: 0.75))
            .strikethrough(!live, color: Dungeon.muted)
    }
}
