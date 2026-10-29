import AppKit
import ImpKit
import ApplicationServices
import AVFoundation
import ServiceManagement
import Speech

enum Permission: String, CaseIterable, Identifiable, Hashable {
    case microphone, speech
    /// Only for computer control (`ImpToolGroup.computer`).
    case screenRecording, accessibility
    var id: String { rawValue }

    /// Needed by Imp itself; the others only when an Imp is given a tool that wants them.
    static let core: [Permission] = [.microphone, .speech]
    var isOptional: Bool { !Self.core.contains(self) }
    /// What computer control needs.
    static let computerControl: [Permission] = [.screenRecording, .accessibility]

    var title: String {
        switch self {
        case .microphone: String(localized: "Microphone")
        case .speech: String(localized: "Speech Recognition")
        case .screenRecording: String(localized: "Screen & System Audio Recording")
        case .accessibility: String(localized: "Accessibility (Device Control & Data Access)")
        }
    }

    var why: String {
        switch self {
        case .microphone: String(localized: "Lets Imps hear you.")
        case .speech: String(localized: "Turns your voice into text with Apple dictation.")
        case .screenRecording: String(localized: "Lets an Imp see the app it operates. Only for computer control.")
        case .accessibility: String(localized: "Lets an Imp click and type in other apps. Only for computer control.")
        }
    }

    @MainActor var isGranted: Bool {
        switch self {
        case .microphone: AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        case .speech: SFSpeechRecognizer.authorizationStatus() == .authorized
        case .screenRecording: CGPreflightScreenCaptureAccess()
        case .accessibility: AXIsProcessTrusted()
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
        case .screenRecording:
            // The system prompt only appears once; after that the pane is the way.
            if !Self.asked(.screenRecording) { _ = CGRequestScreenCaptureAccess() } else { open("Privacy_ScreenCapture") }
        case .accessibility:
            if !Self.asked(.accessibility) {
                // The literal is `kAXTrustedCheckOptionPrompt` (a global var Swift 6 won't let us read).
                _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
            } else { open("Privacy_Accessibility") }
        }
    }

    /// Whether the system prompt was already shown for `p` (remembers it by saying yes the second time).
    private static func asked(_ p: Permission) -> Bool {
        let key = "askedPermission.\(p.rawValue)"
        defer { UserDefaults.standard.set(true, forKey: key) }
        return UserDefaults.standard.bool(forKey: key)
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
