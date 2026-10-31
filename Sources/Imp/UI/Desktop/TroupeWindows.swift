import AppKit

/// One set of panels (Imp + bubble) per Imp on screen, kept in step with the troupe (and with
/// `AppModel.isHidden`, and with each Imp hidden on its own).
@MainActor
final class TroupeWindows {
    private let app: AppModel
    private var panels: [UUID: Panels] = [:]
    /// The Imps whose panels are showing.
    private var shown: Set<UUID> = []
    var menuProvider: ((ImpModel) -> NSMenu)? {
        didSet { panels.values.forEach { $0.menuProvider = menuProvider } }
    }

    init(app: AppModel) {
        self.app = app
        app.onTroupeChange = { [weak self] in self?.sync() }
        app.flyHome = { [weak self] id, origin, done in
            guard let panels = self?.panels[id], panels.isImpVisible else { return done() }
            panels.fly(to: origin, then: done)
        }
        app.flyOff = { [weak self] id, device, done in
            guard let panels = self?.panels[id], panels.isImpVisible else { return done() }
            panels.send(to: device, then: done)
        }
        app.flyAway = { [weak self] id, side, done in
            guard let panels = self?.panels[id], panels.isImpVisible else { return done() }
            panels.flyOff(side, speed: 1_600, then: done)
        }
        app.flyIn = { [weak self] id, entry in
            // A visitor's panels are made as it arrives.
            guard let self, let panels = self.panels[id] ?? self.makePanels(for: self.app.visitor(id)) else { return }
            self.shown.insert(id)
            panels.flyIn(entry)
        }
        sync()
    }

    private func makePanels(for imp: ImpModel?) -> Panels? {
        guard let imp else { return nil }
        let p = Panels(model: imp)
        p.menuProvider = menuProvider
        panels[imp.id] = p
        return p
    }

    private func sync() {
        for imp in app.bodies where panels[imp.id] == nil { makePanels(for: imp) }
        for (id, p) in panels where app.body(id) == nil {
            p.close()
            panels[id] = nil
            shown.remove(id)
        }
        // Each Imp shows unless everyone is hidden or it is, on its own, or it's on another device.
        for (id, p) in panels {
            let visible = !app.isHiding(id) && !app.isAway(id)
            guard visible != shown.contains(id) else { continue }
            if visible { shown.insert(id); p.show() } else { shown.remove(id); p.hide() }
        }
    }
}
