import ImpDesign
import ImpKit
import SwiftUI

/// The Den: the server where Imps share and find animations, triggers and Imps, in the same card as The Hop
/// on Devices (`ServerCard`), then the way into it: Browse The Den, or why it can't be browsed yet.
struct SharingPane: View {
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.medium) {
            ServerCard(kind: .den, text: Binding(get: { model.prefs.den }, set: { model.prefs.den = $0 }))
                .settingAnchor(.sharingDen)
            browse
        }
    }

    /// One row: Browse The Den (only with a Den set up). What The Den holds, or why it can't be
    /// browsed yet, is behind the (?).
    private var browse: some View {
        let ready = DenServer(model.prefs.den) != nil
        return HStack(spacing: Spacing.cozy) {
            IconTile(systemName: "books.vertical.fill")
            Text("sharing.browse").font(Typeface.body).foregroundStyle(ready ? Tone.text : Tone.muted).lineLimit(1)
            InfoTip(ready ? "servers.den.about" : "servers.den.needed")
            Spacer(minLength: Spacing.small)
            if ready {
                HoverIconButton(systemName: "arrow.up.right", help: "sharing.browse") {
                    let flow = KitFlow(imp: nil, forEveryImp: true)
                    flow.browsing = true
                    HomeWindow.shared.router.kitFlow = flow
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: Sizing.hit, alignment: .leading)
        .pebble()
    }
}
