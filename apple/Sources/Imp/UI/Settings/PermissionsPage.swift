import AppKit
import ImpDesign
import ImpKit
import SwiftUI

/// What Imp may use on this Mac: one row each, with whether it is allowed and a button to allow it.
struct PermissionsPage: View {
    let model: AppModel
    private var status: SystemStatus { .shared }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.medium) {
            Card("settings.privacy.core.title", icon: "ear.fill", info: "settings.privacy.core.info") {
                ForEach(Permission.core) { row($0) }
            }
            .settingAnchor(.privacyListening)
            Card("settings.privacy.computer.title", icon: "desktopcomputer", info: "privacy.computer_note") {
                ForEach(Permission.computerControl) { row($0) }
            }
            .settingAnchor(.privacyComputer)
        }
    }

    private func row(_ p: Permission) -> some View {
        Row(p.titleKey, icon: p.symbol, info: p.infoKey) {
            if status.isGranted(p) {
                StatusText(text: "Granted", symbol: "checkmark.circle.fill", color: Tone.good)
            } else {
                Button { p.request() } label: { FitLabel("Allow…", systemImage: "checkmark.shield") }
                    .buttonStyle(.imp(.secondary, small: true))
            }
        }
    }
}

extension Permission {
    /// The name of the permission, as a short phrase.
    var titleKey: LocalizedStringKey {
        switch self {
        case .microphone: "settings.privacy.microphone.title"
        case .speech: "settings.privacy.speech.title"
        case .screenRecording: "settings.privacy.screen.title"
        case .accessibility: "settings.privacy.accessibility.title"
        }
    }

    /// Only the one whose name does not say what it is for has a tip.
    var infoKey: LocalizedStringKey? { self == .accessibility ? "settings.privacy.accessibility.info" : nil }

    var symbol: String {
        switch self {
        case .microphone: "mic.fill"
        case .speech: "waveform"
        case .screenRecording: "rectangle.dashed.badge.record"
        case .accessibility: "accessibility"
        }
    }
}
