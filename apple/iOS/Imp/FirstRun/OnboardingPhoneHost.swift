import ImpDesign
import ImpKit
import SwiftUI

/// The first run on the iPhone, wired to the app: the real requests, the Keychain, and the pocket that makes the Imp.
/// The Imp is made only by Next on the last step, with the connection step 1 gave it, and starts on the prompt.
@MainActor enum OnboardingPhoneHost {
    static var impName: String { PairingView.firstName }

    static func model(pocket: PocketRuntime, id: UUID) -> OnboardingModel {
        let services = FirstRunServices.live(persona: Persona.pocket(named: impName), probeSeconds: Double(Behavior.localProbeTimeoutSeconds),
                                             listSeconds: Double(Behavior.modelListTimeoutSeconds), checkSeconds: Double(Behavior.brainCheckTimeoutSeconds))
        return OnboardingModel(impName: impName, target: .existing(id), issuer: issuer(), services: services, onThisComputer: false,
                               store: { _ in }, create: { [weak pocket] brain, prompt in
            guard let pocket else { return }
            var imp = PocketImp(id: id, name: impName)
            if !brain.key.isEmpty {
                do { try pocket.secrets.set(brain.key, .apiKey, imp: id) } catch { throw KeyNotSaved() }
            }
            imp.brain = PocketService(brain)
            pocket.hatch(imp)
            if !prompt.isEmpty { pocket.ask(id, prompt) }
        })
    }

    /// The model service of this build with the key store of the install, or nil for a manual build.
    private static func issuer() -> KeyIssuer? {
        #if DEBUG
        if let stub = UITestReseller.issuer() { return stub }
        #endif
        return ResellerBuild.settings().map { settings in
            KeyIssuer(settings: settings, http: KeyIssuer.live(), existing: { IssuedConnection.read(baseURL: settings.baseUrl) },
                      store: { try IssuedConnection.write($0) })
        }
    }
}

#if DEBUG
/// For the UI tests on a device (`-uiTestSandbox`): a model service that came with the app and already issued its key,
/// so the first run needs no network. `-uiTestReseller <address>` names the service.
@MainActor enum UITestReseller {
    static func issuer() -> KeyIssuer? {
        let arguments = CommandLine.arguments
        guard arguments.contains("-uiTestSandbox"), let i = arguments.firstIndex(of: "-uiTestReseller"), arguments.indices.contains(i + 1),
              let settings = ResellerBuild.settings(base: arguments[i + 1], issuance: arguments[i + 1]) else { return nil }
        let brain = FirstRunBrain(name: settings.host, baseURL: settings.baseUrl, model: "uitest-model", key: "uitest-key", isLocal: false)
        return KeyIssuer(settings: settings, http: KeyIssuer.live(), existing: { brain }, store: { _ in })
    }
}
#endif
