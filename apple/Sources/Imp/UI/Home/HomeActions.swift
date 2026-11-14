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

    func newImp() {
        router.hatch([model.addImp()])
    }

    func showHidden() {
        withAnimation(ImpDesign.Motion.fade.reducedAware(Self.reduceMotion)) { model.setHidden(false) }
    }

    func openSettings() { router.openGeneralSettings() }


    // MARK: The background

    func setBackground(_ kind: CanvasBackground.Kind) {
        if kind.usesImage, model.prefs.background.image == nil {
            choosePicture(becoming: kind)
        } else {
            model.prefs.background.kind = kind
        }
    }

    /// Asks for a picture. `kind` is what the background becomes: the current picture or tile choice if it is one already.
    func choosePicture(becoming kind: CanvasBackground.Kind? = nil) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = String(localized: "background.tile_hint")
        Task { @MainActor in
            guard await panel.begin() == .OK, let url = panel.url else { return }
            adopt(url, becoming: kind ?? (model.prefs.background.kind.usesImage ? model.prefs.background.kind : .picture))
        }
    }

    /// Copies the picture in and uses it. A file that can't be used changes nothing.
    func adopt(_ url: URL, becoming kind: CanvasBackground.Kind) {
        do {
            let name = try BackgroundFiles.adopt(url, replacing: model.prefs.background.image)
            model.prefs.background.image = name
            model.prefs.background.kind = kind
        } catch {
            router.pictureFailed = true
        }
    }

    func chooseColour() {
        model.prefs.background.kind = .colour
        BackgroundColourPanel.shared.show(current: model.prefs.background.colour) { colour in
            model.prefs.background.colour = colour
        }
    }

    // MARK: An Imp

    func talk(_ id: UUID) {
        guard let imp = model.profile(id), imp.awayOn == nil else { return askCallHome(id) }
        // The bubble lives beside an Imp on the desktop: one at home steps out first, right where it stands.
        if !imp.isActive { model.setActive(id, true, at: slot(of: imp)?.origin) }
        model.imp(id)?.talk()
    }

    func openImpSettings(_ id: UUID) {
        router.select(id)
        router.openSettings(id)
    }

    /// A click or a tap (`count` in a row) on an Imp in the window. One opens its bubble, which lives
    /// beside an Imp on the desktop, so an Imp at home steps out first. Two or more run the Imp's triggers.
    func click(_ id: UUID, count: Int) {
        router.select(id)
        guard count > 1 else { return openBubble(id) }
        guard let shortcut = model.prefs.clickShortcut(count, on: id, in: model.senses.state) else { return }
        switch shortcut.command {
        case .settings: openImpSettings(id)
        case .talk: talk(id)
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
        guard let next = model.sayGoodbye(id) else { return }
        router.places[id] = nil
        router.select(next)
    }

    var canSayGoodbye: Bool { model.prefs.imps.count > 1 }

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

/// The system colour panel, for the canvas's colour.
@MainActor
final class BackgroundColourPanel: NSObject {
    static let shared = BackgroundColourPanel()
    private var onChange: ((CanvasBackground.Colour) -> Void)?

    func show(current: CanvasBackground.Colour, onChange: @escaping (CanvasBackground.Colour) -> Void) {
        self.onChange = onChange
        let panel = NSColorPanel.shared
        panel.setTarget(nil)
        panel.color = NSColor(srgbRed: current.red, green: current.green, blue: current.blue, alpha: 1)
        panel.showsAlpha = false
        panel.isContinuous = true
        panel.setTarget(self)
        panel.setAction(#selector(changed(_:)))
        panel.orderFront(nil)
    }

    @objc private func changed(_ panel: NSColorPanel) {
        guard let c = panel.color.usingColorSpace(.sRGB) else { return }
        onChange?(CanvasBackground.Colour(red: c.redComponent, green: c.greenComponent, blue: c.blueComponent))
    }
}
