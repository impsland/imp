import Foundation

/// How loud a voice reply is over time, 0…1, so the bubble can move with it. Built once from the
/// file's loudness (RMS per short frame), then read at the player's current time.
public struct VoiceEnvelope: Equatable, Sendable {
    /// Frames per second.
    public let rate: Double
    /// 0…1 per frame: quiet is 0, a raised voice reaches 1.
    public let levels: [Double]

    /// Below this a frame is silence; at `loud` and above it's full.
    public static let quiet = -48.0, loud = -12.0

    /// `rms`: each frame's root mean square (linear, 0…1), `rate` frames per second. Levels rise
    /// quickly and fall a little slower, so syllables read as pulses rather than flicker.
    public init(rms: [Double], rate: Double, attack: Double = 0.6, release: Double = 0.25) {
        self.rate = rate > 0 ? rate : 30
        var out: [Double] = []
        out.reserveCapacity(rms.count)
        var last = 0.0
        for r in rms {
            let db = 20 * log10(max(r, 1e-9))
            let target = min(max((db - Self.quiet) / (Self.loud - Self.quiet), 0), 1)
            last += (target - last) * (target > last ? attack : release)
            out.append(last)
        }
        levels = out
    }

    /// The level `seconds` in (between frames it's blended; outside the file it's 0).
    public func level(at seconds: Double) -> Double {
        guard seconds.isFinite, seconds >= 0, !levels.isEmpty else { return 0 }
        let x = seconds * rate
        let i = Int(x)
        guard i < levels.count else { return 0 }
        let next = i + 1 < levels.count ? levels[i + 1] : 0
        let f = x - Double(i)
        return levels[i] * (1 - f) + next * f
    }

    /// Root mean square of some samples (0 for none).
    public static func rms<C: Collection>(_ samples: C) -> Double where C.Element == Float {
        guard !samples.isEmpty else { return 0 }
        var sum = 0.0
        for s in samples { sum += Double(s) * Double(s) }
        return (sum / Double(samples.count)).squareRoot()
    }

    /// A believable talking level at time `t`, for a voice whose file can't be measured (streamed
    /// from the web): a few slow and quick waves together, like syllables inside phrases. 0…1.
    public static func speechLike(at t: Double) -> Double {
        let phrase = 0.5 + 0.5 * sin(t * 1.3) * sin(t * 0.47 + 1)
        let syllable = 0.5 + 0.5 * sin(t * 9.1 + sin(t * 2.3) * 2)
        let flutter = 0.5 + 0.5 * sin(t * 17.3 + 0.7)
        return min(max(0.15 + 0.85 * phrase * (0.55 * syllable + 0.45 * flutter), 0), 1)
    }
}

/// How an answer's audio shows in the speech bubble. The chat always shows players.
public enum VoiceStyle: String, Codable, CaseIterable, Sendable, Identifiable {
    /// The bubble's edge glows and shifts colour with the voice, and a puff of smoke on its top edge
    /// breathes with it (click it to pause or play again).
    case both
    /// Only the glowing edge.
    case glow
    /// Only the puff of smoke.
    case orb
    /// A player for each file, like in the chat.
    case players
    public var id: String { rawValue }

    public var glows: Bool { self == .both || self == .glow }
    public var hasOrb: Bool { self == .both || self == .orb }
    /// Audio is presented as the Imp speaking, not as players.
    public var speaks: Bool { self != .players }
}

extension Markdown {
    /// A reply's audio, in the order written (videos and pictures aren't voice).
    public static func voices(_ blocks: [MarkdownBlock]) -> [URL] {
        blocks.compactMap { if case .media(let url, _, .audio, _) = $0 { url } else { nil } }
    }

    /// The reply is nothing but audio: the voice is the whole answer.
    public static func isOnlyVoice(_ blocks: [MarkdownBlock]) -> Bool {
        !blocks.isEmpty && blocks.allSatisfy { if case .media(_, _, .audio, _) = $0 { true } else { false } }
    }
}
