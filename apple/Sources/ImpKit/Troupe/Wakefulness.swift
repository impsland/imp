import Foundation

/// Whether an Imp can think right now. The Mac and the iPhone both decide it here, for an Imp at
/// home and for one visiting from another device, so the two apps can't drift apart. An Imp that
/// can't think sleeps: nothing it does (a reaction, a tool step, an animation, being carried) shows
/// it awake, and asking it is refused at once with the reason.
public enum Wakefulness: Equatable, Sendable {
    case awake
    /// A visit whose home device is out of reach: its brain is there.
    case homeAway
    /// No usable brain at its home: no service, no model, or no key for a service that needs one.
    case noBrain

    /// An Imp at home: `brainReady` is this device's own check of its brain.
    public static func atHome(brainReady: Bool) -> Wakefulness { brainReady ? .awake : .noBrain }

    /// A visiting Imp. `homeConnected`: its home is reachable. `homeSaysReady`: what the home last
    /// said about its brain (`LinkMessage.brain`). A home out of reach wins, since that is what
    /// has to change first.
    public static func visiting(homeConnected: Bool, homeSaysReady: Bool) -> Wakefulness {
        guard homeConnected else { return .homeAway }
        return homeSaysReady ? .awake : .noBrain
    }

    public var isAwake: Bool { self == .awake }
}
