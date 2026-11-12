import ImpDesign
import ImpKit
import SwiftUI

/// This device and the ones linked with it: first the devices (link one, the linked ones, forget them),
/// then The Hop that lets them find each other from anywhere. The Hop is the same card as The Den on
/// Sharing (`ServerCard`).
struct DevicesPane: View {
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.medium) {
            DevicesCard(model: model)
            ServerCard(kind: .hop, text: Binding(get: { model.prefs.hop }, set: { model.prefs.hop = $0 }))
                .settingAnchor(.devicesHop)
        }
    }
}
