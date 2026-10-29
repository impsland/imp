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
        sync()
    }

    private func sync() {
        for imp in app.imps where panels[imp.id] == nil {
            let p = Panels(model: imp)
            p.menuProvider = menuProvider
            panels[imp.id] = p
        }
        for (id, p) in panels where app.imp(id) == nil {
            p.close()
            panels[id] = nil
            shown.remove(id)
        }
        // Each Imp shows unless everyone is hidden or it is, on its own.
        for (id, p) in panels {
            let visible = !app.isHiding(id)
            guard visible != shown.contains(id) else { continue }
            if visible { shown.insert(id); p.show() } else { shown.remove(id); p.hide() }
        }
    }
}
