import AVFoundation

/// The Mac's voice, for an Imp that speaks out loud (`imp_speak`). One voice at a time: a new line
/// cuts off the one before.
@MainActor
final class Speaker {
    static let shared = Speaker()
    private let synthesizer = AVSpeechSynthesizer()

    /// Says `text`, in `language` (BCP-47) if given and installed, else in the system's voice.
    func say(_ text: String, language: String? = nil) {
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .word) }
        let utterance = AVSpeechUtterance(string: text)
        if let language, let voice = AVSpeechSynthesisVoice(language: language) { utterance.voice = voice }
        synthesizer.speak(utterance)
    }

    func stop() { synthesizer.stopSpeaking(at: .immediate) }
}
