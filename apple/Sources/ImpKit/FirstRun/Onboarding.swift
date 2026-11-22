import Foundation
import Observation

/// The three steps of the first run, in order.
public enum OnboardingStep: Int, CaseIterable, Equatable, Sendable {
    /// "Your model is ready": the key is issued, or the user's own connection is checked.
    case model = 1
    /// "Move your Imp": how an Imp goes to another device.
    case move
    /// "Let your Imp set itself up": the prompt the new Imp starts on.
    case setup
}

/// The words the new Imp starts on, in the user's language and in plain words: the Imp knows its own tools.
/// Where an Imp is tapped (the iPhone) it says tap, elsewhere click.
public enum OnboardingPrompt {
    public static var preset: String {
        #if os(iOS)
        String(localized: "onboarding.prompt.tap")
        #else
        String(localized: "onboarding.prompt")
        #endif
    }
}

/// The first run, step by step, for every platform: the views only show it. The user presses Next and nothing
/// else. A build that comes with a model service (`issuer`) gets its key while step 1 shows. In any other
/// build, or after "Change connection", step 1 holds the form for an address, a key and a model.
/// The Imp is created only by Next on the last step, and starts on the prompt at once.
@MainActor @Observable
public final class OnboardingModel {
    public let impName: String
    public let issuer: KeyIssuer?
    /// The form for the user's own connection (address, key, model) and its check.
    public private(set) var form: FirstRunModel!
    public private(set) var step = OnboardingStep.model
    /// Whether step 1 shows the form instead of the model that came with the app.
    public private(set) var editingConnection: Bool
    /// What the new Imp is asked first. The user may change it.
    public var prompt = OnboardingPrompt.preset
    /// The Imp was created and the prompt sent: the flow is over.
    public private(set) var isOver = false
    /// Why the Imp could not be created, in words.
    public private(set) var problem: String?

    @ObservationIgnored private var formBrain: FirstRunBrain?
    @ObservationIgnored private let create: @MainActor (_ brain: FirstRunBrain, _ prompt: String) throws -> Void

    /// `store` keeps a checked connection (service, model, key) without creating the Imp. `create` makes the Imp
    /// with that connection and sends it the prompt (empty: nothing to send). It runs once.
    public init(impName: String, target: FirstRunTarget, issuer: KeyIssuer?, services: FirstRunServices,
                onThisComputer: Bool, store: @escaping @MainActor (FirstRunBrain) throws -> Void,
                create: @escaping @MainActor (FirstRunBrain, String) throws -> Void) {
        self.impName = impName
        self.issuer = issuer
        self.create = create
        editingConnection = issuer == nil
        form = FirstRunModel(impName: impName, target: target, onThisComputer: onThisComputer, services: services,
                             awakeBeat: .milliseconds(300)) { [weak self] brain, _ in
            try store(brain)
            self?.formBrain = brain
            self?.advanceAfterCheck()
        }
    }

    /// Starts what step 1 needs: the key of a build that comes with a service.
    public func begin() {
        issuer?.start()
    }

    /// The connection the Imp will think with, once step 1 has one.
    public var brain: FirstRunBrain? {
        editingConnection ? formBrain : issuer?.brain
    }

    /// Whether the build comes with a model service.
    public var isReseller: Bool { issuer != nil }

    /// Next is off only while the step needs something that is not there yet: the key is being issued or
    /// failed, the connection of the form is being checked, or the Imp is being created.
    public var nextEnabled: Bool {
        switch step {
        case .model: brain != nil || (editingConnection && !form.path.isBusy)
        case .move, .setup: true
        }
    }

    public var canGoBack: Bool { step != .model && !isOver }

    public func next() {
        guard nextEnabled else { return }
        switch step {
        case .model:
            if brain != nil { step = .move } else { form.wakeUp() }
        case .move: step = .setup
        case .setup: finish()
        }
    }

    public func back() {
        guard canGoBack, let previous = OnboardingStep(rawValue: step.rawValue - 1) else { return }
        step = previous
    }

    /// "Change connection": step 1 shows the form, with the model that came with the app set aside.
    public func changeConnection() {
        editingConnection = true
        step = .model
    }

    /// Back to the model that came with the app.
    public func useIncludedModel() {
        guard issuer != nil else { return }
        editingConnection = false
    }

    public func cancel() {
        issuer?.cancel()
        form.cancel()
    }

    private func advanceAfterCheck() {
        if step == .model, editingConnection { step = .move }
    }

    private func finish() {
        guard !isOver, let brain else { return }
        problem = nil
        do {
            try create(brain, prompt.trimmingCharacters(in: .whitespacesAndNewlines))
            isOver = true
        } catch {
            problem = error.localizedDescription
        }
    }
}
