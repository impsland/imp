import CoreGraphics
import Foundation
import ImpKit

/// One beat of an antic: hold a pose for a while.
struct AnticStep: Equatable {
    var duration: Double
    /// Where to turn. Nil: the mood decides (moods that watch the cursor keep doing so).
    var look: CGPoint? = nil
    var mood: Mood? = nil
    var glyph: Glyph? = nil
    var tilt: Double = 0
    /// Hop when this step starts.
    var hop = false
    /// Body shape, sprung like the face: + stands tall and thin, − squishes flat.
    var stretch: Double = 0
    /// A move played across the whole step: a spin, a somersault, bounces… (see `Motion.perform`).
    var move: BodyMove? = nil
}

extension [AnticStep] {
    /// The glyph showing during step `i`, `elapsed` seconds into it: how long it has shown and
    /// how long it has left. A glyph held over several steps in a row is one glyph: it pops in
    /// once and leaves once.
    func glyph(at i: Int, elapsed: Double) -> (glyph: Glyph, age: Double, remaining: Double)? {
        guard indices.contains(i), let g = self[i].glyph else { return nil }
        var age = elapsed, remaining = self[i].duration - elapsed
        var j = i - 1
        while j >= 0, self[j].glyph == g { age += self[j].duration; j -= 1 }
        j = i + 1
        while j < count, self[j].glyph == g { remaining += self[j].duration; j += 1 }
        return (g, age, remaining)
    }
}

/// A short routine Imp plays on its own.
struct Antic: Equatable {
    var name: String
    var steps: [AnticStep]
    var isWake = false
    /// Requested explicitly (a trick, a reaction): mouse movement doesn't interrupt it.
    var sticky = false
}

/// The beats of every built-in animation, read from the catalog (`spec/animations`) by `AnimationCatalog`,
/// shared by live Imps (`ImpLife`) and figures in the window (`Performance`).
enum Antics {
    /// The beats of a built-in animation.
    static func steps(for reaction: Reaction) -> [AnticStep] { reaction.beats.map(AnticStep.init) }
}

// MARK: - Animations as data

extension AnticStep {
    /// A beat as it's stored and shared (made animations, kits, the Imp's own tools).
    init(_ b: AnimationBeat) {
        self.init(duration: b.duration, look: b.hasLook ? CGPoint(x: b.lookX ?? 0, y: b.lookY ?? 0) : nil,
                  mood: b.mood.flatMap(Mood.init(rawValue:)), glyph: b.glyph.flatMap(Glyph.init(rawValue:)),
                  tilt: b.tilt, hop: b.hop, stretch: b.stretch,
                  move: b.move.flatMap(BodyMove.Kind.init(rawValue:)).map { BodyMove(kind: $0, times: b.repeats, reverse: b.reverse == true) })
    }
}

extension AnimationBeat {
    init(_ s: AnticStep) {
        self.init(duration: AnimationBeat.round(s.duration), lookX: s.look.map { AnimationBeat.round($0.x) },
                  lookY: s.look.map { AnimationBeat.round($0.y) }, mood: s.mood?.rawValue, glyph: s.glyph?.rawValue,
                  tilt: AnimationBeat.round(s.tilt), hop: s.hop, stretch: AnimationBeat.round(s.stretch),
                  move: s.move?.kind.rawValue, times: s.move?.times, reverse: s.move?.reverse == true ? true : nil)
    }

    static func round(_ x: Double) -> Double { (x * 100).rounded() / 100 }
}

extension Antics {
    /// The beats `ref` is written with for `imp` (its own version, else the shared one, else the
    /// built-in one), at its own pace: for the editor and the Imp's tools. Nil: no such animation.
    static func beats(for ref: AnimationRef, prefs: ImpPreferences, imp: UUID?) -> [AnimationBeat]? {
        switch ref {
        case .preset(let r): prefs.replacement(for: r, imp: imp)?.beats ?? r.beats
        case .custom(let id): prefs.customAnimation(id, imp: imp)?.beats
        }
    }

    /// What `imp` acts out for `ref`: its own version or the shared one if there is, at its tempo.
    static func steps(for ref: AnimationRef, prefs: ImpPreferences, imp: UUID?) -> [AnticStep] {
        let raw: [AnticStep] = switch ref {
        case .preset(let r): prefs.replacement(for: r, imp: imp).map { $0.beats.map(AnticStep.init) } ?? steps(for: r)
        case .custom(let id): prefs.customAnimation(id, imp: imp)?.beats.map(AnticStep.init) ?? []
        }
        return paced(raw, tempo: prefs.imps.first { $0.id == imp }?.traits.tempo ?? 1)
    }

    /// Every beat shorter (a quick Imp) or longer (a lazy one).
    static func paced(_ steps: [AnticStep], tempo: Double) -> [AnticStep] {
        guard tempo > 0, abs(tempo - 1) > 0.001 else { return steps }
        return steps.map { var s = $0; s.duration /= tempo; return s }
    }
}
