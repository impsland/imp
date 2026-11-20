import ImpDesign
import ImpKit
import SwiftUI

/// The animations an Imp plays (its own first, then the shared ones it has no version of), and what
/// it may do with animations by itself. The animation editor opens from here. Changing a shared one
/// changes it for every Imp.
struct AnimationsPanel: View {
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
        let listed = model.prefs.listedAnimations(for: id)
        let own = profile.animations
        return PanelList("animations.list", icon: "figure.dance", info: "animations.help.list", accessory: {
            HStack(spacing: Spacing.small) {
                HoverIconButton(systemName: SectionAction.add, help: "New") { editing = .new(owner: id, model: model) }
                ImportKitButton(imp: id)
                if !own.isEmpty {
                    ShareKitButton(kit: Kit(name: String(localized: "\(profile.callName)'s animations"), animations: own),
                                   help: "Share as a kit")
                }
                AgentToolsButton(model: model, imp: $imp, groups: [.animations])
            }
        }) {
            VStack(alignment: .leading, spacing: Spacing.snug) {
                if listed.isEmpty {
                    EmptyState("animations.empty", symbol: ImpSetting.animations.symbol, fills: true)
                } else {
                    ForEach(listed) { row($0) }
                }
            }
        }
        .settingAnchor(.animationsOwn)
        .addTriggerSheet(model: model, imp: id, animation: $triggerFor)
    }

    private func row(_ listed: ListedAnimation) -> some View {
        let a = listed.animation
        let owner: UUID? = listed.isShared ? nil : self.id
        let prefs = model.prefs
        let model = model, id = a.id, imp = profile
        let tempo = profile.traits.tempo
        return AnimationRow(
            item: .init(key: a.id.uuidString, title: a.title, summary: a.about, symbol: a.symbol, isEnabled: a.isEnabled,
                        starts: prefs.triggers(for: imp.id).filter { $0.isEnabled && $0.steps.contains { $0.animationName == a.title } }.map(\.trigger.event),
                        owner: nil, made: true, scope: listed.scope, scopeName: imp.callName),
            hue: profile.hue, traits: profile.traits,
            performance: playing?.key == "own-\(a.id)" ? playing : nil,
            play: { playing = Performance(key: "own-\(a.id)", steps: Antics.paced(a.beats.map(AnticStep.init), tempo: tempo)) },
            finish: { done in if playing == done { playing = nil } },
            edit: { editing = AnimationDraft(made: a, owner: owner, isNew: false) },
            setEnabled: { on in model.prefs.setEnabled(on, animation: id) },
            addTrigger: { triggerFor = AnimationName(id: a.title) },
            exportSticker: { StickerExport.save(a.beats, name: a.title, hue: imp.hue, traits: imp.traits) })
    }
}
