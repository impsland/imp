import AVFoundation
import Foundation
import Observation

/// Records a sound with the microphone as 16 kHz mono 16-bit WAV, which every model that hears
/// takes. `level` (0...1) follows the voice for a meter. The same on the Mac and the iPhone.
@MainActor
@Observable
public final class SoundRecorder {
    public enum Problem: Error, Equatable { case denied, failed }

    /// Linear PCM, written as WAV by the `.wav` file name.
    public nonisolated static var settings: [String: Any] { [
        AVFormatIDKey: Int(kAudioFormatLinearPCM),
        AVSampleRateKey: 16_000.0,
        AVNumberOfChannelsKey: 1,
        AVLinearPCMBitDepthKey: 16,
        AVLinearPCMIsFloatKey: false,
        AVLinearPCMIsBigEndianKey: false,
    ] }
    /// The longest recording in seconds (32 KB a second keeps it well under the 25 MiB limit).
    public nonisolated static let maxSeconds: TimeInterval = 600

    public private(set) var isRecording = false
    public private(set) var elapsed: TimeInterval = 0
    public private(set) var level: Double = 0
    /// True when the time ran out by itself: the sound is ready for `finish()`.
    public private(set) var timedOut = false

    private var recorder: AVAudioRecorder?
    private var url: URL?
    private var timer: Timer?

    public init() {}

    /// Starts recording. Asks for the microphone the first time.
    public func start() async throws {
        guard !isRecording else { return }
        guard await AVCaptureDevice.requestAccess(for: .audio) else { throw Problem.denied }
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothHFP])
        try? session.setActive(true)
        #endif
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("imp-sound-\(UUID().uuidString).wav")
        guard let recorder = try? AVAudioRecorder(url: file, settings: Self.settings) else { throw Problem.failed }
        recorder.isMeteringEnabled = true
        guard recorder.record(forDuration: Self.maxSeconds) else { throw Problem.failed }
        self.recorder = recorder
        url = file
        elapsed = 0; level = 0; timedOut = false
        isRecording = true
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    private func tick() {
        guard let recorder else { return }
        elapsed = recorder.currentTime
        recorder.updateMeters()
        // -50 dB is quiet, 0 dB is loud.
        level = max(0, min(1, (Double(recorder.averagePower(forChannel: 0)) + 50) / 50))
        if !recorder.isRecording { timer?.invalidate(); timer = nil; timedOut = true; isRecording = false }
    }

    /// Stops and returns the sound (nil when nothing was recorded).
    public func finish(name: String = "sound") -> MediaFile? {
        let seconds = recorder?.currentTime ?? elapsed
        stop()
        defer { discard() }
        guard seconds > 0.2, let url, let data = try? Data(contentsOf: url), MediaFile.check(bytes: data.count) == nil else { return nil }
        return MediaFile(data: data, mimeType: "audio/wav", name: name + ".wav")
    }

    /// Stops and throws the sound away.
    public func cancel() {
        stop()
        discard()
    }

    private func stop() {
        timer?.invalidate(); timer = nil
        recorder?.stop()
        recorder = nil
        isRecording = false
        level = 0
    }

    private func discard() {
        if let url { try? FileManager.default.removeItem(at: url) }
        url = nil
        timedOut = false
    }

    /// 1:05 for 65 seconds.
    public static func clock(_ seconds: TimeInterval) -> String {
        let s = Int(seconds)
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}
