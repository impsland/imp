import ImpDesign
import ImpKit
import SwiftUI

/// This Mac with Link, the devices linked with it (each its own row), then The Hop that lets them find
/// each other from anywhere: the same card as The Den on Sharing (`ServerCard`).
struct DevicesPane: View {
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.medium) {
            ThisDeviceCard(model: model)
            DevicesCard(model: model)
            ServerCard(kind: .hop, text: Binding(get: { model.prefs.hop }, set: { model.prefs.hop = $0 }))
                .settingAnchor(.devicesHop)
        }
    }
}
