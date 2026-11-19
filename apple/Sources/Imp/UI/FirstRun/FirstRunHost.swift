import ImpDesign
import ImpKit
import SwiftUI

/// The first run for one Imp, wired to the app: the real requests and the key store. The Imp is an existing one
/// with no Brain, or a new one that is hatched (with its Brain, on the canvas) only when the Brain works.
struct FirstRunHost: View {
    let app: AppModel
    let target: FirstRunTarget
    let close: () -> Void
    @State private var flow: FirstRunModel
    @State private var linking = false

    /// `hatched` runs when a new Imp was hatched, so the canvas can pop it in.
    init(app: AppModel, target: FirstRunTarget, hatched: @escaping (UUID) -> Void = { _ in }, close: @escaping () -> Void) {
        self.app = app
        self.target = target
        self.close = close
        _flow = State(initialValue: Self.model(app: app, target: target, hatched: hatched))
    }

    /// The model of the first run for an Imp, with the real requests. The Brain panel builds the same one.
    static func model(app: AppModel, target: FirstRunTarget, hatched: @escaping (UUID) -> Void = { _ in }) -> FirstRunModel {
        let profile = target.profile(in: app.prefs.imps) ?? .imp
        let services = FirstRunServices.live(persona: profile.systemPrompt, probeSeconds: Double(Behavior.localProbeTimeoutSeconds), listSeconds: Double(Behavior.modelListTimeoutSeconds),
                                             checkSeconds: Double(Behavior.brainCheckTimeoutSeconds))
        return FirstRunModel(impName: profile.callName, target: target, onThisComputer: true, services: services) { [weak app] brain, target in
            guard let id = try app?.adoptFirstRunBrain(brain, for: target) else { return }
            if case .newImp = target { hatched(id) }
        }
    }

    var body: some View {
        let profile = target.profile(in: app.prefs.imps) ?? .imp
        FirstRunSheet(flow: flow, hue: profile.hue, traits: profile.traits, clock: BodyClock(profile.id),
                      linkDevice: target.isNew ? { linking = true } : nil, close: close)
            .sheet(isPresented: $linking) { LinkDeviceSheet(model: app, mode: .show) }
            // An Imp that came from the other device is the start: the sheet has nothing left to do.
            .onChange(of: app.prefs.imps.isEmpty) { _, none in
                if !none, target.isNew, flow.path.imp == .asleep { close() }
            }
            .onDisappear { flow.cancel() }
    }
}
