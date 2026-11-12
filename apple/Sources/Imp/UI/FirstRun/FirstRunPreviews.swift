import ImpDesign
import ImpKit
import SwiftUI

/// Every step and error state of the first run, for Xcode's canvas. No request leaves the preview.
@MainActor
private enum PreviewFirstRun {
    static func flow(_ events: (FirstRunModel) -> Void = { _ in }) -> FirstRunModel {
        let services = FirstRunServices(find: { [] }, models: { _, _ in ["model-a", "model-b"] }, check: { _ in })
        let flow = FirstRunModel(impName: "Dot", onThisComputer: true, services: services) { _ in }
        events(flow)
        return flow
    }

    static func sheet(_ flow: FirstRunModel) -> some View {
        FirstRunSheet(flow: flow, hue: ImpProfile.defaultHue, traits: .plain, clock: BodyClock(UUID()), close: {})
            .environment(\.impTint, Color.imp(ImpProfile.defaultHue))
            .background(Tone.surface)
    }
}

#Preview("Service") { PreviewFirstRun.sheet(PreviewFirstRun.flow()) }
#Preview("Local") { PreviewFirstRun.sheet(PreviewFirstRun.flow { if let local = ServicePreset.local { $0.choose(local) } }) }
#Preview("Empty key") { PreviewFirstRun.sheet(PreviewFirstRun.flow { $0.continueFromService() }) }
#Preview("Loading models") {
    PreviewFirstRun.sheet(PreviewFirstRun.flow { $0.key = "fake-key"; $0.continueFromService() })
}
