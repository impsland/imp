@preconcurrency import AVFoundation
@preconcurrency import Speech
import os

/// On-device-when-possible dictation with Apple's Speech framework. Stops by itself
/// after a short pause, or when `finish()` is called.
@MainActor
final class Dictation {
    enum Failure: LocalizedError, Equatable {
        case microphoneDenied, speechDenied, unavailable(String), heardNothing
        var errorDescription: String? {
            switch self {
            case .microphoneDenied: String(localized: "I can't hear you. Turn on the microphone for Imp in System Settings › Privacy & Security › Microphone.")
            case .speechDenied: String(localized: "Speech recognition is off for Imp. Turn it on in System Settings › Privacy & Security › Speech Recognition.")
            case .unavailable(let l): String(localized: "Dictation isn't available for \(l) right now.")
            case .heardNothing: String(localized: "I heard nothing. Not even a whisper.")
            }
        }
    }

    var onPartial: ((String) -> Void)?
    var onLevel: ((Double) -> Void)?
    private(set) var isRunning = false

    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var continuation: CheckedContinuation<String, Error>?
    private var transcript = ""
    private var lastChange = Date()
    private var startedAt = Date()
    private var watchdog: Task<Void, Never>?
    private let log = Logger(subsystem: "app.imp.Imp", category: "dictation")

    /// Asks only when macOS hasn't asked yet. Otherwise answers immediately from the cached status.
    /// The handlers are `@Sendable`: macOS calls them off the main thread (see `Permission.request`).
    static func requestPermissions() async throws {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: break
        case .notDetermined:
            let granted = await withCheckedContinuation { c in AVCaptureDevice.requestAccess(for: .audio) { @Sendable in c.resume(returning: $0) } }
            guard granted else { throw Failure.microphoneDenied }
        default: throw Failure.microphoneDenied
        }
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: break
        case .notDetermined:
            let status = await withCheckedContinuation { c in SFSpeechRecognizer.requestAuthorization { @Sendable in c.resume(returning: $0) } }
            guard status == .authorized else { throw Failure.speechDenied }
        default: throw Failure.speechDenied
        }
    }

    /// Listens until a pause. Returns the final transcript.
    func listen(localeID: String) async throws -> String {
        try await Self.requestPermissions()
        let locale = localeID.isEmpty ? Locale.current : Locale(identifier: localeID)
        guard let recognizer = SFSpeechRecognizer(locale: locale) ?? SFSpeechRecognizer(), recognizer.isAvailable else {
            throw Failure.unavailable(locale.identifier)
        }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }
        self.request = request
        transcript = ""
        startedAt = Date()
        lastChange = Date()

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        let levelSink: @Sendable (Double) -> Void = { [weak self] l in Task { @MainActor in self?.onLevel?(l) } }
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            request.append(buffer)
            guard let ch = buffer.floatChannelData?[0] else { return }
            let n = Int(buffer.frameLength)
            var sum: Float = 0
            for i in 0..<n { sum += ch[i] * ch[i] }
            let rms = sqrt(sum / Float(max(n, 1)))
            levelSink(Double(min(1, max(0, (20 * log10(max(rms, 1e-6)) + 50) / 40))))
        }
        engine.prepare()
        try engine.start()
        isRunning = true

        task = recognizer.recognitionTask(with: request) { @Sendable [weak self] result, error in
            let text = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal ?? false
            let failed = error != nil
            Task { @MainActor in
                guard let self else { return }
                if let text, text != self.transcript {
                    self.transcript = text
                    self.lastChange = Date()
                    self.onPartial?(text)
                }
                if isFinal || (failed && self.isRunning) { self.complete() }
            }
        }

        watchdog = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(150))
                guard let self else { return }
                let quiet = Date().timeIntervalSince(self.lastChange)
                if !self.transcript.isEmpty && quiet > 1.6 { self.finish() }
                if self.transcript.isEmpty && Date().timeIntervalSince(self.startedAt) > 8 { self.finish() }
                if Date().timeIntervalSince(self.startedAt) > 60 { self.finish() }
            }
        }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { self.continuation = $0 }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancel() }
        }
    }

    /// Stop listening and use what we have.
    func finish() {
        guard isRunning else { return }
        request?.endAudio()
        teardownAudio()
        // Give the recognizer a moment to deliver the final result.
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(700))
            self?.complete()
        }
    }

    func cancel() {
        task?.cancel()
        teardownAudio()
        continuation?.resume(throwing: CancellationError())
        continuation = nil
        cleanup()
    }

    private func complete() {
        guard let c = continuation else { return }
        continuation = nil
        teardownAudio()
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        task?.finish()
        cleanup()
        if text.isEmpty { c.resume(throwing: Failure.heardNothing) } else { c.resume(returning: text) }
    }

    private func teardownAudio() {
        guard isRunning else { return }
        isRunning = false
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        onLevel?(0)
    }

    private func cleanup() {
        watchdog?.cancel()
        watchdog = nil
        task = nil
        request = nil
    }
}
