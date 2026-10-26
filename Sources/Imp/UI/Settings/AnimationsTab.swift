import ImpKit
import SwiftUI

/// Every animation an Imp can play: try it, switch it off, or choose what starts it. Also how
/// clicks and mouse games work, since those are what start most of them.
struct AnimationsPane: View {
    @Bindable var model: AppModel
    /// The Imp previews are played by (its colour), from the window's selection.
    var hue: Double
    @State private var playing: Performance?

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.gap) {
            clicks
            play
            ForEach(Reaction.Family.allCases, id: \.self) { family in
                Card(Self.title(family), icon: Self.icon(family), info: Self.subtitle(family)) {
                    VStack(spacing: 0) {
                        let members = Reaction.allCases.filter { $0.family == family }
                        ForEach(Array(members.enumerated()), id: \.element) { i, reaction in
                            if i > 0 { CardDivider().padding(.vertical, 2) }
                            AnimationRow(model: model, reaction: reaction, hue: hue, playing: $playing)
                        }
                    }
                }
            }
            HStack {
                Spacer()
                Button("Restore Defaults") { withAnimation(.snappy) { model.prefs.resetAnimations() } }
                    .buttonStyle(.imp(.quiet, small: true))
                    .disabled(model.prefs.animations.isEmpty)
                    .help("Every animation switched on, with its original triggers")
            }
        }
    }

    // MARK: Cards

    private var clicks: some View {
        Card("Clicks", icon: "cursorarrow.click",
             info: "A click waits a moment to be sure you're not double-clicking or poking, so each burst of clicks does just one thing.") {
            Row("Click", info: "⌥-click does the other one. Clicking while it thinks stops it.") {
                Picker("", selection: $model.prefs.click) {
                    Label("Opens a text box", systemImage: "keyboard").tag(ClickAction.type)
                    Label("Starts listening", systemImage: "mic").tag(ClickAction.talk)
                }
                .labelsHidden().fixedSize()
            }
            CardDivider()
            Row("Double-click opens settings", info: "Double-click an Imp on your desktop to open its page here.") {
                Toggle("", isOn: $model.prefs.doubleClickOpensSettings).labelsHidden().toggleStyle(.switch).controlSize(.small)
            }
            CardDivider()
            Row("4 quick clicks", info: "Pokes it. What it does about that is up to you: give any animation below the Poke trigger.") {
                TriggerOwner(name: model.prefs.animation(for: .poke)?.title)
            }

        }
    }

    private var play: some View {
        Card("When animations play", icon: "sparkles",
             info: "Right-click an Imp for its own menu: talk, type, settings, colour, size, send home.") {
            Row("On its own", info: "Little routines when it's quiet (see “On its own” below).") {
                Toggle("", isOn: $model.prefs.antics).labelsHidden().toggleStyle(.switch).controlSize(.small)
            }
            CardDivider()
            Row("Mouse games", info: "Circling an Imp, swishing past its face, stroking or tickling its head, resting the cursor on it or beside it, bobbing it above.") {
                Toggle("", isOn: $model.prefs.mouseGames).labelsHidden().toggleStyle(.switch).controlSize(.small)
            }
        }
    }

    private static func title(_ f: Reaction.Family) -> String {
        switch f {
        case .expressions: "Expressions"
        case .gestures: "Gestures"
        case .play: "Games and feelings"
        case .handling: "Handle with care"
        case .routines: "On its own"
        }
    }

    private static func icon(_ f: Reaction.Family) -> String {
        switch f {
        case .expressions: "face.smiling"
        case .gestures: "hand.raised.fill"
        case .play: "hand.point.up.left.fill"
        case .handling: "hand.raised.fingers.spread.fill"
        case .routines: "hourglass"
        }
    }

    private static func subtitle(_ f: Reaction.Family) -> String {
        switch f {
        case .expressions: "Feelings it shows. Some are how the Imps respond to each other. Give any of them a trigger."
        case .gestures: "A nod for yes, a shake for no and more. None plays on its own: give one a trigger, or just try it."
        case .play: "Mouse games, pokes, and finding its favourite colour."
        case .handling: "How it feels about what you do to it: tickles, cuddles, being carried, shaken, startled or stared at. Stroking needs slow strokes to and fro, so heading for it to drag it never counts."
        case .routines: "Little things it does when nothing else is going on."
        }
    }
}

/// One animation: try it, what starts it, and a switch.
private struct AnimationRow: View {
    @Bindable var model: AppModel
    let reaction: Reaction
    let hue: Double
    @Binding var playing: Performance?

    var body: some View {
        let rule = model.prefs.rule(for: reaction)
        HStack(alignment: .center, spacing: 12) {
            preview
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 4) {
                    Text(reaction.title).font(.system(size: 13, weight: .semibold))
                    InfoTip(reaction.summary)
                }
                FlowLayout(spacing: 5, lineSpacing: 5) {
                    if rule.triggers.isEmpty {
                        Chip(title: "Only when you try it", symbol: "hand.tap", live: false)
                    }
                    ForEach(AnimationTrigger.allCases.filter(rule.triggers.contains)) { t in
                        Chip(title: t.title, symbol: t.symbol, live: rule.isEnabled && isLive(t))
                            .help(isLive(t) ? t.title : "\(t.title) is switched off above")
                    }
                }
                .opacity(rule.isEnabled ? 1 : 0.5)
            }
            Spacer(minLength: 8)
            triggerMenu(rule)
            Toggle("", isOn: Binding(get: { rule.isEnabled }, set: { model.prefs.setEnabled($0, for: reaction) }))
                .labelsHidden().toggleStyle(.switch).controlSize(.small)
                .help(rule.isEnabled ? "Switch \(reaction.title) off" : "Switch \(reaction.title) on")
        }
        .padding(.vertical, 6)
    }

    /// The symbol. While it's being tried, a little Imp acting it out.
    private var preview: some View {
        let mine = playing?.reaction == reaction ? playing : nil
        return Button {
            playing = Performance(reaction)
        } label: {
            ZStack {
                Circle().fill(Color.white.opacity(0.06))
                if let mine {
                    StageImp(hue: hue, performance: mine)
                        .frame(width: 52, height: 52)
                        .offset(y: -3)
                        .transition(.scale(scale: 0.4).combined(with: .opacity))
                        .task(id: mine.started) {
                            try? await Task.sleep(for: .seconds(mine.duration + 0.3))
                            if playing == mine { withAnimation(.snappy) { playing = nil } }
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
            .animation(.snappy(duration: 0.2), value: mine != nil)
        }
        .buttonStyle(.plain)
        .help("Try \(reaction.title)")
        .accessibilityLabel("Try \(reaction.title)")
    }

    private func triggerMenu(_ rule: AnimationRule) -> some View {
        HoverIconMenu(systemName: "bolt.badge.clock", help: "What starts \(reaction.title)") {
            Section("Starts when…") {
                ForEach(AnimationTrigger.allCases) { t in
                    Toggle(isOn: Binding(get: { rule.triggers.contains(t) },
                                         set: { on in withAnimation(.snappy(duration: 0.2)) { model.prefs.setTrigger(t, on, for: reaction) } })) {
                        Label(menuTitle(t, rule: rule), systemImage: t.symbol)
                    }
                }
            }
        }
    }

    /// A gesture starts one animation: say which one has it now, since choosing it here moves it.
    private func menuTitle(_ t: AnimationTrigger, rule: AnimationRule) -> String {
        guard t.isExclusive, !rule.triggers.contains(t),
              let owner = Reaction.allCases.first(where: { $0 != reaction && model.prefs.rule(for: $0).triggers.contains(t) })
        else { return t.title }
        return "\(t.title) (now: \(owner.title))"
    }

    /// Whether the switch above that governs this trigger is on.
    private func isLive(_ t: AnimationTrigger) -> Bool {
        if t == .idle { return model.prefs.antics }
        return t.watchesCursor ? model.prefs.mouseGames : true
    }
}

/// A trigger, as a small tag.
private struct Chip: View {
    let title: String
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

/// Which animation a gesture plays, or that it plays none.
private struct TriggerOwner: View {
    let name: String?

    var body: some View {
        Text(name ?? "Nothing")
            .font(.system(size: 12, weight: .semibold, design: .rounded))
            .foregroundStyle(name == nil ? Dungeon.muted : Dungeon.cream)
            .padding(.horizontal, 9).padding(.vertical, 3)
            .background(Capsule().fill(Color.white.opacity(0.07)))
    }
}
