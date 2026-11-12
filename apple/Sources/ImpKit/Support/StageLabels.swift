import Foundation

/// When the words around an Imp on the main screen (its speech bubble, thinking dots and name tag) may be seen.
/// None of them while a game is on (they are dropped from view and return when it ends, a bubble
/// whose own timer ran out meanwhile does not come back), and none over the Imp whose context menu
/// is open or about to open, so nothing is left behind its lifted preview.
public enum StageLabels {
    public static func showsWords(playing: Bool, menuFor: UUID?, imp: UUID) -> Bool {
        !playing && menuFor != imp
    }
}
