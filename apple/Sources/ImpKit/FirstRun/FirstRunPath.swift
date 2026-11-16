import Foundation

/// Where the first run is. Two named steps, the same on every platform, and the moments in between.
public enum FirstRunStep: Equatable, Sendable {
    /// Step 1: a preset or any address, and the key.
    case service
    /// Between 1 and 2: the models are being loaded from the address, with the key.
    case loadingModels
    /// Step 2: pick a model.
    case model
    /// Step 2, working: a tiny request while the Imp stirs.
    case checking
    /// Step 2, the check failed: a sentence says what to do next. What the user typed is kept.
    case failed
    /// Step 2, done: the Imp is awake. The flow ends by itself.
    case awake
    /// The Imp is awake and keeps its Brain: the flow is over.
    case done
}

/// What happens on the path. The rules for the next step live in `FirstRunPath.apply`.
public enum FirstRunEvent: Equatable, Sendable {
    case load
    case loaded
    case loadFailed
    case check
    case checkWorked
    case checkFailed
    case carryOn
    case back
    /// The model was typed without a list (the listing failed): straight to the model step.
    case skipList
    /// Jump to a step by its number (1 or 2), when it is unlocked.
    case go(Int)
}

/// How the Imp looks along the path.
public enum FirstRunImpState: Equatable, Sendable {
    case asleep, stirring, awake
}

/// The path as a value: the current step and how far the user got. Pure, so every platform follows the same steps.
/// There is no way to skip it: closing leaves the Imp asleep, which is a calm state of its own.
public struct FirstRunPath: Equatable, Sendable {
    public private(set) var step = FirstRunStep.service
    /// The furthest step the user can jump to (1 or 2).
    public private(set) var reached = 1

    public init() {}

    /// The key of each step's name, in order.
    public static let names = ["firstrun.step.service", "firstrun.step.model"]

    /// The numbered steps, for "Step 1 of 2".
    public static var totalSteps: Int { names.count }

    /// 1 for the service, 2 for the model and the check. Nil once the flow is over.
    public var number: Int? {
        switch step {
        case .service, .loadingModels: 1
        case .model, .checking, .failed, .awake: 2
        case .done: nil
        }
    }

    /// The Imp sleeps until the check works.
    public var imp: FirstRunImpState {
        switch step {
        case .checking: .stirring
        case .awake, .done: .awake
        default: .asleep
        }
    }

    /// Something is running, so the user waits (or goes back to cancel it).
    public var isBusy: Bool { step == .loadingModels || step == .checking || step == .awake }

    public var isOver: Bool { step == .done }

    /// Back is offered from every step but the first, and not while the Imp is waking up.
    public var canGoBack: Bool { (number ?? 1) > 1 && step != .awake }

    /// Whether the step indicator may jump to step `n`: only to one already reached, and never while something runs.
    public func canGo(to n: Int) -> Bool {
        !isBusy && !isOver && n >= 1 && n <= reached && n != number
    }

    public mutating func go(to n: Int) { apply(.go(n)) }

    /// Moves on. An event that makes no sense at the current step changes nothing.
    public mutating func apply(_ event: FirstRunEvent) {
        switch (step, event) {
        case (.service, .load): step = .loadingModels
        case (.loadingModels, .loaded): step = .model; reached = max(reached, 2)
        case (.loadingModels, .loadFailed): step = .service
        case (.service, .skipList): step = .model; reached = max(reached, 2)
        case (.model, .check), (.failed, .check): step = .checking
        case (.checking, .checkWorked): step = .awake
        case (.checking, .checkFailed): step = .failed
        case (.awake, .carryOn): step = .done
        case (.loadingModels, .back): step = .service
        case (.checking, .back), (.failed, .back): step = .model
        case (.model, .back): step = .service
        case (_, .go(let n)):
            guard canGo(to: n) else { break }
            step = [FirstRunStep.service, .model][n - 1]
        default: break
        }
    }
}
