import AppKit

/// One set of panels (Imp + bubble) per Imp on screen, kept in step with the troupe (and with
/// `AppModel.isHidden`).
@MainActor
final class TroupeWindows {
    private let app: AppModel
    private var panels: [UUID: Panels] = [:]
    private var shown = true
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
        let visible = !app.isHidden
        for imp in app.imps where panels[imp.id] == nil {
            let p = Panels(model: imp)
            p.menuProvider = menuProvider
            panels[imp.id] = p
            if visible { p.show() }
        }
        for (id, p) in panels where app.imp(id) == nil {
            p.close()
            panels[id] = nil
        }
        guard visible != shown else { return }
        shown = visible
        panels.values.forEach { visible ? $0.show() : $0.hide() }
    }
}
