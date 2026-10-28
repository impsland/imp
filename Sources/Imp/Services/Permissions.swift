import AppKit
import ImpKit
import AVFoundation
import ServiceManagement
import Speech

enum Permission: String, CaseIterable, Identifiable, Hashable {
    case microphone, speech
    var id: String { rawValue }

    var title: String {
        switch self {
        case .microphone: "Microphone"
        case .speech: "Speech Recognition"
        }
    }

    var why: String {
        switch self {
        case .microphone: "Hear you when you talk to Imp."
        case .speech: "Turn your voice into text (Apple dictation)."
        }
    }

    @MainActor var isGranted: Bool {
        switch self {
        case .microphone: AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        case .speech: SFSpeechRecognizer.authorizationStatus() == .authorized
        }
    }

    /// The completion handlers are `@Sendable` on purpose: macOS calls them on a background queue,
    /// and a closure written here would otherwise be main-actor isolated, which Swift 6 checks at
    /// run time and turns into a crash (that's how granting Speech Recognition used to quit Imp).
    @MainActor func request() {
        switch self {
        case .microphone:
            if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
                AVCaptureDevice.requestAccess(for: .audio) { @Sendable _ in }
            } else { open("Privacy_Microphone") }
        case .speech:
            if SFSpeechRecognizer.authorizationStatus() == .notDetermined {
                SFSpeechRecognizer.requestAuthorization { @Sendable _ in }
            } else { open("Privacy_SpeechRecognition") }
        }
    }


    @MainActor private func open(_ anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }
}

@MainActor
enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }
    static func set(_ on: Bool) throws {
        if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
    }
}
