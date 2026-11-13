import ImpDesign
import ImpKit
import SwiftUI

/// Sharing: the Gallery (Browse what others shared in The Den, Import a kit you have), then The Den's
/// server, the same card as The Hop on Devices (`ServerCard`). Publishing starts from the share button of
/// whatever you want to share, so it is explained here and not duplicated.
struct SharingPane: View {
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.medium) {
            gallery
            ServerCard(kind: .den, text: Binding(get: { model.prefs.den }, set: { model.prefs.den = $0 }))
                .settingAnchor(.sharingDen)
        }
    }

    /// Browse is offered with a Den set up; without one the button is off and its tooltip says why.
    private var gallery: some View {
        let ready = DenServer(model.prefs.den) != nil
        return Card("sharing.gallery", icon: "books.vertical.fill", info: "sharing.gallery.info") {
            HStack(spacing: Spacing.small) {
                Button { open(browsing: true) } label: {
                    FitLabel("sharing.browse", systemImage: "books.vertical").frame(maxWidth: .infinity)
                }
                .buttonStyle(.imp(.primary)).disabled(!ready)
                .help(ready ? Text("servers.den.about") : Text("servers.den.needed"))
                Button { open(browsing: false) } label: {
                    FitLabel("sharing.import", systemImage: "square.and.arrow.down").frame(maxWidth: .infinity)
                }
                .buttonStyle(.imp(.secondary))
            }
        }
    }

    private func open(browsing: Bool) {
        let flow = KitFlow(imp: nil, forEveryImp: true)
        flow.browsing = browsing
        HomeWindow.shared.router.kitFlow = flow
    }
}
