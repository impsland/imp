import ImpDesign
import ImpKit
import SwiftUI

/// Sharing: import a kit you have. Browsing and publishing happen in an MCP gallery such as the Den, which
/// is added as a tool (Tools tab): the Imp downloads an item there and `imp_add_kit` opens the review.
struct SharingPane: View {
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.medium) {
            Card("sharing.gallery", icon: "books.vertical.fill", info: "sharing.gallery.info") {
                Button {
                    let flow = KitFlow(imp: nil, forEveryImp: true)
                    HomeWindow.shared.router.kitFlow = flow
                } label: {
                    FitLabel("sharing.import", systemImage: "square.and.arrow.down").frame(maxWidth: .infinity)
                }
                .buttonStyle(.imp(.secondary))
                .settingAnchor(.sharingImport)
            }
        }
    }
}
