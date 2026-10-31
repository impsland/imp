import AVFoundation
import CoreHaptics
import UIKit

/// What Echo feels like: each rune has its own little pattern of taps, so it can be told apart with
/// eyes closed. Uses Core Haptics where the phone has it, plain impacts where it doesn't.
@MainActor
final class EchoHaptics {
    /// One tap of a pattern: when (seconds in), how hard, how sharp.
    struct Tap {
        var time: Double
        var strength: Float
        var sharpness: Float
    }

    /// A soft thump; two quick knocks; a sharp tick with a soft echo behind it; three climbing.
    static let runes: [[Tap]] = [
        [Tap(time: 0, strength: 0.6, sharpness: 0.2)],
        [Tap(time: 0, strength: 0.7, sharpness: 0.6), Tap(time: 0.09, strength: 0.7, sharpness: 0.6)],
        [Tap(time: 0, strength: 1, sharpness: 0.9), Tap(time: 0.13, strength: 0.4, sharpness: 0.15)],
        [Tap(time: 0, strength: 0.35, sharpness: 0.5), Tap(time: 0.08, strength: 0.6, sharpness: 0.5), Tap(time: 0.16, strength: 0.95, sharpness: 0.5)],
    ]

    private var engine: CHHapticEngine?
    private let impact = UIImpactFeedbackGenerator(style: .medium)
    private let notice = UINotificationFeedbackGenerator()
    private let capable = CHHapticEngine.capabilitiesForHardware().supportsHaptics

    func prepare() {
        impact.prepare()
        notice.prepare()
        guard capable, engine == nil else { return }
        engine = try? CHHapticEngine()
        try? engine?.start()
    }

    func stop() {
        engine?.stop()
        engine = nil
    }

    /// The pattern of rune `n`.
    func rune(_ n: Int) { play(Self.runes[min(max(n, 0), Self.runes.count - 1)]) }

    /// Wrong: a low buzz and a warning.
    func mistake() {
        notice.notificationOccurred(.warning)
        guard let engine, capable else { return }
        let event = CHHapticEvent(eventType: .hapticContinuous, parameters: [
            CHHapticEventParameter(parameterID: .hapticIntensity, value: 0.7),
            CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.1),
        ], relativeTime: 0, duration: 0.32)
        run([event], on: engine)
    }

    /// A sequence repeated: taps that climb, then the success.
    func cleared(clean: Bool) {
        let count = clean ? 5 : 3
        play((0..<count).map { Tap(time: 0.07 * Double($0), strength: 0.35 + 0.15 * Float($0), sharpness: 0.5) })
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(0.07 * Double(count) + 0.05))
            notice.notificationOccurred(.success)
        }
    }

    /// Your turn: one soft tap.
    func yourTurn() { play([Tap(time: 0, strength: 0.4, sharpness: 0.3)]) }

    private func play(_ taps: [Tap]) {
        if let engine, capable {
            let events = taps.map { tap in
                CHHapticEvent(eventType: .hapticTransient, parameters: [
                    CHHapticEventParameter(parameterID: .hapticIntensity, value: tap.strength),
                    CHHapticEventParameter(parameterID: .hapticSharpness, value: tap.sharpness),
                ], relativeTime: tap.time)
            }
            if run(events, on: engine) { return }
        }
        // No Core Haptics: the same taps, as impacts.
        for tap in taps {
            Task { @MainActor in
                if tap.time > 0 { try? await Task.sleep(for: .seconds(tap.time)) }
                impact.impactOccurred(intensity: CGFloat(tap.strength))
            }
        }
    }

    @discardableResult
    private func run(_ events: [CHHapticEvent], on engine: CHHapticEngine) -> Bool {
        do {
            try engine.start()
            let player = try engine.makePlayer(with: CHHapticPattern(events: events, parameters: []))
            try player.start(atTime: CHHapticTimeImmediate)
            return true
        } catch {
            return false
        }
    }
}

/// Soft tones for the runes, made on the spot: a bell-like note for each, a low one for a slip. They
/// play in the ambient category, so the silent switch mutes them and music playing carries on.
@MainActor
final class EchoSound {
    /// G4, C5, E5, G5: any order sounds friendly.
    private static let notes: [Double] = [392, 523.25, 659.25, 783.99]
    private static let sampleRate = 44_100.0

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let format = AVAudioFormat(standardFormatWithSampleRate: EchoSound.sampleRate, channels: 1)
    private var tones: [AVAudioPCMBuffer] = []
    private var slip: AVAudioPCMBuffer?
    private var ready = false

    func prepare() {
        guard !ready, let format else { return }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.ambient, mode: .default)
            try session.setActive(true)
        } catch {
            return
        }
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        tones = Self.notes.compactMap { Self.bell($0, duration: 0.55, format: format) }
        slip = Self.bell(174.6, duration: 0.45, format: format, bright: 0.12)
        ready = tones.count == Self.notes.count
        _ = running()
    }

    func stop() {
        player.stop()
        engine.stop()
        ready = false
    }

    func rune(_ n: Int) {
        guard ready, tones.indices.contains(n) else { return }
        play(tones[n])
    }

    func mistake() {
        if let slip { play(slip) }
    }

    /// A little run up the notes.
    func cleared() {
        for (i, n) in [0, 1, 2, 3].enumerated() {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(0.07 * Double(i)))
                rune(n)
            }
        }
    }

    private func running() -> Bool {
        if !engine.isRunning {
            guard (try? engine.start()) != nil else { return false }
        }
        if !player.isPlaying { player.play() }
        return true
    }

    private func play(_ buffer: AVAudioPCMBuffer) {
        guard running() else { return }
        player.scheduleBuffer(buffer, at: nil, options: .interrupts)
    }

    /// A sine with a touch of its octave, a quick soft attack and a long fade.
    private static func bell(_ frequency: Double, duration: Double, format: AVAudioFormat, bright: Double = 0.3) -> AVAudioPCMBuffer? {
        let frames = AVAudioFrameCount(duration * sampleRate)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames), let data = buffer.floatChannelData?[0] else { return nil }
        buffer.frameLength = frames
        for i in 0..<Int(frames) {
            let t = Double(i) / sampleRate
            let envelope = min(1, t / 0.008) * exp(-t * 6.5)
            let wave = sin(2 * .pi * frequency * t) + bright * sin(4 * .pi * frequency * t)
            data[i] = Float(0.22 * envelope * wave / (1 + bright))
        }
        return buffer
    }
}
