@preconcurrency import AVFoundation
@preconcurrency import Speech
import ImpKit
import NaturalLanguage
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

    /// One language listening: its recognizer, its request fed from the shared microphone tap, and what it heard.
    private final class Lane {
        let locale: String
        let recognizer: SFSpeechRecognizer
        let request: SFSpeechAudioBufferRecognitionRequest
        var task: SFSpeechRecognitionTask?
        var text = ""
        var confidence = 0.0
        var done = false

        init(locale: String, recognizer: SFSpeechRecognizer, request: SFSpeechAudioBufferRecognitionRequest) {
            self.locale = locale; self.recognizer = recognizer; self.request = request
        }
    }

    private let engine = AVAudioEngine()
    private var lanes: [Lane] = []
    private var continuation: CheckedContinuation<ListeningLanguages.Heard, Error>?
    private var shown = ""
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

    /// Listens until a pause in one language (empty: the system's). Returns the final transcript.
    func listen(localeID: String) async throws -> String {
        try await listen(localeIDs: [localeID]).text
    }

    /// Listens until a pause in every one of `localeIDs` at once, on the same audio. The first is the
    /// likely one: its words show while listening. The answer is the best of them (`ListeningLanguages.pick`),
    /// with the locale it was heard in.
    func listen(localeIDs: [String]) async throws -> ListeningLanguages.Heard {
        try await Self.requestPermissions()
        let ids = localeIDs.isEmpty ? [""] : localeIDs
        var lanes: [Lane] = []
        for id in ids {
            let locale = id.isEmpty ? Locale.current : Locale(identifier: id)
            guard let recognizer = SFSpeechRecognizer(locale: locale) ?? (ids.count == 1 ? SFSpeechRecognizer() : nil),
                  recognizer.isAvailable else {
                log.info("No recognizer for \(locale.identifier, privacy: .public)")
                continue
            }
            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            request.addsPunctuation = true
            if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }
            lanes.append(Lane(locale: recognizer.locale.identifier, recognizer: recognizer, request: request))
        }
        guard !lanes.isEmpty else { throw Failure.unavailable(ids.first.map { $0.isEmpty ? Locale.current.identifier : $0 } ?? "") }
        self.lanes = lanes
        shown = ""
        startedAt = Date()
        lastChange = Date()

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        let levelSink: @Sendable (Double) -> Void = { [weak self] l in Task { @MainActor in self?.onLevel?(l) } }
        let requests = lanes.map(\.request)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            for request in requests { request.append(buffer) }
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

        for lane in lanes {
            let key = ObjectIdentifier(lane)
            lane.task = lane.recognizer.recognitionTask(with: lane.request) { @Sendable [weak self] result, error in
                let text = result?.bestTranscription.formattedString
                let segments = result?.bestTranscription.segments.map { Double($0.confidence) } ?? []
                let isFinal = result?.isFinal ?? false
                let failed = error != nil
                Task { @MainActor in
                    guard let self, let lane = self.lanes.first(where: { ObjectIdentifier($0) == key }) else { return }
                    if let text, text != lane.text {
                        lane.text = text
                        self.lastChange = Date()
                    }
                    if isFinal, !segments.isEmpty { lane.confidence = segments.reduce(0, +) / Double(segments.count) }
                    if isFinal || failed { lane.done = true }
                    self.showLeader()
                    if self.lanes.allSatisfy(\.done) { self.complete() }
                }
            }
        }

        watchdog = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(150))
                guard let self else { return }
                let quiet = Date().timeIntervalSince(self.lastChange)
                let heard = self.lanes.contains { !$0.text.isEmpty }
                if heard && quiet > 1.6 { self.finish() }
                if !heard && Date().timeIntervalSince(self.startedAt) > 8 { self.finish() }
                if Date().timeIntervalSince(self.startedAt) > 60 { self.finish() }
            }
        }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { self.continuation = $0 }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancel() }
        }
    }

    /// The words shown while listening: the likely language's, or, while it has none, the first that has some.
    private func showLeader() {
        let leader = lanes.first { !$0.text.isEmpty }?.text ?? ""
        let text = lanes.first.map { $0.text.isEmpty ? leader : $0.text } ?? leader
        guard text != shown else { return }
        shown = text
        onPartial?(text)
    }

    /// Stop listening and use what we have.
    func finish() {
        guard isRunning else { return }
        for lane in lanes { lane.request.endAudio() }
        teardownAudio()
        // Give the recognizers a moment to deliver their final results.
        let wait = lanes.count > 1 ? 1000 : 700
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(wait))
            self?.complete()
        }
    }

    func cancel() {
        for lane in lanes { lane.task?.cancel() }
        teardownAudio()
        continuation?.resume(throwing: CancellationError())
        continuation = nil
        cleanup()
    }

    private func complete() {
        guard let c = continuation else { return }
        continuation = nil
        teardownAudio()
        let heard = lanes.map { lane in
            ListeningLanguages.Heard(locale: lane.locale, text: lane.text.trimmingCharacters(in: .whitespacesAndNewlines),
                                     confidence: lane.confidence, fit: Self.fit(lane.text, locale: lane.locale))
        }
        for lane in lanes { lane.task?.finish() }
        let sticky = lanes.first?.locale
        cleanup()
        guard let best = ListeningLanguages.pick(heard, sticky: sticky) else { return c.resume(throwing: Failure.heardNothing) }
        if heard.count > 1 {
            let scores = heard.map { "\($0.locale)=\(String(format: "%.2f", $0.score))" }.joined(separator: " ")
            log.info("Heard \(best.locale, privacy: .public) (\(scores, privacy: .public))")
        }
        c.resume(returning: best)
    }

    /// How much `text` reads as the language of `locale`, 0…1, from the system's text language check.
    private static func fit(_ text: String, locale: String) -> Double {
        guard !text.isEmpty else { return 0 }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        let code = Locale(identifier: locale).language.languageCode?.identifier ?? locale
        let hypotheses = recognizer.languageHypotheses(withMaximum: 8)
        // Chinese is two scripts to the checker: either counts.
        return hypotheses.filter { $0.key.rawValue == code || $0.key.rawValue.hasPrefix(code + "-") }.map(\.value).reduce(0, +)
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
        lanes = []
    }
}
