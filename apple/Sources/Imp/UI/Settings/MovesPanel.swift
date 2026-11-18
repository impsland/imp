import ImpDesign
import ImpKit
import SwiftUI

/// The animations only an Imp plays. The animation editor opens from here.
struct MovesPanel: View {
    @Bindable var model: AppModel
    let id: UUID
    @State private var editing: AnimationDraft?
    @State private var playing: Performance?
    @State private var triggerFor: AnimationName?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var profile: ImpProfile { model.profile(id) ?? .imp }

    var body: some View {
        ownSection
            .sheet(item: $editing) { AnimationEditor(model: model, draft: $0) }
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
                if own.isEmpty {
                    Text("moves.empty").font(Typeface.body).foregroundStyle(Tone.muted).padding(.horizontal, Spacing.small)
                } else {
                    ForEach(Array(own.enumerated()), id: \.element.id) { i, a in
                        row(a)
                    }
                }
            }
        }
        .settingAnchor(.movesOwn)
        .addTriggerSheet(model: model, imp: id, animation: $triggerFor)
    }

    private func row(_ a: MadeAnimation) -> some View {
        let prefs = model.prefs
        let model = model, id = a.id
        let tempo = profile.traits.tempo
        return AnimationRow(
            item: .init(key: a.id.uuidString, title: a.title, summary: a.about, symbol: a.symbol, isEnabled: a.isEnabled,
                        starts: prefs.triggers(for: id).filter { $0.isEnabled && $0.steps.contains { $0.animationName == a.title } }.map(\.trigger.event),
                        owner: nil, made: true),
            hue: profile.hue, traits: profile.traits,
            performance: playing?.key == "own-\(a.id)" ? playing : nil,
            play: { playing = Performance(key: "own-\(a.id)", steps: Antics.paced(a.beats.map(AnticStep.init), tempo: tempo)) },
            finish: { done in if playing == done { playing = nil } },
            edit: { editing = AnimationDraft(made: a, owner: id, isNew: false) },
            setEnabled: { on in model.prefs.setEnabled(on, animation: id) },
            addTrigger: { triggerFor = AnimationName(id: a.title) })
    }
}
