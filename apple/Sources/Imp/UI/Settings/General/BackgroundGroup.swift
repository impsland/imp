import ImpDesign
import ImpKit
import SwiftUI

/// The Background group of the Look card: one choice and, for the kinds that need one, the action that
/// finishes it, shown only then.
enum BackgroundGroup {
    /// What a kind needs after it is chosen.
    enum Follow: Equatable { case colour, picture }

    static let kinds = CanvasBackground.Kind.allCases

    static func follow(_ kind: CanvasBackground.Kind) -> Follow? {
        switch kind {
        case .theme: nil
        case .colour: .colour
        case .picture, .tile: .picture
        }
    }

    static func symbol(_ kind: CanvasBackground.Kind) -> String {
        switch kind {
        case .theme: "flame.fill"
        case .colour: "paintpalette.fill"
        case .picture: "photo.fill"
        case .tile: "square.grid.2x2.fill"
        }
    }

    static func title(_ kind: CanvasBackground.Kind) -> String {
        switch kind {
        case .theme: String(localized: "background.theme")
        case .colour: String(localized: "background.colour")
        case .picture: String(localized: "background.picture")
        case .tile: String(localized: "background.tile")
        }
    }
}
