import ImpKit
import SwiftUI
import Testing
@testable import Imp

/// How far an Imp's drawing reaches outside its own square while it acts: the iPhone draws each Imp in
/// a canvas of its own size, so whatever reaches further is cut off.
@MainActor
@Suite struct ImpBoundsTests {
    /// The drawn area of every frame of `steps`, in the Imp's design units (its square is 0…100).
    static func reach(_ steps: [AnticStep], mood: Mood = .idle, traits: ImpTraits = .plain) -> CGRect {
        let puppet = Puppet()
        var union = CGRect.null
        var start = 0.0
        for step in steps {
            var t = 0.0
            while t < step.duration {
                var cue = Puppet.Cue(mood: step.mood ?? mood, step: step, hue: 0)
                cue.traits = traits
                cue.stepElapsed = t
                cue.hopSince = step.hop ? t : nil
                let (face, motion) = puppet.frame(cue, at: start + t)
                union = union.union(drawn(face: face, motion: motion, glyph: step.glyph, age: t))
                t += 1.0 / 15
            }
            start += step.duration
        }
        return union
    }

    /// The box of what one frame covers, on a canvas three times the Imp's size with the Imp in the middle.
    static func drawn(face: Face, motion: Motion, glyph: Glyph? = nil, age: Double = 0) -> CGRect {
        let renderer = ImageRenderer(content: Canvas { ctx, _ in
            ctx.translateBy(x: 100, y: 100)
            ImpRenderer.draw(&ctx, size: CGSize(width: 100, height: 100), face: face, motion: motion, shadow: false, glyph: glyph, glyphAge: age, glyphFade: 1)
        }.frame(width: 300, height: 300))
        renderer.scale = 1
        guard let image = renderer.cgImage, let data = image.dataProvider?.data, let bytes = CFDataGetBytePtr(data) else { return .null }
        let w = image.width, h = image.height, row = image.bytesPerRow, bpp = image.bitsPerPixel / 8
        var minX = w, minY = h, maxX = -1, maxY = -1
        for y in 0..<h { for x in 0..<w where bytes[y * row + x * bpp + 3] > 8 {
            minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
        } }
        guard maxX >= 0 else { return .null }
        return CGRect(x: minX - 100, y: minY - 100, width: maxX - minX + 1, height: maxY - minY + 1)
    }

    /// The iPhone gives each Imp room past its square (`ImpFigure.stageBleed`: 45 % above, 30 % left, 45 % right,
    /// 10 % below): the worst a made animation can do has to fit in it.
    @Test func theWorstAnImpCanDoFitsTheRoomItIsGiven() {
        let room = CGRect(x: -30, y: -45, width: 175, height: 155)
        let wild = ImpTraits(horns: 30, tilt: 12, tempo: 1.6)
        for move in AnimationBeat.moves {
            for tilt in [-30.0, 30] {
                let r = Self.reach([AnticStep(AnimationBeat(duration: 1.6, glyph: "notes", tilt: tilt, hop: true, stretch: 0.3, move: move, times: 3))], traits: wild)
                #expect(room.contains(r), "\(move), tilt \(tilt): \(r)")
            }
        }
    }

    /// A hop (15 units) and a flip in the same frame add up to 33 units of lift. On the desktop the Imp's square is
    /// all the room it has, so however high a frame asks to lift, the lift is lowered to fit above the head: the top
    /// of the Imp is never cut off by the edge of its square.
    @Test func aLiftHigherThanTheRoomIsLoweredNotCutOff() {
        for headH in [1.0, 1.15] {
            for lift in [Motion.hopHeight, Motion.hopHeight * 1.2, Motion.hopHeight * 2.2] {
                var face = Face(.idle)
                face.headH = headH; face.horn = 25; face.hornSize = 1.3
                var motion = Motion(t: 0)
                motion.lift = lift
                let top = Self.drawn(face: face, motion: motion).minY
                let rest = ImpRenderer.restingTop(face)
                #expect(top >= min(rest, ImpRenderer.headMargin) - 1, "headH \(headH), lift \(lift): top \(top), rest \(rest)")
            }
        }
    }
}
