import ImpDesign
import ImpKit
import SwiftUI

/// The animations only an Imp plays, and what it may do with animations by itself. The animation
/// editor opens from here.
struct MovesPanel: View {
    @Bindable var model: AppModel
    @Binding var imp: ImpProfile
    @State private var editing: AnimationDraft?
    @State private var playing: Performance?
    @State private var triggerFor: AnimationName?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var id: UUID { imp.id }
    private var profile: ImpProfile { imp }

    var body: some View {
        ownSection
            .sheet(item: $editing) { AnimationEditor(model: model, draft: $0) }
    }

    // MARK: Animations

    private var ownSection: some View {
        let own = profile.animations
        return PanelList("moves.animations", icon: "figure.dance", info: "moves.help.own", accessory: {
            HStack(spacing: Spacing.small) {
                if !own.isEmpty {
                    ShareKitButton(kit: Kit(name: String(localized: "\(profile.callName)'s animations"), animations: own),
                                   help: "Share as a kit")
                }
                ImportKitButton(imp: id)
                AgentToolsButton(imp: $imp, groups: [.moves])
                Button { editing = .new(owner: id, model: model) } label: { FitLabel("New", systemImage: "plus") }
                    .buttonStyle(.imp(.secondary, small: true))
            }
        }) {
            VStack(alignment: .leading, spacing: Spacing.snug) {
                if own.isEmpty {
                    EmptyState("moves.empty", symbol: ImpSetting.moves.symbol, fills: true)
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
        let model = model, id = a.id, imp = profile
        let tempo = profile.traits.tempo
        return AnimationRow(
            item: .init(key: a.id.uuidString, title: a.title, summary: a.about, symbol: a.symbol, isEnabled: a.isEnabled,
                        starts: prefs.triggers(for: imp.id).filter { $0.isEnabled && $0.steps.contains { $0.animationName == a.title } }.map(\.trigger.event),
                        owner: nil, made: true),
            hue: profile.hue, traits: profile.traits,
            performance: playing?.key == "own-\(a.id)" ? playing : nil,
            play: { playing = Performance(key: "own-\(a.id)", steps: Antics.paced(a.beats.map(AnticStep.init), tempo: tempo)) },
            finish: { done in if playing == done { playing = nil } },
            edit: { editing = AnimationDraft(made: a, owner: imp.id, isNew: false) },
            setEnabled: { on in model.prefs.setEnabled(on, animation: id) },
            addTrigger: { triggerFor = AnimationName(id: a.title) },
            exportSticker: { StickerExport.save(a.beats, name: a.title, hue: imp.hue, traits: imp.traits) })
    }
}
