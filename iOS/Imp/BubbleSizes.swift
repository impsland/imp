import ImpKit
import SwiftUI

/// The sizes of the talk bubbles on the stage. Working out how big a bubble comes out means
/// counting the lines of its text, so it is done once per speech (again when a streaming reply
/// grows), not every frame.
@MainActor
final class BubbleSizes {
    private var known: [UUID: (speech: LinkSpeech, size: CGSize)] = [:]

    /// About how big `speech` comes out, and whether it's new or changed since last asked.
    func size(of speech: LinkSpeech) -> (size: CGSize, isNew: Bool) {
        if let hit = known[speech.id], hit.speech == speech { return (hit.size, false) }
        let size = SpeechBubble.size(of: speech)
        known[speech.id] = (speech, size)
        return (size, true)
    }

    /// Forgets the speeches that are gone.
    func keep(_ ids: [UUID]) {
        guard known.count > ids.count else { return }
        let ids = Set(ids)
        known = known.filter { ids.contains($0.key) }
    }
}
