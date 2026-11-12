import ImpDesign
import ImpKit
import SwiftUI

/// The animations an Imp plays: how it follows the cursor, and the ones only it plays. The animation
/// editor opens from here.
struct MovesPanel: View {
    @Bindable var model: AppModel
    let id: UUID
    @State private var editing: AnimationDraft?
    @State private var playing: Performance?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var profile: ImpProfile { model.profile(id) ?? .imp }

    var body: some View {
        followSection
        ownSection
            .sheet(item: $editing) { AnimationEditor(model: model, draft: $0) }
    }

    // MARK: Following the cursor

    private func profileBinding<T>(_ get: @escaping (ImpProfile) -> T, _ set: @escaping (inout ImpProfile, T) -> Void) -> Binding<T> {
        Binding(get: { get(profile) },
                set: { new in if let i = model.prefs.imps.firstIndex(where: { $0.id == id }) { set(&model.prefs.imps[i], new) } })
    }

    private var followSection: some View {
        let mode = profileBinding(\.follow) { $0.follow = $1 }
        let speed = profileBinding(\.followSpeed) { $0.followSpeed = $1 }
        return PanelSection("Following the cursor", icon: "cursorarrow.motionlines", info: "moves.help.follow") {
            Row("moves.follow_how", icon: "figure.walk", info: "moves.help.follow_how") {
                ImpSegmented("moves.follow_how", selection: mode, options: FollowMode.allCases,
                             title: { $0.title }, symbol: { $0.symbol })
            }
            .settingAnchor(.movesFollowHow)
            Row("Speed", icon: "speedometer", info: "moves.help.speed") {
                RowSlider(value: speed, range: FollowMath.speedRange, label: "Speed",
                          shown: String(format: "%.1f×", speed.wrappedValue), resets: 1)
                    .disabled(!profile.follow.movesBody)
            }
            .settingAnchor(.movesSpeed)
            if reduceMotion && profile.follow.movesBody {
                StatusText(text: "Reduce Motion is on, so \(profile.callName) only follows with its eyes.",
                           symbol: "figure.walk.motion", color: Tone.warnText)
            }
        }
    }

    // MARK: Its own animations

    private var ownSection: some View {
        let own = profile.animations
        return PanelList("Its own animations", icon: "wand.and.stars", info: "moves.help.own", accessory: {
            HStack(spacing: Spacing.small) {
                if !own.isEmpty {
                    ShareKitButton(kit: Kit(name: String(localized: "\(profile.callName)'s animations"), animations: own),
                                   help: "Share \(profile.callName)'s animations as a kit")
                }
                Button { editing = .new(owner: id, model: model) } label: { FitLabel("New", systemImage: "plus") }
                    .buttonStyle(.imp(.secondary, small: true))
            }
        }) {
            VStack(alignment: .leading, spacing: Spacing.snug) {
                Row("moves.builtin", icon: "pencil", info: "moves.help.builtin") {
                    Menu {
                        ForEach(Reaction.Family.allCases, id: \.self) { family in
                            Menu(AnimationsPane.title(family)) {
                                ForEach(Reaction.allCases.filter { $0.family == family }) { r in
                                    Button(r.title) { change(r) }
                                }
                            }
                        }
                    } label: {
                        FitLabel("moves.change", systemImage: "pencil").impPill(.secondary, small: true)
                    }
                    .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                }
                .settingAnchor(.movesBuiltIn)
                .pebble()
                if own.isEmpty {
                    Text("moves.empty").font(Typeface.body).foregroundStyle(Tone.muted).padding(.horizontal, Spacing.small)
                } else {
                    let live = Live(idle: model.prefs.antics, cursor: model.prefs.mouseGames)
                    ForEach(Array(own.enumerated()), id: \.element.id) { i, a in
                        row(a, live: live)
                    }
                }
            }
        }
        .settingAnchor(.movesOwn)
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
        let rule = prefs.rule(ofMade: a, owner: id)
        let model = model, id = a.id
        var restore: (@MainActor () -> Void)?
        if a.replaces != nil { restore = { withImpAnimation(ImpDesign.Motion.expand, reduceMotion: reduceMotion) { model.prefs.removeAnimation(id) } } }
        let tempo = profile.traits.tempo
        let reduceMotion = reduceMotion
        // Its own version of a built-in one keeps the built-in one's starts.
        var setTrigger: (@MainActor (AnimationTrigger, Bool) -> Void)?
        if a.replaces == nil {
            setTrigger = { t, on in
                withImpAnimation(ImpDesign.Motion.expand, reduceMotion: reduceMotion) { model.prefs.setTrigger(t, on, animation: id) }
            }
        }
        return AnimationRow(
            item: .init(key: a.id.uuidString, title: a.title, summary: a.about, symbol: a.symbol, rule: rule,
                        owner: nil, replaces: a.replaces?.title, edited: false, made: true),
            hue: profile.hue, traits: profile.traits, locked: false, live: live, owners: [:],
            performance: playing?.key == "own-\(a.id)" ? playing : nil,
            play: { playing = Performance(key: "own-\(a.id)", steps: Antics.paced(a.beats.map(AnticStep.init), tempo: tempo)) },
            finish: { done in if playing == done { playing = nil } },
            edit: { editing = AnimationDraft(made: a, owner: id, isNew: false) },
            restore: restore,
            setEnabled: { on in model.prefs.setEnabled(on, animation: id) },
            setTrigger: setTrigger)
    }
}
