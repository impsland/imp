import ImpDesign
import ImpKit
import SwiftUI

/// Every trigger, shared or an Imp's own: change it in the trigger editor, share it as a kit, turn it off.
/// A new one is shared, for every Imp.
struct SharingTriggers: View {
    let model: AppModel
    @State private var draft: Draft?

    /// A trigger being added or changed, and who it is for.
    private struct Draft: Identifiable {
        var shortcut: Shortcut
        let isNew: Bool
        let owner: UUID?
        var id: UUID { shortcut.id }
    }

    var body: some View {
        let listed = model.prefs.sharableTriggers
        SharingSection("triggers.title", symbol: ImpSetting.triggers.symbol, info: "sharing.triggers.info", add: "New", onAdd: add,
                       count: listed.count, kit: model.prefs.kit(sharing: listed.map(\.shortcut), named: words("triggers.title")),
                       importAnchor: true, rows: { ForEach(listed) { row($0) } })
            .settingAnchor(.sharingTriggers)
            .sheet(item: $draft) { item in
                // Always a whole editor: an empty sheet can't be closed and holds the window. With no Imp to try it
                // on (none yet), a shared trigger is edited for every Imp, without Try.
                let imp = model.settingsImp(for: item.owner)
                ShortcutSheet(model: model, imp: imp?.id, shortcut: item.shortcut, isNew: item.isNew,
                              scope: item.owner == nil ? .everyImp : .onlyThisImp, target: item.owner.map(ScopeTarget.imp) ?? .everyImp,
                              save: { save($0, for: $1) },
                              duplicate: { copy($0, of: item) },
                              delete: { remove(item) })
                    .environment(\.impTint, imp.map { Color.imp($0.hue) } ?? Color.imp)
                    .tint(imp.map { Color.imp($0.hue) } ?? Color.imp)
            }
    }

    private func row(_ item: SharedTrigger) -> some View {
        let shortcut = item.shortcut
        let owner = item.owner.flatMap(model.profile)
        let target = model.settingsImp(for: item.owner)
        return SharingRow(
            title: shortcut.sentence,
            kit: model.prefs.kit(sharing: shortcut, named: shortcut.displayName, imp: item.owner),
            isOn: Binding(get: { model.prefs.shortcuts.first { $0.id == item.id }?.isEnabled ?? false },
                          set: { model.prefs.setEnabled($0, trigger: item) }),
            edit: { draft = Draft(shortcut: shortcut, isNew: false, owner: item.owner) },
            leading: { IconTile(systemName: shortcut.symbol) },
            detail: { ScopeLabel(scope: owner == nil ? .everyImp : .onlyThisImp, name: owner?.callName ?? "") },
            menu: {
                if let target {
                    Button(words("sharing.open_in", target.callName)) { open(target.id) }
                }
            })
    }

    private func add() {
        var s = Shortcut(name: "", trigger: .starter(.click), steps: [])
        s.id = UUID()
        draft = Draft(shortcut: s, isNew: true, owner: nil)
    }

    private func save(_ shortcut: Shortcut, for target: ScopeTarget) {
        var s = shortcut
        if s.name.trimmingCharacters(in: .whitespaces).isEmpty { s.name = String(s.trigger.summary.prefix(Shortcut.maxNameLength)) }
        if s.trigger.event != .keys { s.hotkey = nil }
        model.prefs.saveTrigger(s, for: target)
        draft = nil
    }

    private func copy(_ shortcut: Shortcut, of item: Draft) {
        var copy = shortcut
        copy.id = UUID()
        copy.overrides = nil
        copy.name = String(localized: "\(shortcut.displayName) copy")
        copy.hotkey = nil                       // two triggers on the same keys would just fight
        draft = Draft(shortcut: copy, isNew: true, owner: item.owner)
    }

    private func remove(_ item: Draft) {
        draft = nil
        if item.owner == nil { model.prefs.removeSharedTrigger(item.id) } else if let owner = item.owner { model.prefs.removeTrigger(item.id, for: owner) }
    }

    private func open(_ imp: UUID) {
        let router = HomeWindow.shared.router
        router.select(imp)
        router.openSettings(imp, panel: .triggers)
    }
}
