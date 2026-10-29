import ImpKit
import SwiftUI

/// Every animation an Imp can play: try it, turn it off, or choose what starts it.
///
/// The list is long (dozens of rows), so it's built to be cheap: the whole pane reads the
/// preferences once per render and hands each row plain values, rows only re-render when their own
/// values change (`Equatable`). (Not lazy: lazy stacks re-guess the heights of rows above when a
/// preview starts, and the page jumped.)
struct AnimationsPane: View {
    @Bindable var model: AppModel
    /// The Imp previews are played by (its colour), from the window's selection.
    var hue: Double
    /// Whether that Imp wears its favourite colour (this unlocks the animations of that family).
    var favorite = false
    @State private var playing: Performance?

    var body: some View {
        let prefs = model.prefs
        let owners = Self.owners(prefs)
        let live = Live(idle: prefs.antics, cursor: prefs.mouseGames)
        VStack(alignment: .leading, spacing: Metrics.gap) {
            ForEach(Reaction.Family.allCases, id: \.self) { family in
                familyCard(family, prefs: prefs, owners: owners, live: live)
            }
            HStack {
                Spacer()
                Button("Restore Defaults") { withAnimation(.snappy) { model.prefs.resetAnimations() } }
                    .buttonStyle(.imp(.quiet, small: true))
                    .disabled(prefs.animations.isEmpty)
                    .help("Turns every animation on, with its original starts")
            }
        }
    }

    // MARK: Cards

    @ViewBuilder
    private func familyCard(_ family: Reaction.Family, prefs: ImpPreferences, owners: [AnimationTrigger: Reaction],
                            live: Live) -> some View {
        Card(Self.title(family), icon: Self.icon(family), info: Self.subtitle(family)) {
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
            let members = Reaction.allCases.filter { $0.family == family }
            VStack(spacing: 0) {
                ForEach(Array(members.enumerated()), id: \.element) { i, reaction in
                    if i > 0 { CardDivider().padding(.vertical, 2) }
                    AnimationRow(
                        reaction: reaction, rule: prefs.rule(for: reaction), hue: hue,
                        locked: reaction.unlocksWithFavoriteColor && !favorite, live: live, owners: owners,
                        performance: playing?.reaction == reaction ? playing : nil,
                        play: { playing = Performance(reaction) },
                        finish: { done in if playing == done { withAnimation(.snappy) { playing = nil } } },
                        setEnabled: { model.prefs.setEnabled($0, for: reaction) },
                        setTrigger: { t, on in
                            withAnimation(.snappy(duration: 0.2)) { model.prefs.setTrigger(t, on, for: reaction) }
                        })
                    .equatable()
                }
            }
        }
    }

    /// Which animation holds each gesture now (one per gesture), found once for every row.
    private static func owners(_ prefs: ImpPreferences) -> [AnimationTrigger: Reaction] {
        var owners: [AnimationTrigger: Reaction] = [:]
        for r in Reaction.allCases {
            for t in prefs.rule(for: r).triggers where t.isExclusive { owners[t] = r }
        }
        return owners
    }

    private static func title(_ f: Reaction.Family) -> LocalizedStringKey {
        switch f {
        case .expressions: "Expressions"
        case .gestures: "Gestures"
        case .play: "Play"
        case .handling: "Touch"
        case .routines: "On its own"
        case .favorite: "Favourite colour"
        }
    }

    private static func icon(_ f: Reaction.Family) -> String {
        switch f {
        case .expressions: "face.smiling"
        case .gestures: "hand.raised.fill"
        case .play: "hand.point.up.left.fill"
        case .handling: "hand.raised.fingers.spread.fill"
        case .routines: "hourglass"
        case .favorite: "heart.fill"
        }
    }

    private static func subtitle(_ f: Reaction.Family) -> LocalizedStringKey {
        switch f {
        case .expressions: "Feelings it shows. Some are how Imps respond to each other."
        case .gestures: "A nod, a shake and more. None plays on its own, so give one a start or try it."
        case .play: "Mouse games, pokes and finding its favourite colour."
        case .handling: "How it reacts to tickles, cuddles, being carried, shaken, startled or stared at. Stroking needs slow strokes to and fro."
        case .routines: "Little things it does when it's quiet. The switch turns them all off."
        case .favorite: "Only while it wears the colour it loves. Find it to unlock them. Previews always work."
        }
    }
}

/// Which switches are on, as far as a trigger's chip is concerned.
private struct Live: Equatable {
    /// Doing things on its own.
    var idle: Bool
    /// Games with the cursor.
    var cursor: Bool

    func isLive(_ t: AnimationTrigger) -> Bool {
        if t == .idle { return idle }
        return t.watchesCursor ? cursor : true
    }
}

/// One animation: try it, what starts it, and a switch. Plain values in, so a row only redraws
/// when something it shows changed (the closures are ignored when comparing).
private struct AnimationRow: View, Equatable {
    let reaction: Reaction
    let rule: AnimationRule
    let hue: Double
    /// Dimmed with a lock: it plays only in its favourite colour, which this Imp isn't wearing.
    let locked: Bool
    let live: Live
    /// Who holds each gesture, for the trigger menu.
    let owners: [AnimationTrigger: Reaction]
    /// Set while it's being tried.
    let performance: Performance?
    let play: @MainActor () -> Void
    let finish: @MainActor (Performance) -> Void
    let setEnabled: @MainActor (Bool) -> Void
    let setTrigger: @MainActor (AnimationTrigger, Bool) -> Void

    nonisolated static func == (a: Self, b: Self) -> Bool {
        a.reaction == b.reaction && a.rule == b.rule && a.hue == b.hue && a.locked == b.locked
            && a.live == b.live && a.owners == b.owners && a.performance == b.performance
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            preview
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 4) {
                    Text(reaction.title).font(.system(size: 13, weight: .semibold))
                    InfoTip(verbatim: reaction.summary)
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
            triggerMenu
            Toggle(String(""), isOn: Binding(get: { rule.isEnabled }, set: { setEnabled($0) }))
                .labelsHidden().toggleStyle(.switch).controlSize(.small)
                .help(rule.isEnabled ? "Turn off \(reaction.title)" : "Turn on \(reaction.title)")
        }
        .padding(.vertical, 6)
        .opacity(locked ? 0.55 : 1)
    }

    /// The symbol. While it's being tried, a little Imp acting it out.
    private var preview: some View {
        Button(action: play) {
            ZStack {
                Circle().fill(Color.white.opacity(0.06))
                if let performance {
                    StageImp(hue: hue, performance: performance)
                        .frame(width: 52, height: 52)
                        .offset(y: -3)
                        .transition(.scale(scale: 0.4).combined(with: .opacity))
                        .task(id: performance.started) {
                            try? await Task.sleep(for: .seconds(performance.duration + 0.3))
                            finish(performance)
                        }
                } else {
                    Image(systemName: reaction.symbol).font(.system(size: 15, weight: .semibold)).foregroundStyle(Dungeon.muted)
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
        .help("Try \(reaction.title)")
        .accessibilityLabel("Try \(reaction.title)")
    }

    private var triggerMenu: some View {
        HoverIconMenu(systemName: "bolt.badge.clock", help: "What starts \(reaction.title)") {
            Section("Starts when…") {
                ForEach(AnimationTrigger.allCases) { t in
                    Toggle(isOn: Binding(get: { rule.triggers.contains(t) }, set: { setTrigger(t, $0) })) {
                        Label(menuTitle(t), systemImage: t.symbol)
                    }
                }
            }
        }
    }

    /// A gesture starts one animation: say which one has it now, since choosing it here moves it.
    private func menuTitle(_ t: AnimationTrigger) -> LocalizedStringKey {
        guard t.isExclusive, !rule.triggers.contains(t), let owner = owners[t], owner != reaction else { return LocalizedStringKey(t.title) }
        return "\(t.title) (now \(owner.title))"
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
