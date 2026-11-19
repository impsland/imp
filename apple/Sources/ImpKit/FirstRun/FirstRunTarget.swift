import Foundation

/// Whose Brain the first run is choosing.
public enum FirstRunTarget: Equatable, Sendable {
    /// An Imp that already exists and has no Brain: the Brain is adopted for it.
    case existing(UUID)
    /// An Imp that is not in the settings yet: it is hatched together with its first Brain, so an Imp
    /// never exists without one. Cancelling leaves nothing behind.
    case newImp(ImpProfile)
}

extension FirstRunTarget {
    /// Whether the Imp does not exist yet.
    public var isNew: Bool { if case .newImp = self { true } else { false } }

    /// The Imp this is for: the one that is not hatched yet, or the existing one among `imps`.
    public func profile(in imps: [ImpProfile]) -> ImpProfile? {
        switch self {
        case .existing(let id): imps.first { $0.id == id }
        case .newImp(let profile): profile
        }
    }
}

extension ImpPreferences {
    /// The Imp that would hatch next, for the first run to show asleep before it exists: a free name and
    /// the colour every Imp hatches in. It is not in `imps`.
    public func nextImp() -> ImpProfile {
        var profile = ImpProfile.newcomer(joining: imps)
        profile.isActive = false
        return profile
    }

    /// Keeps the Brain the first run checked. For a new Imp it hatches it with that Brain, at home (let out
    /// later like any Imp). Returns the Imp's id.
    @discardableResult
    public mutating func keep(_ brain: FirstRunBrain, for target: FirstRunTarget) -> UUID {
        switch target {
        case .existing(let id):
            adopt(brain, for: id)
            return id
        case .newImp(let profile):
            var hatched = profile
            hatched.brain = nil
            hatched.isActive = false
            imps.append(hatched)
            adopt(brain, for: hatched.id)
            return hatched.id
        }
    }
}
