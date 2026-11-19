import AppKit
import ImpDesign
import ImpKit
import SwiftUI

/// Says that Local Network is off for Imp on this Mac, with a button that opens System Settings at
/// Privacy & Security › Local Network. It fills whatever room it is given (the code's place in the Link
/// sheet), so showing it moves nothing.
struct LocalNetworkNotice: View {
    var body: some View {
        VStack(spacing: Spacing.cozy) {
            Image(systemName: "exclamationmark.triangle.fill").font(.icon(.large)).foregroundStyle(Tone.warnText)
            Text("link.localnet.off").font(Typeface.small).foregroundStyle(Tone.text)
                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            Button { NSWorkspace.shared.open(Self.settings) } label: { FitLabel("link.localnet.open_mac", systemImage: "gear") }
                .buttonStyle(.imp(.secondary, small: true))
        }
        .padding(Spacing.medium)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
    }

    static let settings = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork")!
}
