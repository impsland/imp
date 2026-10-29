import ImpKit
import SwiftUI

/// One Imp's own way of moving: its character (laid over everything it does) and the animations
/// only it plays.
struct MovesTab: View {
    @Bindable var model: AppModel
    let id: UUID
    @State private var editing: AnimationDraft?
    @State private var playing: Performance?

    private var profile: ImpProfile { model.profile(id) ?? .imp }
    private var traits: Binding<ImpTraits> {
        Binding(get: { profile.traits },
                set: { new in if let i = model.prefs.imps.firstIndex(where: { $0.id == id }) { model.prefs.imps[i].traits = new } })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.gap) {
            characterCard
            ownCard
        }
        .sheet(item: $editing) { AnimationEditor(model: model, draft: $0) }
    }

    // MARK: Character

    private var characterCard: some View {
        Card("Character", icon: "theatermasks.fill",
             info: "How \(profile.callName) always looks and moves: tired eyes, a frown, droopy horns, a slower pace. It shows in every mood and animation, and while it follows the cursor.") {
            Button("Reset") { withAnimation(.snappy) { traits.wrappedValue = .plain } }
                .buttonStyle(.imp(.quiet, small: true))
                .disabled(profile.traits.isPlain)
                .help("Back to a plain face")
        } content: {
            HStack(alignment: .top, spacing: 16) {
                VStack(spacing: 6) {
                    ZStack {
                        RoundedRectangle(cornerRadius: Metrics.corner, style: .continuous).fill(Color.black.opacity(0.22))
                        StageImp(hue: profile.hue, performance: playing, traits: profile.traits, clock: BodyClock(id))
                            .frame(width: 110, height: 110)
                            .task(id: playing?.started) {
                                guard let p = playing else { return }
                                try? await Task.sleep(for: .seconds(p.duration + 0.3))
                                if playing == p { playing = nil }
                            }
                    }
                    .frame(width: 130, height: 124)
                    Button { tryOne() } label: { Label("Try", systemImage: "play.fill") }
                        .buttonStyle(.imp(.secondary, small: true))
                        .help("Plays one of its animations with this character")
                }
                VStack(alignment: .leading, spacing: 10) {
                    EvenGrid(minWidth: 92, spacing: 6) {
                        ForEach(ImpTraits.presets) { p in
                            ChoiceChip(verbatim: "\(p.emoji) \(p.name)", picked: profile.traits.preset?.id == p.id) {
                                withAnimation(.snappy) { traits.wrappedValue = p.traits }
                            }
                        }
                    }
                    FieldRow("Lids", width: 54) {
                        LabeledSlider(value: traits.lids, range: 0...0.6, left: "Open", right: "Heavy", format: Self.percent(0.6))
                    }
                    FieldRow("Brows", width: 54) {
                        LabeledSlider(value: traits.slant, range: -1...1, left: "Worried", right: "Cross", format: { String(format: "%+.1f", $0) })
                    }
                    FieldRow("Eyes", width: 54) {
                        LabeledSlider(value: traits.eyes, range: -0.4...0.4, left: "Small", right: "Big", format: { String(format: "%+.0f%%", $0 * 100) })
                    }
                    FieldRow("Squint", width: 54) {
                        LabeledSlider(value: traits.squint, range: -1...1, left: "Wide", right: "Narrow", format: { String(format: "%+.1f", $0) })
                    }
                    FieldRow("Horns", width: 54) {
                        LabeledSlider(value: traits.horns, range: -30...30, left: "Droopy", right: "Perky", format: { "\(Int($0.rounded()))°" })
                    }
                    FieldRow("Cheeks", width: 54) {
                        LabeledSlider(value: traits.blush, range: 0...1, left: "Pale", right: "Rosy", format: Self.percent(1))
                    }
                    FieldRow("Head", width: 54) {
                        LabeledSlider(value: traits.tilt, range: -12...12, left: "Left", right: "Right", format: { "\(Int($0.rounded()))°" })
                    }
                    FieldRow("Pace", width: 54) {
                        LabeledSlider(value: traits.tempo, range: 0.6...1.6, left: "Slow", right: "Quick", format: { String(format: "%.1f×", $0) })
                    }
                }
            }
        }
    }

    private static func percent(_ max: Double) -> (Double) -> String { { "\(Int(($0 / max * 100).rounded()))%" } }

    /// One of the animations it plays when it's quiet, or a happy hop.
    private func tryOne() {
        let pool = model.prefs.refs(for: .idle, imp: id)
        let ref = pool.randomElement() ?? .preset(.jump)
        playing = Performance(ref, prefs: model.prefs, imp: id)
    }

    // MARK: Its own animations

    private var ownCard: some View {
        let own = profile.animations
        return Card("Its own animations", icon: "wand.and.stars",
                    info: "Only \(profile.callName) plays these. Make a new one, or its own version of a built-in one (it plays instead, for \(profile.callName) alone). They go along when you share or export \(profile.callName).") {
            HStack(spacing: 6) {
                if !own.isEmpty {
                    ShareKitButton(kit: Kit(name: String(localized: "\(profile.callName)'s animations"), animations: own),
                                   help: "Share \(profile.callName)'s animations as a kit")
                }
                Menu {
                    ForEach(Reaction.Family.allCases, id: \.self) { family in
                        Menu(AnimationsPane.title(family)) {
                            ForEach(Reaction.allCases.filter { $0.family == family }) { r in
                                Button(r.title) { change(r) }
                            }
                        }
                    }
                } label: {
                    Label("Change a Built-in One", systemImage: "pencil")
                }
                .menuStyle(.borderlessButton).fixedSize()
                .help("Its own version of a built-in animation")
                Button { editing = .new(owner: id, model: model) } label: { Label("New", systemImage: "plus") }
                    .buttonStyle(.imp(.secondary, small: true))
                    .help("Make an animation only \(profile.callName) plays")
            }
        } content: {
            if own.isEmpty {
                Text("None yet. \(profile.callName) can make its own too: ask it to.")
                    .font(.system(size: 12.5)).foregroundStyle(Dungeon.muted)
            } else {
                let live = Live(idle: model.prefs.antics, cursor: model.prefs.mouseGames)
                VStack(spacing: 0) {
                    ForEach(Array(own.enumerated()), id: \.element.id) { i, a in
                        if i > 0 { CardDivider().padding(.vertical, 2) }
                        row(a, live: live)
                    }
                }
            }
        }
    }

    private func change(_ reaction: Reaction) {
        if let mine = profile.animations.first(where: { $0.replaces == reaction }) {
            editing = AnimationDraft(made: mine, owner: id, isNew: false)
        } else {
            editing = .replacing(reaction, owner: id, model: model)
        }
    }

    private func row(_ a: MadeAnimation, live: Live) -> some View {
        let prefs = model.prefs
        let rule: AnimationRule = if let r = a.replaces { prefs.rule(for: r) } else { AnimationRule(isEnabled: a.isEnabled, triggers: a.triggers) }
        let model = model, id = a.id
        var restore: (@MainActor () -> Void)?
        if a.replaces != nil { restore = { withAnimation(.snappy) { model.prefs.removeAnimation(id) } } }
        let tempo = profile.traits.tempo
        return AnimationRow(
            item: .init(key: a.id.uuidString, title: a.title, summary: a.about, symbol: a.symbol, rule: rule,
                        owner: nil, replaces: a.replaces?.title, edited: false, made: true),
            hue: profile.hue, traits: profile.traits, locked: false, live: live, owners: [:],
            performance: playing?.key == "own-\(a.id)" ? playing : nil,
            play: { playing = Performance(key: "own-\(a.id)", steps: Antics.paced(a.beats.map(AnticStep.init), tempo: tempo)) },
            finish: { done in if playing == done { playing = nil } },
            edit: { editing = AnimationDraft(made: a, owner: id, isNew: false) },
            restore: restore,
            setEnabled: { on in if let r = a.replaces { model.prefs.setEnabled(on, for: r) } else { model.prefs.setEnabled(on, animation: a.id) } },
            setTrigger: { t, on in
                withAnimation(.snappy(duration: 0.2)) {
                    if let r = a.replaces { model.prefs.setTrigger(t, on, for: r) } else { model.prefs.setTrigger(t, on, animation: a.id) }
                }
            })
    }
}
