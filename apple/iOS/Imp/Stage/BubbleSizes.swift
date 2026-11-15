import ImpKit
import SwiftUI

/// The sizes of the talk bubbles on the stage, and the side of its Imp each one is on. Working out how big a
/// bubble comes out means counting the lines of its text, so it is done once per speech (again when a
/// streaming reply grows), not every frame. The side is kept so a bubble stays where it is while it can.
@MainActor
final class BubbleSizes {
    private var known: [UUID: (speech: LinkSpeech, size: CGSize)] = [:]
    private var edges: [UUID: Edge] = [:]

    /// The edge the tail of this speech's bubble grew from last time.
    func edge(of speech: UUID) -> Edge? { edges[speech] }

    func keep(edge: Edge, for speech: UUID) { edges[speech] = edge }

    /// About how big `speech` comes out, and whether it's new or changed since last asked.
    func size(of speech: LinkSpeech) -> (size: CGSize, isNew: Bool) {
        if let hit = known[speech.id], hit.speech == speech { return (hit.size, false) }
        let size = SpeechBubble.size(of: speech)
        known[speech.id] = (speech, size)
        return (size, true)
    }

    /// Forgets the speeches that are gone.
    func keep(_ ids: [UUID]) {
        guard known.count > ids.count || edges.count > ids.count else { return }
        let ids = Set(ids)
        known = known.filter { ids.contains($0.key) }
        edges = edges.filter { ids.contains($0.key) }
    }
}

/// Where a talk bubble goes on the stage: its body (the tail not included), the edge its tail grows from, and the
/// point on the Imp the tail points at.
struct BubblePlace {
    var speech: LinkSpeech
    var frame: CGRect
    var edge: Edge
    var target: CGPoint

    /// Where the tail points, from the middle of its edge.
    var tail: CGFloat {
        switch edge {
        case .top, .bottom: target.x - frame.midX
        case .leading, .trailing: target.y - frame.midY
        }
    }

    /// The middle of the tail's edge: the bubble hangs from it.
    var anchor: CGPoint {
        switch edge {
        case .bottom: CGPoint(x: frame.midX, y: frame.maxY)
        case .top: CGPoint(x: frame.midX, y: frame.minY)
        case .leading: CGPoint(x: frame.minX, y: frame.midY)
        case .trailing: CGPoint(x: frame.maxX, y: frame.midY)
        }
    }

    /// How the bubble lines up with its anchor.
    var alignment: Alignment {
        switch edge {
        case .bottom: .bottom
        case .top: .top
        case .leading: .leading
        case .trailing: .trailing
        }
    }

    /// The point it grows from as it comes in: its tail's edge.
    var unit: UnitPoint {
        switch edge {
        case .bottom: .bottom
        case .top: .top
        case .leading: .leading
        case .trailing: .trailing
        }
    }
}
