import AppKit
import ImpDesign
import ImpKit
import SwiftUI
import UniformTypeIdentifiers

/// What the canvas menus do. The right-click menus, the corner buttons and the menu bar all call these,
/// so each action exists once.
@MainActor
struct HomeActions {
    let model: AppModel
    let router: HomeRouter

    static var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    // MARK: The canvas

    /// A new Imp. With no Brain to give it (nothing to think with yet) it is hatched by the first run
    /// instead, together with its first Brain: an Imp never exists without one.
    func newImp() {
        guard model.assistant.isReady() else { return router.firstRun = .newImp(model.prefs.nextImp()) }
        router.hatch([model.addImp()])
    }

    /// Opens the Link sheet, to bring an Imp from another device.
    func linkDevice() { router.linkingDevice = true }

    func showHidden() {
        withAnimation(ImpDesign.Motion.fade.reducedAware(Self.reduceMotion)) { model.setHidden(false) }
    }

    func openSettings() { router.openGeneralSettings() }


    // MARK: The background

    /// Puts the plain background back (the Imps make the others).
    func resetBackground() { model.prefs.background = RoomBackground.defaultHTML }

    // MARK: An Imp

    func talk(_ id: UUID) {
        guard let imp = model.profile(id), imp.awayOn == nil else { return askCallHome(id) }
        // The bubble lives beside an Imp on the desktop: one at home steps out first, right where it stands.
        if !imp.isActive { model.setActive(id, true, at: slot(of: imp)?.origin) }
        model.imp(id)?.talk()
    }

    /// Opens a text box beside the Imp. One at home steps out first, as for Talk.
    func type(_ id: UUID) {
        guard let imp = model.profile(id), imp.awayOn == nil else { return askCallHome(id) }
        if !imp.isActive { model.setActive(id, true, at: slot(of: imp)?.origin) }
        model.imp(id)?.startTyping()
    }

    /// Opens the chat beside the Imp. One at home steps out first, as for Talk.
    func chat(_ id: UUID) {
        guard let imp = model.profile(id), imp.awayOn == nil else { return askCallHome(id) }
        if !imp.isActive { model.setActive(id, true, at: slot(of: imp)?.origin) }
        model.imp(id)?.openChat()
    }

    /// A new size or colour, from the Imp's menu.
    func restyle(_ id: UUID, _ change: (inout ImpProfile) -> Void) {
        guard let i = model.prefs.imps.firstIndex(where: { $0.id == id }) else { return }
        change(&model.prefs.imps[i])
    }

    func openImpSettings(_ id: UUID) {
        router.select(id)
        router.openSettings(id)
    }

    /// A click or a tap (`count` in a row) on an Imp in the window: runs the Imp's enabled click trigger
    /// for that many clicks, and nothing else. An Imp at home steps out first when the trigger needs its body.
    func click(_ id: UUID, count: Int) {
        router.select(id)
        guard let shortcut = model.prefs.clickShortcut(count, on: id, in: model.senses.state) else { return }
        switch shortcut.steps.first.flatMap({ $0.act == .open ? $0.target : nil }) {
        case .settings: openImpSettings(id)
        case .listen: talk(id)
        default:
            guard let imp = model.profile(id), imp.awayOn == nil else { return }
            if !imp.isActive { model.setActive(id, true, at: slot(of: imp)?.origin) }
            model.imp(id)?.perform(shortcut)
        }
    }

    func openBubble(_ id: UUID) {
        guard let imp = model.profile(id), imp.awayOn == nil else { return askCallHome(id) }
        if !imp.isActive { model.setActive(id, true, at: slot(of: imp)?.origin) }
        model.imp(id)?.clicked(1)
    }

    /// Lets an Imp out right where it stands, or flies it home to the same place. Either can be undone.
    /// One away on another device is asked back instead (Call Home).
    func toggleActive(_ id: UUID) {
        guard let imp = model.profile(id) else { return }
        guard imp.awayOn == nil else { return askCallHome(id) }
        let slot = slot(of: imp)
        if !imp.isActive {
            model.setActive(id, true, at: slot?.origin)
            offerUndo(.letOut, id) { model.setActive(id, false) }
        } else {
            let from = model.imp(id)?.impFrame.origin
            let arrive: @MainActor @Sendable () -> Void = { model.setActive(id, false); offerUndoHome(id, from: from) }
            if let slot, let fly = model.flyHome { fly(id, slot.origin, arrive) } else { arrive() }
        }
    }

    /// The dragged Imp's frame is no longer wholly in the window: it is let out and the same drag goes on
    /// in its own window. `figure` is where the Imp is drawn on screen and `pointer` what holds it, so the
    /// panel appears exactly there and the grab is kept to the point.
    func dragOut(_ id: UUID, figure: CGRect, pointer: CGPoint) {
        guard let imp = model.profile(id), imp.awayOn == nil, !imp.isActive else { return }
        let grab = ImpDrag.grab(pointer: pointer, centre: CGPoint(x: figure.midX, y: figure.midY))
        model.setActive(id, true, at: figure.origin)
        model.carryOut?(id, grab)
        offerUndo(.letOut, id) { model.setActive(id, false) }
    }

    /// A free Imp was let go over the window: it goes home, to where it is drawn (`centre`, on screen),
    /// which is under the pointer by the grab it was held with.
    func dropHome(_ id: UUID, centre: CGPoint, from origin: CGPoint) {
        guard let imp = model.profile(id) else { return }
        if let place = router.place(atScreen: centre, side: Panels.baseSize * imp.scale) { router.places[id] = place }
        model.setActive(id, false)
        offerUndoHome(id, from: origin)
    }

    private func offerUndo(_ kind: UndoOffer.Kind, _ id: UUID, revert: @escaping @MainActor () -> Void) {
        router.offer(UndoOffer(kind, imp: id, seconds: Behavior.undoBarSeconds), revert: revert)
    }

    private func offerUndoHome(_ id: UUID, from origin: CGPoint?) {
        offerUndo(.sendHome, id) { model.setActive(id, true, at: origin) }
    }

    /// Brings a hidden Imp back: onto the canvas where it stood, or onto the desktop if it was out there.
    func bringBack(_ id: UUID) {
        withAnimation(ImpDesign.Motion.fade.reducedAware(Self.reduceMotion)) { model.setHidden(id, false) }
    }

    func hide(_ id: UUID) {
        withAnimation(ImpDesign.Motion.fade.reducedAware(Self.reduceMotion)) { model.setHidden(id, true) }
        offerUndo(.hide, id) { bringBack(id) }
    }

    func copyKit(_ id: UUID) { if let kit = kit(id) { KitSharing.copy(kit) } }

    func copyLink(_ id: UUID) { if let kit = kit(id) { KitSharing.copyLink(kit) } }

    func canShareLink(_ id: UUID) -> Bool { kit(id)?.stamped.link != nil }

    /// Goodbye asks first: the window shows the question (see `HomeView`).
    func askGoodbye(_ id: UUID) { router.saying = id }

    /// An Imp away on another device: the window asks whether to take it back.
    func askCallHome(_ id: UUID) {
        guard model.isAway(id) else { return }
        router.select(id)
        router.callingHome = id
    }

    /// Takes it back from the device that holds it, even one that is gone for good.
    func callHome(_ id: UUID) {
        router.callingHome = nil
        model.callHome(id)
    }

    /// Say goodbye for good. Another Imp takes the keyboard.
    func sayGoodbye(_ id: UUID) {
        router.saying = nil
        let next = model.sayGoodbye(id)
        router.places[id] = nil
        router.selection = next
    }

    var canSayGoodbye: Bool { !model.prefs.imps.isEmpty }

    // MARK: Several Imps at once

    /// Hides them all. Undo brings them all back.
    func hide(_ ids: [UUID]) {
        guard let first = ids.first else { return }
        withAnimation(ImpDesign.Motion.fade.reducedAware(Self.reduceMotion)) { for id in ids { model.setHidden(id, true) } }
        offerUndo(.hide, first) { for id in ids { bringBack(id) } }
    }

    /// Lets out every one still at home, each where it stands. Undo takes them all back in.
    func free(_ ids: [UUID]) {
        let home = ids.compactMap(model.profile).filter { !$0.isActive && $0.awayOn == nil }
        guard let first = home.first else { return }
        for imp in home { model.setActive(imp.id, true, at: slot(of: imp)?.origin) }
        router.clearPicks()
        offerUndo(.letOut, first.id) { for imp in home { model.setActive(imp.id, false) } }
    }

    /// One kit with all of them.
    func copyKit(_ ids: [UUID]) {
        let name = words("menu.group.title", ids.count)
        KitSharing.copy(ImpExport.kit(Set(ids), model: model, name: name))
    }

    /// The same Brain for all: nil is the shared one, else a service with its own model.
    func setBrain(_ ids: [UUID], _ brain: Brain?) {
        var p = model.prefs
        for i in p.imps.indices where ids.contains(p.imps[i].id) { p.imps[i].brain = brain }
        model.changeByPerson(p)
    }

    /// A new size or colour for all of them.
    func restyle(_ ids: [UUID], _ change: (inout ImpProfile) -> Void) {
        for i in model.prefs.imps.indices where ids.contains(model.prefs.imps[i].id) { change(&model.prefs.imps[i]) }
    }

    func canSayGoodbye(to ids: [UUID]) -> Bool { ImpPicks.canSayGoodbye(to: ids.count, of: model.prefs.imps.count) }

    /// Goodbye asks first, once for all of them (see `HomeView`).
    func askGoodbye(_ ids: [UUID]) {
        if ids.count == 1, let id = ids.first { return askGoodbye(id) }
        router.sayingMany = ids
    }

    /// Say goodbye to all of them for good. Having no Imp is fine.
    func sayGoodbye(_ ids: [UUID]) {
        router.sayingMany = nil
        guard canSayGoodbye(to: ids) else { return }
        var next: UUID?
        for id in ids {
            next = model.sayGoodbye(id) ?? next
            router.places[id] = nil
        }
        router.clearPicks()
        router.selection = next
    }

    /// "Let out" while it is at home, "Send home" once it is out, "Call Home…" while it is on another device.
    func releaseTitle(_ id: UUID) -> String {
        guard let imp = model.profile(id) else { return String(localized: "menu.imp.let_out") }
        if imp.awayOn != nil { return String(localized: "menu.imp.call_home_ask") }
        return String(localized: imp.isActive ? "menu.imp.send_home" : "menu.imp.let_out")
    }

    /// Always: an Imp away on another device can be called home from here, whatever became of that device.
    func canRelease(_ id: UUID) -> Bool { model.profile(id) != nil }

    func label(_ id: UUID) -> String {
        guard let imp = model.profile(id) else { return "" }
        let state = imp.awayOn != nil ? words("imp.state.away", model.link.name(of: imp.awayOn ?? id) ?? "iPhone")
            : String(localized: model.isHiding(id) ? "imp.state.hidden" : imp.isActive ? "imp.state.out" : "imp.state.awake")
        return words("imp.a11y.label", imp.name, state)
    }

    private func slot(of imp: ImpProfile) -> CGRect? { router.slot(of: imp.id, side: Panels.baseSize * imp.scale) }

    private func kit(_ id: UUID) -> Kit? {
        guard let imp = model.profile(id) else { return nil }
        return ImpExport.kit([id], model: model, name: imp.callName)
    }
}
