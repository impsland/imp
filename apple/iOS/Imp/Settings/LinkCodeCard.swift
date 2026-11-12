import ImpDesign
import ImpKit
import SwiftUI

/// This iPhone's invite as its own centred card: the QR code, one line, and copy and share in one row.
/// Showing it makes a new code. Once it is off the screen it still works for 15 minutes.
struct LinkCodeCard: View {
    let hub: LinkHub
    @State private var invite: LinkInvite?

    var body: some View {
        VStack(spacing: Spacing.medium) {
            if let invite, let image = QRCode.image(for: invite.url.absoluteString) {
                Image(decorative: image, scale: 1)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: Sizing.tipWidth)
                    .padding(Spacing.medium)
                    // A QR code is read as black on white, whatever the app's colours.
                    .background(Tone.text, in: RoundedRectangle(cornerRadius: Radius.large, style: .continuous))
                    .accessibilityLabel("phone.code.label")
                Text("phone.code.caption").font(Typeface.caption).foregroundStyle(Tone.muted)
                    .multilineTextAlignment(.center)
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: Spacing.small) { copy(invite); share(invite) }
                    VStack(spacing: Spacing.small) { copy(invite); share(invite) }
                }
            } else {
                ProgressView().frame(minHeight: Sizing.hit)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(Spacing.roomy)
        .impCard()
        .task {
            // Showing a code is what needs the local network: asked for here, not at launch.
            await hub.useNetwork()
            invite = hub.node.invite()
        }
        .onDisappear { hub.node.inviteHidden() }
    }

    private func copy(_ invite: LinkInvite) -> some View {
        Button { UIPasteboard.general.string = invite.url.absoluteString } label: { FitLabel("phone.copy", systemImage: "doc.on.doc") }
            .buttonStyle(.secondary)
    }

    private func share(_ invite: LinkInvite) -> some View {
        ShareLink(item: invite.url) { FitLabel("phone.share", systemImage: "square.and.arrow.up") }
            .buttonStyle(.secondary)
    }
}
