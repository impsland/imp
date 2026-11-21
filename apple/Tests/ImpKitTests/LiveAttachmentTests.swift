// Live API (opt-in): IMP_LIVE_TESTS=1 swift test --package-path apple --filter LiveAttachment
// A picture and a sound go to a real model the way the apps send what is attached to a message
// (Briefing.message with media), with the address and key in ./.env. The model is
// IMP_TEST_MEDIA_MODEL, else xiaomi/mimo-v2.6-flash: one that sees and hears.

import CoreGraphics
import Foundation
import Testing
@testable import ImpKit

@Suite(.enabled(if: LiveEnv.values != nil), .serialized) struct LiveAttachmentTests {
    private var model: String {
        ProcessInfo.processInfo.environment["IMP_TEST_MEDIA_MODEL"].flatMap { $0.isEmpty ? nil : $0 } ?? "xiaomi/mimo-v2.6-flash"
    }

    /// A plain red square, as a PNG.
    private func redSquare() throws -> MediaFile {
        let ctx = try #require(CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 0,
                                         space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        let image = try #require(ctx.makeImage())
        let picture = try #require(EncodedImage.encode(image))
        return MediaFile(data: picture.data, mimeType: picture.mimeType, name: "square.png")
    }

    /// One second of a 440 Hz tone, 16 kHz mono 16-bit WAV, as the apps record.
    private func tone() -> MediaFile {
        let rate = 16_000
        var samples = Data()
        for i in 0..<rate {
            let v = Int16(sin(2 * Double.pi * 440 * Double(i) / Double(rate)) * 12_000)
            withUnsafeBytes(of: v.littleEndian) { samples.append(contentsOf: $0) }
        }
        var wav = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { wav.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { wav.append(contentsOf: $0) } }
        wav.append(contentsOf: Array("RIFF".utf8)); u32(UInt32(36 + samples.count)); wav.append(contentsOf: Array("WAVEfmt ".utf8))
        u32(16); u16(1); u16(1); u32(UInt32(rate)); u32(UInt32(rate * 2)); u16(2); u16(16)
        wav.append(contentsOf: Array("data".utf8)); u32(UInt32(samples.count)); wav.append(samples)
        return MediaFile(data: wav, mimeType: "audio/wav", name: "tone.wav")
    }

    @Test func aPictureAndASoundAreSeenAndHeard() async throws {
        let live = try LiveEnv.client()
        let turn = Briefing.message("What colour is the picture, and what do you hear? One short sentence.",
                                    media: [try redSquare(), tone()])
        // A small model sometimes says it can't hear: it gets three tries.
        var answers: [String] = []
        for _ in 0..<3 {
            let answer = try await live.client.chat(model: model, messages: [.system(Persona.imp), turn]).text.lowercased()
            answers.append(answer)
            let sees = answer.contains("red")
            let hears = ["tone", "beep", "hum", "sine", "whistle", "pitch", "note", "buzz"].contains { answer.contains($0) }
            if sees && hears { return }
        }
        Issue.record("the model didn't name both the colour and the sound: \(answers)")
    }
}
