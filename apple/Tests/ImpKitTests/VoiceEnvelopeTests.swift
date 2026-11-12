import Foundation
import Testing
@testable import ImpKit

@Suite struct VoiceEnvelopeTests {
    @Test func silenceIsStillAndLoudIsFull() {
        let e = VoiceEnvelope(rms: Array(repeating: 0, count: 10) + Array(repeating: 0.5, count: 30), rate: 10)
        #expect(e.level(at: 0.5) == 0)
        #expect(e.level(at: 3.5) > 0.99)                         // settled on a loud voice
    }

    @Test func itRisesFasterThanItFalls() {
        let e = VoiceEnvelope(rms: [0.5, 0.5, 0, 0], rate: 1)
        let rise = e.levels[0], fall = e.levels[1] - e.levels[2]
        #expect(rise > fall && fall > 0)
    }

    @Test func betweenFramesItBlendsAndOutsideItIsQuiet() {
        let e = VoiceEnvelope(rms: [0.5, 0.5, 0.5], rate: 2, attack: 1, release: 1)
        #expect(e.levels == [1, 1, 1])
        #expect(e.level(at: 1.25) == 0.5)                        // halfway into the fade after the last frame
        #expect(e.level(at: 2) == 0 && e.level(at: -1) == 0 && e.level(at: .nan) == 0)
        #expect(VoiceEnvelope(rms: [], rate: 30).level(at: 0) == 0)
    }

    @Test func rootMeanSquare() {
        #expect(VoiceEnvelope.rms([Float]()) == 0)
        #expect(abs(VoiceEnvelope.rms([0.5, -0.5, 0.5, -0.5] as [Float]) - 0.5) < 1e-9)
    }

    @Test func aMadeUpVoiceStaysInRangeAndMoves() {
        let levels = stride(from: 0.0, to: 10, by: 1 / 30).map(VoiceEnvelope.speechLike)
        #expect(levels.allSatisfy { (0...1).contains($0) })
        #expect((levels.max()! - levels.min()!) > 0.4)
    }

    @Test func stylesSayWhatTheyShow() {
        #expect(VoiceStyle.both.glows && VoiceStyle.both.hasOrb && VoiceStyle.both.speaks)
        #expect(VoiceStyle.glow.glows && !VoiceStyle.glow.hasOrb)
        #expect(!VoiceStyle.orb.glows && VoiceStyle.orb.hasOrb)
        #expect(!VoiceStyle.players.speaks && !VoiceStyle.players.glows && !VoiceStyle.players.hasOrb)
    }

    @Test func aRepliesVoices() {
        let mixed = Markdown.blocks("Hi\n\n![Voice](a.mp3#autoplay)\n\n![Clip](b.mov)\n\n![Pic](c.png)\n\n![More](d.m4a)")
        #expect(Markdown.voices(mixed).map(\.lastPathComponent) == ["a.mp3", "d.m4a"])
        #expect(!Markdown.isOnlyVoice(mixed))
        #expect(Markdown.isOnlyVoice(Markdown.blocks("![Voice](a.mp3#autoplay)\n\n![Again](b.wav)")))
        #expect(!Markdown.isOnlyVoice(Markdown.blocks("")))
        #expect(Markdown.voices(Markdown.blocks("Just words")).isEmpty)
    }

    @Test func settingsSavedBeforeVoiceStylesStillLoad() throws {
        var p = ImpPreferences()
        #expect(p.voiceStyle == .both)
        p.voiceStyle = .players
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(p)) as! [String: Any]
        #expect(try JSONDecoder().decode(ImpPreferences.self, from: JSONSerialization.data(withJSONObject: json)).voiceStyle == .players)
        json.removeValue(forKey: "voice")
        #expect(try JSONDecoder().decode(ImpPreferences.self, from: JSONSerialization.data(withJSONObject: json)).voiceStyle == .both)
    }
}
