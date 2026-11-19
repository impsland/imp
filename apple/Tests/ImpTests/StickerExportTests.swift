import CoreGraphics
import Foundation
import ImpKit
import Testing
import zlib
@testable import Imp

/// An animation saved as a `.tgs` sticker meets the sticker rules: gzipped Lottie, 512×512, 60 frames a
/// second, at most 3 seconds and 64 KB, with nothing a sticker may not hold.
@MainActor
@Suite struct StickerExportTests {
    /// Every mood, every glyph and every move, one beat each: the busiest animation there can be.
    private static var everything: [AnimationBeat] {
        AnimationBeat.moods.enumerated().map { i, mood in
            AnimationBeat(duration: 0.4, lookX: i % 2 == 0 ? 0.6 : -0.6, mood: mood,
                          glyph: AnimationBeat.glyphs[i % AnimationBeat.glyphs.count], tilt: Double(i % 5) * 4, hop: i % 4 == 0,
                          stretch: i % 3 == 0 ? 0.2 : 0, move: AnimationBeat.moves[i % AnimationBeat.moves.count])
        }
    }

    private static let wave = [
        AnimationBeat(duration: 0.5, mood: "happy", glyph: "notes", hop: true),
        AnimationBeat(duration: 1.0, mood: "excited", move: "spin"),
        AnimationBeat(duration: 0.8, lookX: -0.5, mood: "love", glyph: "heart", tilt: 12),
    ]

    private func gunzip(_ data: Data) throws -> Data {
        #expect(data.prefix(2) == Data([0x1f, 0x8b]), "a gzip header")
        var stream = z_stream()
        #expect(inflateInit2_(&stream, 15 + 16, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK)
        defer { inflateEnd(&stream) }
        var out = Data(count: 4 * 1024 * 1024)
        let n: Int = data.withUnsafeBytes { input in
            out.withUnsafeMutableBytes { output in
                stream.next_in = UnsafeMutablePointer(mutating: input.bindMemory(to: Bytef.self).baseAddress)
                stream.avail_in = uInt(data.count)
                stream.next_out = output.bindMemory(to: Bytef.self).baseAddress
                stream.avail_out = uInt(output.count)
                return inflate(&stream, Z_FINISH) == Z_STREAM_END ? Int(stream.total_out) : -1
            }
        }
        try #require(n > 0)
        return out.prefix(n)
    }

    private func check(_ sticker: StickerExport.Sticker) throws -> [String: Any] {
        #expect(sticker.data.count <= StickerExport.maxBytes)
        let json = try #require(try JSONSerialization.jsonObject(with: gunzip(sticker.data)) as? [String: Any])
        #expect(json["tgs"] as? Int == 1)
        #expect(json["w"] as? Int == 512 && json["h"] as? Int == 512)
        #expect(json["fr"] as? Int == 60)
        let op = try #require(json["op"] as? Int)
        #expect(op >= 1 && op <= 180)
        let layers = try #require(json["layers"] as? [[String: Any]])
        #expect(!layers.isEmpty)
        // Only shape layers, and nothing a sticker may not hold, anywhere.
        #expect(layers.allSatisfy { $0["ty"] as? Int == 4 })
        #expect((json["assets"] as? [Any])?.isEmpty == true)
        let text = String(decoding: try gunzip(sticker.data), as: UTF8.self)
        for banned in ["\"x\":\"", "\"refId\"", "\"masksProperties\"", "\"tt\":", "\"ef\":", "\"ty\":\"rp\"", "\"ty\":\"mm\"", "\"ty\":5", "\"ty\":2,", "\"ddd\":1", "\"ao\":1", "\"tm\":"] {
            #expect(!text.contains(banned), "\(banned)")
        }
        for layer in layers {
            let ip = try #require(layer["ip"] as? Int), lop = try #require(layer["op"] as? Int)
            #expect(ip >= 0 && lop <= op && ip < lop)
        }
        return json
    }

    @Test func aShortAnimationIsASticker() throws {
        let sticker = try StickerExport.make(Self.wave, name: "Wave", hue: 0.02, traits: .plain)
        let json = try check(sticker)
        #expect(json["op"] as? Int == 138)  // 2.3 s at 60 fps
        #expect(sticker.speedUp == 1 && !sticker.trimmed)
    }

    @Test func aLongOneIsSpedUpThenCut() throws {
        let beats = Self.everything   // 20 beats of 0.4 s: 8 s
        let sticker = try StickerExport.make(beats, name: "Everything", hue: 0.6, traits: ImpTraits.presets[0].traits)
        let json = try check(sticker)
        #expect(json["op"] as? Int == 180)
        #expect(sticker.speedUp == StickerExport.maxSpeedUp && sticker.trimmed)
    }

    @Test func nothingToPlayIsSaidSo() {
        #expect(throws: StickerExport.Failure.self) { try StickerExport.make([], name: "", hue: 0, traits: .plain) }
    }

    @Test func pathsBecomeLottieShapes() {
        let path = CGMutablePath()
        path.addEllipse(in: CGRect(x: 0, y: 0, width: 10, height: 10))
        path.move(to: .zero)
        path.addLine(to: CGPoint(x: 5, y: 0))
        let parts = LottieWriter.subpaths(path)
        #expect(parts.count == 2)
        #expect(parts[0].closed && parts[0].points.count == 4)   // an ellipse is four curves, its closing point merged
        #expect(!parts[1].closed && parts[1].points.count == 2)
    }
}
