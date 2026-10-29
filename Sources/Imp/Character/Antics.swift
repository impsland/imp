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

/// The beats of every animation, shared by live Imps (`ImpLife`) and figures in the window (`Performance`).
enum Antics {
    /// The beats of an animation. `work`: where on screen you're probably working (for routines
    /// that glance at it).
    static func steps(for reaction: Reaction, work: CGPoint) -> [AnticStep] {
        let center = CGPoint.zero, user = CGPoint(x: 0, y: 0.1)
        return switch reaction {
        case .greet: [   // a friendly double nod
            AnticStep(duration: 0.2, look: CGPoint(x: 0, y: 0.5)), AnticStep(duration: 0.2, look: user),
            AnticStep(duration: 0.2, look: CGPoint(x: 0, y: 0.45)), AnticStep(duration: 1.0, look: user, mood: .happy),
        ]
        case .jump: [
            AnticStep(duration: 0.75, look: CGPoint(x: 0, y: -0.3), mood: .surprised, hop: true),
            AnticStep(duration: 0.9, look: center, mood: .happy),
        ]
        case .smile: [AnticStep(duration: 1.8, look: user, mood: .happy)]
        case .love: [AnticStep(duration: 2.0, look: user, mood: .love)]
        case .laugh: [
            AnticStep(duration: 0.75, look: CGPoint(x: 0.1, y: -0.2), mood: .happy, tilt: -6, hop: true),
            AnticStep(duration: 1.2, look: user, mood: .happy, tilt: 6),
        ]
        case .sad: [AnticStep(duration: 2.2, look: CGPoint(x: -0.2, y: 0.5), mood: .sad)]
        case .wow: [AnticStep(duration: 1.6, look: user, mood: .surprised, glyph: .exclaim)]
        case .sleep: [AnticStep(duration: 2.8, look: CGPoint(x: 0, y: 0.35), mood: .sleepy)]
        case .thanks: [  // a slow little bow
            AnticStep(duration: 0.55, look: CGPoint(x: 0, y: 0.75)), AnticStep(duration: 1.4, look: user, mood: .love),
        ]
        case .bye: [
            AnticStep(duration: 0.3, look: CGPoint(x: -0.4, y: 0), tilt: -8), AnticStep(duration: 0.3, look: CGPoint(x: 0.4, y: 0), tilt: 8),
            AnticStep(duration: 0.3, look: CGPoint(x: -0.4, y: 0), tilt: -8), AnticStep(duration: 0.9, look: user, mood: .happy),
        ]
        case .dizzy: [
            AnticStep(duration: 2.6, look: CGPoint(x: 0.15, y: -0.1), mood: .dizzy),
            AnticStep(duration: 0.5, look: center, mood: .surprised),
        ]
        case .mean: [    // stops following the cursor and stares you down
            AnticStep(duration: 2.4, look: CGPoint(x: 0, y: 0.05), mood: .mean),
            AnticStep(duration: 0.4, look: CGPoint(x: 0.6, y: 0.1), mood: .mean, tilt: 4),
        ]
        case .pet: [AnticStep(duration: 1.8, look: CGPoint(x: 0, y: -0.35), mood: .love, tilt: 5)]
        case .angry: [   // stamps, fumes at you, then turns away in a huff
            AnticStep(duration: 0.45, look: user, mood: .annoyed, glyph: .exclaim, hop: true),
            AnticStep(duration: 1.3, look: CGPoint(x: 0, y: 0.2), mood: .annoyed, tilt: -3),
            AnticStep(duration: 0.9, look: CGPoint(x: 0.75, y: -0.1), mood: .mean, tilt: 7),
        ]
        case .delight: [ // a gasp, a hop, then hearts
            AnticStep(duration: 0.4, look: user, mood: .surprised, glyph: .exclaim),
            AnticStep(duration: 1.6, look: user, mood: .love, tilt: -5, hop: true),
            AnticStep(duration: 0.8, look: user, mood: .happy, tilt: 4),
        ]
        case .glance: [
            AnticStep(duration: .random(in: 1.4...2.2),
                      look: CGPoint(x: .random(in: -0.9...0.9), y: .random(in: -0.7...0.5)),
                      tilt: .random(in: -5...5)),
        ]
        case .lookAround: [
            AnticStep(duration: 1.0, look: CGPoint(x: -0.85, y: -0.2)),
            AnticStep(duration: 1.0, look: CGPoint(x: 0.85, y: -0.3)),
            AnticStep(duration: 0.8, look: CGPoint(x: 0, y: 0.25)),
        ]
        case .turn: [
            AnticStep(duration: 0.7, look: CGPoint(x: -0.95, y: 0), tilt: -6),
            AnticStep(duration: 0.7, look: CGPoint(x: 0.95, y: 0), tilt: 6),
            AnticStep(duration: 0.6, look: .zero),
        ]
        case .hum: [
            AnticStep(duration: .random(in: 3...4.5), look: CGPoint(x: 0.25, y: -0.45), mood: .happy, glyph: .notes, tilt: 5),
            // A contented beat after the tune: eyes ease open, head comes back.
            AnticStep(duration: 0.7, look: CGPoint(x: 0.1, y: -0.1), tilt: 2),
        ]
        case .showOff: [
            AnticStep(duration: 0.8, look: .zero, mood: .surprised, glyph: .exclaim),
            AnticStep(duration: 1.8, look: CGPoint(x: 0.9, y: 0.35), mood: .happy, tilt: 8),
        ]
        case .wonder: [
            AnticStep(duration: 2.4, look: CGPoint(x: -0.5, y: -0.7), mood: .thinking, glyph: .question, tilt: -6),
        ]
        case .idea: [
            AnticStep(duration: 1.4, look: CGPoint(x: 0.3, y: -0.8), mood: .thinking),
            AnticStep(duration: 1.5, look: .zero, mood: .happy, glyph: .idea),
        ]
        case .nap: [
            AnticStep(duration: 2.4, look: CGPoint(x: 0, y: 0.35), mood: .sleepy),
            AnticStep(duration: 0.6, look: .zero, mood: .surprised, glyph: .exclaim),
        ]
        case .watch: [AnticStep(duration: .random(in: 3...5), look: work, tilt: 4)]
        case .dance: [   // bops side to side, humming
            AnticStep(duration: 0.5, look: CGPoint(x: -0.3, y: -0.1), mood: .happy, glyph: .notes, tilt: -10, hop: true),
            AnticStep(duration: 0.5, look: CGPoint(x: 0.3, y: -0.1), mood: .happy, glyph: .notes, tilt: 10),
            AnticStep(duration: 0.5, look: CGPoint(x: -0.3, y: -0.1), mood: .happy, glyph: .notes, tilt: -10, hop: true),
            AnticStep(duration: 0.5, look: CGPoint(x: 0.3, y: -0.1), mood: .happy, glyph: .notes, tilt: 10),
            AnticStep(duration: 0.7, look: user, mood: .content),
        ]
        case .yawn: [    // a big sleepy stretch, a little sag, back to normal
            AnticStep(duration: 1.1, look: CGPoint(x: 0, y: -0.35), mood: .sleepy, stretch: 0.12),
            AnticStep(duration: 0.45, look: CGPoint(x: 0, y: 0.1), stretch: -0.05),
            AnticStep(duration: 0.6, look: user),
        ]
        case .sneeze: [  // winds up, achoo, dazed
            AnticStep(duration: 0.7, look: CGPoint(x: 0, y: -0.4), mood: .surprised, stretch: 0.06),
            AnticStep(duration: 0.4, look: CGPoint(x: 0, y: 0.5), mood: .error, hop: true, stretch: -0.1),
            AnticStep(duration: 0.8, look: user, mood: .bored),
        ]
        case .peekaboo: [ // hides its eyes, then pops back up
            AnticStep(duration: 1.0, look: CGPoint(x: 0, y: 1), stretch: -0.12),
            AnticStep(duration: 0.75, look: user, mood: .surprised, glyph: .exclaim, hop: true, stretch: 0.06),
            AnticStep(duration: 0.8, look: user, mood: .giggly),
        ]
        case .stargaze: [
            AnticStep(duration: 2.4, look: CGPoint(x: -0.2, y: -0.85), glyph: .sparkles, tilt: -4),
            AnticStep(duration: 0.9, look: CGPoint(x: 0, y: -0.3), mood: .content),
        ]
        case .bored: [   // flat lids, then a sigh that sinks it a little
            AnticStep(duration: 2.0, mood: .bored),
            AnticStep(duration: 0.7, look: CGPoint(x: 0.3, y: 0.2), mood: .bored, stretch: -0.06),
            AnticStep(duration: 0.5, look: user),
        ]
        case .wiggle: [  // a quick happy shimmy
            AnticStep(duration: 0.14, look: CGPoint(x: -0.2, y: -0.1), mood: .excited, tilt: -12, hop: true),
            AnticStep(duration: 0.14, look: CGPoint(x: 0.2, y: -0.1), mood: .excited, tilt: 12),
            AnticStep(duration: 0.14, look: CGPoint(x: -0.2, y: -0.1), mood: .excited, tilt: -12),
            AnticStep(duration: 0.14, look: CGPoint(x: 0.2, y: -0.1), mood: .excited, tilt: 12),
            AnticStep(duration: 0.14, look: CGPoint(x: -0.2, y: -0.1), mood: .excited, tilt: -12),
            AnticStep(duration: 0.8, look: user, mood: .happy),
        ]
        case .sneak: [   // low and wary: a look left, a look right, then a grin
            AnticStep(duration: 0.5, look: CGPoint(x: -0.8, y: 0.1), mood: .mean, stretch: -0.12),
            AnticStep(duration: 0.7, look: CGPoint(x: 0.8, y: 0.1), mood: .mean, tilt: 5, stretch: -0.12),
            AnticStep(duration: 0.8, look: user, mood: .giggly, stretch: -0.04),
        ]

        // Expressions
        case .boo: [     // ducks out of sight, springs up, giggles
            AnticStep(duration: 0.55, look: CGPoint(x: 0, y: 0.6), stretch: -0.15),
            AnticStep(duration: 0.8, look: user, mood: .annoyed, glyph: .exclaim, hop: true, stretch: 0.08),
            AnticStep(duration: 0.9, look: user, mood: .giggly),
        ]
        case .shiver: [AnticStep(duration: 1.8, look: CGPoint(x: 0.2, y: 0.3), mood: .scared, glyph: .sweat)]
        case .blowKiss: [
            AnticStep(duration: 0.6, mood: .shy),
            AnticStep(duration: 1.1, look: user, mood: .love, glyph: .heart, tilt: -6),
        ]
        case .heartbeat: [ // swells and shrinks twice, like a pulse
            AnticStep(duration: 0.3, look: user, mood: .love, glyph: .heart, stretch: 0.1),
            AnticStep(duration: 0.3, look: user, mood: .love, glyph: .heart, stretch: -0.08),
            AnticStep(duration: 0.3, look: user, mood: .love, glyph: .heart, stretch: 0.1),
            AnticStep(duration: 0.9, look: user, mood: .love, glyph: .heart, stretch: -0.08),
            AnticStep(duration: 0.5, look: user, mood: .content),
        ]
        case .proud: [AnticStep(duration: 1.8, look: CGPoint(x: 0.1, y: -0.5), mood: .happy, glyph: .sparkles, stretch: 0.1)]

        // How you handle it. Several are kept going while you do (see `ImpLife.sustain`).
        case .giggle: [
            AnticStep(duration: 0.5, look: CGPoint(x: -0.1, y: -0.1), mood: .giggly, tilt: -6, hop: true),
            AnticStep(duration: 0.6, look: CGPoint(x: 0.1, y: -0.1), mood: .giggly, tilt: 6),
            AnticStep(duration: 0.5, look: user, mood: .happy, tilt: -3),
        ]
        case .cuddle: [
            AnticStep(duration: 0.35, look: user, mood: .content, stretch: -0.06),
            AnticStep(duration: 1.4, look: user, mood: .content, glyph: .heart, tilt: 4, stretch: -0.08),
        ]
        case .wheee: [   // gasps, then looks down at the world going by
            AnticStep(duration: 0.35, look: CGPoint(x: 0, y: -0.3), mood: .surprised, glyph: .exclaim),
            AnticStep(duration: 1.2, look: CGPoint(x: 0, y: 0.45), mood: .excited),
        ]
        case .woozy: [   // dizzy, then shakes it off, unimpressed
            AnticStep(duration: 1.8, look: CGPoint(x: 0.1, y: -0.1), mood: .dizzy),
            AnticStep(duration: 0.14, look: CGPoint(x: -0.5, y: 0)), AnticStep(duration: 0.14, look: CGPoint(x: 0.5, y: 0)),
            AnticStep(duration: 0.14, look: CGPoint(x: -0.5, y: 0)), AnticStep(duration: 0.8, look: user, mood: .bored),
        ]
        case .plop: [    // set down: a look left, a look right, then back to you
            AnticStep(duration: 0.6, look: CGPoint(x: -0.7, y: -0.05)),
            AnticStep(duration: 0.6, look: CGPoint(x: 0.7, y: -0.05)),
            AnticStep(duration: 0.4, look: user),
        ]
        case .flinch: [
            AnticStep(duration: 0.25, look: user, mood: .surprised, glyph: .exclaim, stretch: -0.1),
            AnticStep(duration: 1.6, look: CGPoint(x: 0.3, y: 0.35), mood: .scared, glyph: .sweat),
        ]
        case .curious: [AnticStep(duration: 2.2, mood: .curious, glyph: .question)]   // eyes on the cursor
        case .shy: [
            AnticStep(duration: 0.3, look: user, mood: .surprised),
            AnticStep(duration: 2.0, mood: .shy, glyph: .sweat),
        ]
        case .pounce: [  // watches the dangling cursor, then hops for it
            AnticStep(duration: 0.7, mood: .excited),
            AnticStep(duration: Motion.hopLength, mood: .excited, hop: true),
            AnticStep(duration: Motion.hopLength, mood: .excited, hop: true),
            AnticStep(duration: 0.6, look: user, mood: .happy),
        ]
        case .missedYou: [
            AnticStep(duration: 0.35, look: user, mood: .surprised, glyph: .exclaim),
            AnticStep(duration: 0.9, look: user, mood: .excited, glyph: .heart, hop: true),
            AnticStep(duration: 0.8, look: user, mood: .love),
        ]

        // Body language for answers: short and readable, so a few can play in a row.
        case .yes: [     // two nods
            AnticStep(duration: 0.18, look: CGPoint(x: 0, y: 0.45)), AnticStep(duration: 0.18, look: user),
            AnticStep(duration: 0.18, look: CGPoint(x: 0, y: 0.45)), AnticStep(duration: 0.7, look: user, mood: .happy),
        ]
        case .no: [      // a head shake
            AnticStep(duration: 0.18, look: CGPoint(x: -0.5, y: 0.1)), AnticStep(duration: 0.18, look: CGPoint(x: 0.5, y: 0.1)),
            AnticStep(duration: 0.18, look: CGPoint(x: -0.5, y: 0.1)), AnticStep(duration: 0.18, look: CGPoint(x: 0.5, y: 0.1)),
            AnticStep(duration: 0.5, look: user),
        ]
        case .maybe: [
            AnticStep(duration: 0.5, look: CGPoint(x: -0.3, y: -0.1), tilt: -10),
            AnticStep(duration: 0.5, look: CGPoint(x: 0.3, y: -0.1), tilt: 10),
            AnticStep(duration: 0.4, look: user),
        ]
        case .dontKnow: [  // looks for the answer, doesn't find it, shrugs
            AnticStep(duration: 0.6, look: CGPoint(x: -0.4, y: -0.6), mood: .thinking, tilt: -6),
            AnticStep(duration: 1.1, look: user, mood: .surprised, glyph: .question, tilt: 7, hop: true),
        ]
        case .areYouSure: [AnticStep(duration: 1.5, look: CGPoint(x: 0.1, y: 0.15), mood: .mean, glyph: .question, tilt: 9)]
        case .notSure: [  // looks away, thinking, then a puzzled tilt
            AnticStep(duration: 0.8, look: CGPoint(x: -0.6, y: 0.2), mood: .thinking, tilt: -4),
            AnticStep(duration: 0.9, look: CGPoint(x: 0.3, y: -0.2), mood: .curious, glyph: .question),
        ]
        case .exactly: [
            AnticStep(duration: 0.6, look: user, mood: .happy, hop: true),
            AnticStep(duration: 0.2, look: CGPoint(x: 0, y: 0.5)), AnticStep(duration: 0.6, look: user, mood: .happy),
        ]
        case .nope: [    // a stern shake, then turns away
            AnticStep(duration: 0.22, look: CGPoint(x: -0.6, y: 0.1), mood: .mean),
            AnticStep(duration: 0.22, look: CGPoint(x: 0.6, y: 0.1), mood: .mean),
            AnticStep(duration: 0.9, look: CGPoint(x: 0.75, y: 0.05), mood: .mean, tilt: 6),
        ]
        case .hmm: [AnticStep(duration: 1.6, look: CGPoint(x: 0.35, y: -0.7), mood: .thinking, tilt: -5)]
        case .aha: [
            AnticStep(duration: 0.8, look: CGPoint(x: 0.3, y: -0.7), mood: .thinking),
            AnticStep(duration: 1.0, look: user, mood: .surprised, glyph: .idea, hop: true),
        ]
        case .tada: [
            AnticStep(duration: 0.4, look: user, mood: .surprised),
            AnticStep(duration: 1.2, look: user, mood: .happy, tilt: -6, hop: true),
        ]
        case .sorry: [
            AnticStep(duration: 0.5, look: CGPoint(x: 0, y: 0.8)),
            AnticStep(duration: 1.2, look: CGPoint(x: 0, y: 0.4), mood: .sad),
        ]
        case .oops: [    // startles, winces, then a sheepish look away
            AnticStep(duration: 0.45, look: user, mood: .surprised, glyph: .exclaim),
            AnticStep(duration: 0.5, look: CGPoint(x: -0.3, y: 0.3), mood: .error),
            AnticStep(duration: 0.9, mood: .shy, glyph: .sweat),
        ]
        case .impressed: [
            AnticStep(duration: 0.7, look: user, mood: .surprised, glyph: .exclaim),
            AnticStep(duration: 0.9, look: user, mood: .happy),
        ]
        case .haha: [
            AnticStep(duration: 0.55, look: CGPoint(x: 0.1, y: -0.2), mood: .happy, tilt: -6, hop: true),
            AnticStep(duration: 0.55, look: user, mood: .happy, tilt: 6),
            AnticStep(duration: 0.45, look: user, mood: .happy, tilt: -3),
        ]
        case .loveIt: [AnticStep(duration: 1.8, look: user, mood: .love, tilt: 5)]
        case .sadNews: [AnticStep(duration: 2.0, look: CGPoint(x: 0, y: 0.5), mood: .sad)]
        case .careful: [
            AnticStep(duration: 0.4, look: user, mood: .surprised, glyph: .exclaim, hop: true),
            AnticStep(duration: 1.2, look: user, glyph: .exclaim),
        ]
        case .welcome: [
            AnticStep(duration: 0.5, look: CGPoint(x: 0, y: 0.7)),
            AnticStep(duration: 1.1, look: user, mood: .happy),
        ]
        case .phew: [    // braced, then a big sigh of relief
            AnticStep(duration: 0.8, look: CGPoint(x: 0.2, y: 0.3), mood: .scared, glyph: .sweat, stretch: 0.05),
            AnticStep(duration: 1.0, look: CGPoint(x: 0, y: 0.4), mood: .content, stretch: -0.1),
            AnticStep(duration: 0.5, look: user, mood: .happy),
        ]
        case .smug: [    // chin up, pleased with itself
            AnticStep(duration: 0.4, look: user),
            AnticStep(duration: 1.6, look: CGPoint(x: 0.15, y: -0.5), mood: .content, tilt: 7, stretch: 0.04),
        ]
        case .confused: [ // a puzzled tilt one way, then the other
            AnticStep(duration: 0.8, look: CGPoint(x: -0.3, y: -0.2), mood: .curious, glyph: .question, tilt: -12),
            AnticStep(duration: 0.8, look: CGPoint(x: 0.3, y: -0.2), mood: .curious, glyph: .question, tilt: 2),
            AnticStep(duration: 0.4, look: user),
        ]

        // Only while it wears its favourite colour.
        case .twirl: [   // spins its gaze all the way round, sparkling
            AnticStep(duration: 0.3, look: CGPoint(x: 0, y: 0.4), mood: .excited, stretch: -0.05),
            AnticStep(duration: 0.28, look: CGPoint(x: 0.9, y: 0.1), mood: .excited, glyph: .sparkles, tilt: 8),
            AnticStep(duration: 0.28, look: CGPoint(x: 0, y: -0.85), mood: .excited, glyph: .sparkles),
            AnticStep(duration: 0.28, look: CGPoint(x: -0.9, y: 0.1), mood: .excited, glyph: .sparkles, tilt: -8),
            AnticStep(duration: 0.28, look: CGPoint(x: 0, y: 0.7), mood: .excited, glyph: .sparkles),
            AnticStep(duration: 0.28, look: CGPoint(x: 0.9, y: 0.1), mood: .excited, glyph: .sparkles, tilt: 8),
            AnticStep(duration: 0.28, look: CGPoint(x: 0, y: -0.85), mood: .excited, glyph: .sparkles),
            AnticStep(duration: 1.0, look: user, mood: .happy, glyph: .sparkles, stretch: 0.06),
        ]
        case .serenade: [ // hums a love song, swaying, hearts drifting up
            AnticStep(duration: 0.5, look: CGPoint(x: 0, y: -0.3), mood: .content),
            AnticStep(duration: 1.2, look: CGPoint(x: -0.3, y: -0.35), mood: .love, glyph: .notes, tilt: -7),
            AnticStep(duration: 1.2, look: CGPoint(x: 0.3, y: -0.35), mood: .love, glyph: .notes, tilt: 7),
            AnticStep(duration: 1.0, look: user, mood: .love, glyph: .heart, tilt: -3),
        ]
        case .cheer: [   // three happy hops
            AnticStep(duration: Motion.hopLength, look: CGPoint(x: 0, y: -0.3), mood: .happy, tilt: -6, hop: true),
            AnticStep(duration: Motion.hopLength, look: CGPoint(x: 0, y: -0.3), mood: .excited, glyph: .sparkles, tilt: 6, hop: true),
            AnticStep(duration: Motion.hopLength, look: CGPoint(x: 0, y: -0.35), mood: .happy, glyph: .sparkles, tilt: -6, hop: true),
            AnticStep(duration: 0.7, look: user, mood: .content),
        ]
        case .swoon: [   // melts, hearts, a dreamy tilt
            AnticStep(duration: 0.5, look: CGPoint(x: 0.2, y: -0.3), mood: .surprised),
            AnticStep(duration: 1.6, look: CGPoint(x: 0.35, y: -0.2), mood: .love, glyph: .heart, tilt: 9, stretch: -0.08),
            AnticStep(duration: 1.4, look: CGPoint(x: 0.3, y: -0.1), mood: .content, glyph: .heart, tilt: 6, stretch: -0.1),
            AnticStep(duration: 0.6, look: user, mood: .happy),
        ]
        case .glow: [    // stands tall and proud, sparkling
            AnticStep(duration: 0.5, look: CGPoint(x: 0, y: -0.2), mood: .content, stretch: 0.04),
            AnticStep(duration: 1.8, look: CGPoint(x: 0.1, y: -0.55), mood: .happy, glyph: .sparkles, stretch: 0.14),
            AnticStep(duration: 0.7, look: user, mood: .content, stretch: 0.04),
        ]
        }
    }
}

// MARK: - Animations as data

extension AnticStep {
    /// A beat as it's stored and shared (made animations, kits, the Imp's own tools).
    init(_ b: AnimationBeat) {
        self.init(duration: b.duration, look: b.hasLook ? CGPoint(x: b.lookX ?? 0, y: b.lookY ?? 0) : nil,
                  mood: b.mood.flatMap(Mood.init(rawValue:)), glyph: b.glyph.flatMap(Glyph.init(rawValue:)),
                  tilt: b.tilt, hop: b.hop, stretch: b.stretch)
    }
}

extension AnimationBeat {
    init(_ s: AnticStep) {
        self.init(duration: AnimationBeat.round(s.duration), lookX: s.look.map { AnimationBeat.round($0.x) },
                  lookY: s.look.map { AnimationBeat.round($0.y) }, mood: s.mood?.rawValue, glyph: s.glyph?.rawValue,
                  tilt: AnimationBeat.round(s.tilt), hop: s.hop, stretch: AnimationBeat.round(s.stretch))
    }

    static func round(_ x: Double) -> Double { (x * 100).rounded() / 100 }
}

extension Antics {
    /// The beats `ref` is written with for `imp` (its own version, else the shared one, else the
    /// built-in one), at its own pace: for the editor and the Imp's tools. Nil: no such animation.
    static func beats(for ref: AnimationRef, prefs: ImpPreferences, imp: UUID?) -> [AnimationBeat]? {
        switch ref {
        case .preset(let r): prefs.replacement(for: r, imp: imp)?.beats ?? steps(for: r, work: .zero).map(AnimationBeat.init)
        case .custom(let id): prefs.customAnimation(id, imp: imp)?.beats
        }
    }

    /// What `imp` acts out for `ref`: its own version or the shared one if there is, at its tempo.
    static func steps(for ref: AnimationRef, prefs: ImpPreferences, imp: UUID?, work: CGPoint = .zero) -> [AnticStep] {
        let raw: [AnticStep] = switch ref {
        case .preset(let r): prefs.replacement(for: r, imp: imp).map { $0.beats.map(AnticStep.init) } ?? steps(for: r, work: work)
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
