import AppKit
import ImpKit
import SwiftUI

struct PermissionsPage: View {
    let model: AppModel
    private var status: SystemStatus { .shared }

    var body: some View {
        Card("Permissions", icon: "lock.shield.fill",
             info: "A few switches in System Settings. The Imps ask for as little as they can; triggers and the clipboard need no permission.") {
            VStack(spacing: 10) {
                ForEach(Permission.allCases) { p in
                    let granted = status.isGranted(p)
                    if p != Permission.allCases.first { CardDivider() }
                    HStack(spacing: 10) {
                        Image(systemName: icon(p))
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(granted ? .green : Color.orange)
                            .frame(width: 28, height: 28)
                            .background(Circle().fill((granted ? Color.green : Color.orange).opacity(0.14)))
                        Text(p.title).font(.system(size: 13, weight: .semibold))
                        InfoTip(p.why)
                        Spacer(minLength: 8)
                        if granted {
                            StatusText(text: "Granted", symbol: "checkmark.circle.fill", color: .green)
                        } else {
                            Button("Allow…") { p.request() }.buttonStyle(.imp(.primary, small: true))
                        }
                    }
                }
            }
        }
    }

    private func icon(_ p: Permission) -> String {
        switch p {
        case .microphone: "mic.fill"
        case .speech: "waveform"
        }
    }
}
