import AppKit
import Foundation
import ImpDesign
import ImpKit
import UniformTypeIdentifiers
import zlib

/// An animation as an animated sticker (`.tgs`): the Imp acting it out, drawn by the same code as on
/// screen but recorded as vector shapes (`VectorPen`), written as Lottie (`LottieWriter`) and gzipped.
/// A sticker is 512×512 at 60 frames a second, at most 3 seconds long and at most 64 KB.
enum StickerExport {
    static let maxSeconds = 3.0
    static let maxBytes = 64 * 1024
    /// A longer animation plays faster, up to this much, and is cut at 3 seconds if it is still longer.
    static let maxSpeedUp = 2.0
    /// The share of the sticker left free around the Imp.
    static let margin = 0.12

    struct Sticker {
        var data: Data
        /// How much faster than written it plays (1: as written).
        var speedUp: Double
        /// It was cut short at 3 seconds.
        var trimmed: Bool
    }

    enum Failure: LocalizedError {
        case empty, tooBig(Int)
        var errorDescription: String? {
            switch self {
            case .empty: String(localized: "sticker.error.empty")
            case .tooBig(let kb): words("sticker.error.too_big", kb)
            }
        }
    }

    /// The beats as one sticker, by an Imp of `hue` with `traits`.
    @MainActor
    static func make(_ beats: [AnimationBeat], name: String, hue: Double, traits: ImpTraits) throws -> Sticker {
        let steps = Antics.paced(beats.map(AnticStep.init), tempo: traits.tempo)
        let total = steps.reduce(0) { $0 + $1.duration }
        guard total > 0 else { throw Failure.empty }
        let speedUp = min(maxSpeedUp, max(1, total / maxSeconds))
        let paced = Antics.paced(steps, tempo: speedUp)
        let seconds = min(maxSeconds, total / speedUp)
        let frames = record(paced, frames: max(1, Int((seconds * Double(LottieWriter.fps)).rounded())), hue: hue, traits: traits)
        // Finer first; coarser keyframes and coordinates until it fits.
        var smallest = Int.max
        for (stride, decimals) in [(1, 1), (1, 0), (2, 0), (3, 0), (4, 0), (5, 0), (6, 0), (8, 0), (10, 0), (15, 0)] {
            let json = LottieWriter(stride: stride, decimals: decimals).document(frames: frames, name: name)
            let packed = gzip(json)
            if packed.count <= maxBytes { return Sticker(data: packed, speedUp: speedUp, trimmed: total / speedUp > maxSeconds + 0.001) }
            smallest = min(smallest, packed.count)
        }
        throw Failure.tooBig(smallest / 1024)
    }

    /// The shapes of each frame, as the Imp acts the steps out from a standstill.
    @MainActor
    static func record(_ steps: [AnticStep], frames: Int, hue: Double, traits: ImpTraits) -> [[VectorShape]] {
        let start = Date(timeIntervalSinceReferenceDate: 0)
        let performance = Performance(key: "sticker", steps: steps, at: start)
        let puppet = Puppet()
        let canvas = CGSize(width: LottieWriter.size, height: LottieWriter.size)
        return (0..<frames).map { i in
            let t = Double(i) / Double(LottieWriter.fps)
            let beat = performance.beat(at: start.addingTimeInterval(t))
            let cue = Puppet.Cue(mood: beat?.step.mood ?? .idle, step: beat?.step, hue: hue, gaze: nil,
                                 hopSince: beat?.hopSince, stepElapsed: beat?.elapsed, traits: traits)
            let (face, motion) = puppet.frame(cue, at: t)
            let log = VectorLog()
            var pen = VectorPen(log: log)
            // A margin all round, so a glyph over the head or a hop stays inside the sticker.
            let side = Double(LottieWriter.size)
            pen.penTranslate(side * margin / 2, side * margin / 2)
            pen.penScale(1 - margin, 1 - margin)
            ImpRenderer.draw(&pen, size: canvas, face: face, motion: motion, glyph: beat?.glyph?.glyph,
                             glyphAge: beat?.glyph?.age ?? 0, glyphFade: (beat?.glyph?.remaining ?? 0) / 0.5)
            // The same part drawn again in one frame (three notes, two blush dots) is told apart by its turn.
            var seen: [String: Int] = [:]
            return log.shapes.map { shape in
                var s = shape
                let n = seen[s.track, default: 0]
                seen[s.track] = n + 1
                s.track += "#\(n)"
                return s
            }
        }
    }

    /// `data` as a gzip file (RFC 1952): a header, the deflated bytes, their CRC-32 and length.
    static func gzip(_ data: Data) -> Data {
        var stream = z_stream()
        // windowBits 15 + 16: zlib writes the gzip header and trailer itself.
        guard deflateInit2_(&stream, Z_BEST_COMPRESSION, Z_DEFLATED, 15 + 16, 9, Z_DEFAULT_STRATEGY,
                            ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { return Data() }
        defer { deflateEnd(&stream) }
        var output = Data(count: Int(deflateBound(&stream, uLong(data.count))) + 32)
        let written: Int = data.withUnsafeBytes { input in
            output.withUnsafeMutableBytes { out in
                stream.next_in = UnsafeMutablePointer(mutating: input.bindMemory(to: Bytef.self).baseAddress)
                stream.avail_in = uInt(data.count)
                stream.next_out = out.bindMemory(to: Bytef.self).baseAddress
                stream.avail_out = uInt(out.count)
                return deflate(&stream, Z_FINISH) == Z_STREAM_END ? Int(stream.total_out) : 0
            }
        }
        return output.prefix(written)
    }

    // MARK: Saving

    /// Asks where to save the sticker and saves it. Says what was changed to make it fit, or why it can't.
    @MainActor
    static func save(_ beats: [AnimationBeat], name: String, hue: Double, traits: ImpTraits) {
        let sticker: Sticker
        do {
            sticker = try make(beats, name: name, hue: hue, traits: traits)
        } catch {
            alert(String(localized: "sticker.error.title"), error.localizedDescription)
            return
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "tgs") ?? .data]
        panel.nameFieldStringValue = (name.isEmpty ? "Imp" : name) + ".tgs"
        var notes = [String(localized: "sticker.note")]
        if sticker.speedUp > 1.001 { notes.append(words("sticker.note.faster", String(format: "%.1f", sticker.speedUp))) }
        if sticker.trimmed { notes.append(String(localized: "sticker.note.trimmed")) }
        panel.message = notes.joined(separator: " ")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try sticker.data.write(to: url, options: .atomic)
        } catch {
            alert(String(localized: "Couldn't save the file"), error.localizedDescription)
        }
    }

    @MainActor
    private static func alert(_ title: String, _ text: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.runModal()
    }
}
