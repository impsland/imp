import ImpDesign
import ImpKit
import SwiftUI

/// The first run for one Imp, wired to the app: the real requests and the key store.
struct FirstRunHost: View {
    let app: AppModel
    let id: UUID
    let close: () -> Void
    @State private var flow: FirstRunModel

    init(app: AppModel, id: UUID, close: @escaping () -> Void) {
        self.app = app
        self.id = id
        self.close = close
        _flow = State(initialValue: Self.model(app: app, id: id))
    }

    /// The model of the first run for an Imp, with the real requests. The Brain panel builds the same one.
    static func model(app: AppModel, id: UUID) -> FirstRunModel {
        let profile = app.profile(id) ?? .imp
        let services = FirstRunServices.live(persona: profile.systemPrompt, probeSeconds: Double(Behavior.localProbeTimeoutSeconds), listSeconds: Double(Behavior.modelListTimeoutSeconds),
                                             checkSeconds: Double(Behavior.brainCheckTimeoutSeconds))
        return FirstRunModel(impName: profile.callName, onThisComputer: true, services: services) { [weak app] brain in
            try app?.adoptFirstRunBrain(brain, for: id)
        }
    }

    var body: some View {
        let profile = app.profile(id) ?? .imp
        FirstRunSheet(flow: flow, hue: profile.hue, traits: profile.traits, clock: BodyClock(id), close: close)
            .onDisappear { flow.cancel() }
    }
}
