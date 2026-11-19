import ImpDesign
import ImpKit
import SwiftUI

/// Devices, the one place that says where every Imp is and how the devices talk: a canvas that fills the window.
/// Pressing a device, an Imp or a line opens a sheet about it (`DeviceSheet`); pressing empty canvas does nothing.
/// It is its own screen, not a section of Settings. Link a device opens from the bar. Back (and Esc) leaves for the Imps.
struct DevicesScreen: View {
    let model: AppModel
    let router: HomeRouter
    @State private var sheet: DevicesSheet?
    @Environment(\.postNotice) private var postNotice

    init(model: AppModel, router: HomeRouter, sheet: DevicesSheet? = nil) {
        self.model = model
        self.router = router
        _sheet = State(initialValue: sheet)
    }

    var body: some View {
        // Rebuilt whenever the link, the Imps or the Hop change: the canvas is always the live state.
        let map = SettingsNodes.deviceMap(for: model)
        VStack(spacing: 0) {
            TopBar(back: { router.goHome() }) {
                Text("devices.title").font(Typeface.cardTitle).foregroundStyle(Tone.text)
                    .accessibilityAddTraits(.isHeader)
            } trailing: {
                HoverIconButton(systemName: "qrcode", help: "settings.devices.link.title", tint: Tone.text) { sheet = .link }
                    .settingAnchor(.devicesPair)
                    .cornerLabel(.trailing, bar: Metrics.barHeight)
            }
            DevicesCanvas(map: map, hop: model.prefs.hop, moved: Bindable(router).devicePlaces,
                          open: { sheet = $0 }, link: { sheet = .link })
        }
        .environment(\.highlightedSetting, router.highlightedSetting)
        .onChange(of: router.highlightedSetting, initial: true) { _, setting in reveal(setting) }
        .onChange(of: model.link.problem, initial: true) { _, problem in if let problem { postNotice(.warning(problem)) } }
        .sheet(item: Binding(get: { sheet?.resolved(in: map) }, set: { sheet = $0 })) { item in
            switch item {
            case .link: LinkDeviceSheet(model: model, mode: .show)
            case .hop: HopSheet(model: model, map: map) { sheet = $0 }
            case .about(let selection):
                DeviceSheet(model: model, router: router, map: map, selection: selection) { sheet = $0 }
                    .id(selection)
            }
        }
    }

    /// A link to one of the Devices settings: the Hop in its sheet, the others in the sheet of this Mac.
    private func reveal(_ setting: SettingID?) {
        switch setting {
        case .devicesHop: sheet = .hop
        case .devicesLink, .devicesForgetAll: sheet = .about(.node(DeviceMap.thisMacID))
        default: break
        }
    }
}
