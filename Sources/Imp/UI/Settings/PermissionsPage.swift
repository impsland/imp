import AppKit
import ImpKit
import SwiftUI

struct PermissionsPage: View {
    let model: AppModel
    private var status: SystemStatus { .shared }

    var body: some View {
        Card("Permissions", icon: "lock.shield.fill",
             info: "Imps ask for as little as they can. The last two are only for computer control.") {
            VStack(spacing: 10) {
                ForEach(Permission.allCases) { p in
                    let granted = status.isGranted(p)
                    let pending: Color = p.isOptional ? .secondary : .orange
                    if p != Permission.allCases.first { CardDivider() }
                    HStack(spacing: 10) {
                        Image(systemName: icon(p))
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(granted ? .green : pending)
                            .frame(width: 28, height: 28)
                            .background(Circle().fill((granted ? Color.green : pending).opacity(0.14)))
                        Text(p.title).font(.system(size: 13, weight: .semibold))
                        if p.isOptional { Text("Optional").font(.system(size: 11)).foregroundStyle(.secondary) }
                        InfoTip(verbatim: p.why)
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
        case .screenRecording: "rectangle.dashed.badge.record"
        case .accessibility: "accessibility"
        }
    }
}
