import ImpDesign
import ImpKit
import SwiftUI

/// Every animation, shared or an Imp's own: try it (its picture plays it), change it, share it as a kit, turn it off.
/// Saving it as a sticker is in the row's menu. A new one is shared, for every Imp.
struct SharingAnimations: View {
    @Bindable var model: AppModel
    @State private var editing: AnimationDraft?
    @State private var playing: Performance?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let listed = model.prefs.sharableAnimations
        SharingSection("animations.list", symbol: ImpSetting.animations.symbol, info: "sharing.animations.info", add: "New",
                       onAdd: { editing = .new(owner: nil, model: model) },
                       count: listed.count, kit: Kit(name: words("animations.list"), animations: listed.map(\.animation)),
                       rows: { ForEach(listed) { row($0) } })
        .settingAnchor(.sharingAnimations)
        .sheet(item: $editing) { AnimationEditor(model: model, draft: $0) }
    }

    private func row(_ item: SharedAnimation) -> some View {
        let a = item.animation
        let owner = item.owner.flatMap(model.profile)
        let maker = model.settingsImp(for: item.owner) ?? .imp
        let key = "sharing-\(a.id)"
        return SharingRow(
            title: a.title,
            kit: Kit(name: a.title, animations: [a]),
            isOn: Binding(get: { model.prefs.sharableAnimations.first { $0.id == a.id }?.animation.isEnabled ?? false },
                          set: { model.prefs.setEnabled($0, animation: a.id) }),
            edit: { editing = AnimationDraft(made: a, owner: item.owner, isNew: false) },
            leading: {
                AnimationPreview(title: a.title, symbol: a.symbol, hue: maker.hue, traits: maker.traits, compact: true,
                                 performance: playing?.key == key ? playing : nil,
                                 play: { playing = Performance(key: key, steps: Antics.paced(a.beats.map(AnticStep.init), tempo: maker.traits.tempo)) },
                                 finish: { done in
                                     if playing == done { withImpAnimation(ImpDesign.Motion.smooth, reduceMotion: reduceMotion) { playing = nil } }
                                 })
            },
            detail: { ScopeLabel(scope: owner == nil ? .everyImp : .onlyThisImp, name: owner?.callName ?? "") },
            menu: {
                Button("Try") { playing = Performance(key: key, steps: Antics.paced(a.beats.map(AnticStep.init), tempo: maker.traits.tempo)) }
                Button("sticker.export") { StickerExport.save(a.beats, name: a.title, hue: maker.hue, traits: maker.traits) }
            })
    }
}
