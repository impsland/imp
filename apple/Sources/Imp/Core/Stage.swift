import AppKit
import ImpKit

/// How the Imps notice each other. While one Imp is busy with you (thinking, listening),
/// the idle ones turn to watch it. When it has a moment (an answer, an error, a hop), the others
/// may respond after a beat (see `Contagion`). Nobody copies anyone exactly.
@MainActor
final class Stage {
    private unowned let app: AppModel

    init(app: AppModel) { self.app = app }

    /// Where an idle Imp should look: at whichever other Imp is most "on stage", if any.
    func focus(for imp: ImpModel) -> CGPoint? {
        let imps = app.desktopImps
        guard imps.count > 1, !imp.isBusy, imp.bubble == nil else { return nil }
        let best = imps.filter { $0 !== imp }
            .map { ($0, Self.presence($0)) }
            .filter { $0.1 > 0 }
            .max { $0.1 < $1.1 }
        return best?.0.headOnScreen.center
    }

    /// How much attention an Imp draws right now.
    private static func presence(_ imp: ImpModel) -> Int {
        switch imp.activity {
        case .thinking, .tools: return 3
        case .listening, .typing: return 2
        case nil: return imp.bubble != nil ? 1 : 0
        }
    }

    /// An Imp had a moment. The others may join in, staggered, facing it.
    func broadcast(_ event: StageEvent, from source: ImpModel) {
        guard let response = Contagion.response(to: event), app.prefs.isEnabled(response) else { return }
        for other in app.desktopImps where other !== source && !other.isBusy && Double.random(in: 0...1) < Contagion.chance {
            let delay = Double.random(in: 0.25...0.9)
            Task { [weak other, weak source] in
                try? await Task.sleep(for: .seconds(delay))
                guard let other, let source, !other.isBusy else { return }
                other.life.perform(response, facing: Gaze.toward(source.headOnScreen.center, from: other.impCenter))
            }
        }
    }

    /// An Imp was dropped near others: they say hello to each other. Whether anyone was there.
    @discardableResult
    func arrived(_ imp: ImpModel) -> Bool {
        for other in app.desktopImps where other !== imp && !other.isBusy {
            guard hypot(other.impCenter.x - imp.impCenter.x, other.impCenter.y - imp.impCenter.y) < 260 else { continue }
            imp.life.perform(.greet, facing: Gaze.toward(other.impCenter, from: imp.impCenter))
            Task { [weak other, weak imp] in
                try? await Task.sleep(for: .seconds(0.45))
                guard let other, let imp else { return }
                other.life.perform(.greet, facing: Gaze.toward(imp.impCenter, from: other.impCenter))
            }
            return true
        }
        return false
    }
}
