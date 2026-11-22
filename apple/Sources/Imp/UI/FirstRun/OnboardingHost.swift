import ImpDesign
import ImpKit
import SwiftUI

/// The first run for one Imp, wired to the app: the real requests and the key store. The Imp is created only
/// when the last step's Next is pressed, and starts on the prompt at once.
struct OnboardingHost: View {
    let app: AppModel
    let target: FirstRunTarget
    let close: () -> Void
    @State private var flow: OnboardingModel
    @State private var linking = false

    /// `hatched` runs when a new Imp was created, so the canvas can pop it in.
    init(app: AppModel, target: FirstRunTarget, hatched: @escaping (UUID) -> Void = { _ in }, close: @escaping () -> Void) {
        self.app = app
        self.target = target
        self.close = close
        _flow = State(initialValue: Self.model(app: app, target: target, hatched: hatched))
    }

    static func model(app: AppModel, target: FirstRunTarget, hatched: @escaping (UUID) -> Void = { _ in }) -> OnboardingModel {
        let profile = target.profile(in: app.prefs.imps) ?? .imp
        let services = FirstRunServices.live(persona: profile.systemPrompt, probeSeconds: Double(Behavior.localProbeTimeoutSeconds),
                                             listSeconds: Double(Behavior.modelListTimeoutSeconds), checkSeconds: Double(Behavior.brainCheckTimeoutSeconds))
        let issuer = ResellerBuild.settings().map { settings in
            KeyIssuer(settings: settings, http: KeyIssuer.live(),
                      existing: { [weak app] in app?.storedConnection(baseURL: settings.baseUrl) },
                      store: { [weak app] brain in try app?.storeConnection(brain) })
        }
        return OnboardingModel(impName: profile.callName, target: target, issuer: issuer, services: services, onThisComputer: true,
                               store: { [weak app] brain in try app?.storeConnection(brain) },
                               create: { [weak app] brain, prompt in
            guard let app else { return }
            let id = try app.adoptFirstRunBrain(brain, for: target)
            if target.isNew {
                app.setActive(id, true)
                hatched(id)
            }
            if !prompt.isEmpty { app.send(setup: prompt, to: id) }
        })
    }

    /// The form for an existing Imp's connection with the real requests: it keeps the Brain for that Imp when it works.
    static func connectionForm(app: AppModel, imp: UUID) -> FirstRunModel {
        let profile = (FirstRunTarget.existing(imp).profile(in: app.prefs.imps) ?? .imp)
        let services = FirstRunServices.live(persona: profile.systemPrompt, probeSeconds: Double(Behavior.localProbeTimeoutSeconds),
                                             listSeconds: Double(Behavior.modelListTimeoutSeconds), checkSeconds: Double(Behavior.brainCheckTimeoutSeconds))
        return FirstRunModel(impName: profile.callName, target: .existing(imp), onThisComputer: true, services: services) { [weak app] brain, target in
            try app?.adoptFirstRunBrain(brain, for: target)
        }
    }

    var body: some View {
        let profile = target.profile(in: app.prefs.imps) ?? .imp
        OnboardingSheet(flow: flow, hue: profile.hue, traits: profile.traits, clock: BodyClock(profile.id),
                        linkDevice: target.isNew ? { linking = true } : nil, close: close)
            .sheet(isPresented: $linking) { LinkDeviceSheet(model: app, mode: .show) }
            // An Imp that came from the other device is the start: the sheet has nothing left to do.
            .onChange(of: app.prefs.imps.isEmpty) { _, none in
                if !none, target.isNew, !flow.isOver { close() }
            }
            .task { flow.begin() }
            .onDisappear { flow.cancel() }
    }
}
