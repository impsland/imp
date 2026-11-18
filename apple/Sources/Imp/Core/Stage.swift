import AppKit
import ImpKit

/// How the Imps notice each other. While one Imp is busy with you (thinking, listening),
/// the idle ones turn to watch it. Looking is all they do: nothing plays on its own.
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
}
