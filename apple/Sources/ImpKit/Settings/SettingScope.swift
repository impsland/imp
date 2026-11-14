import Foundation

/// Where a trigger or a made animation applies, as one Imp's settings see it.
///
/// The rules (see `docs/ux/imp-settings.md#scope`):
/// - A shared item applies to every Imp that has no version of its own. A new Imp gets every shared item.
/// - A change made in one Imp's settings applies to that Imp alone, unless the person picks Every Imp.
///   Changing a shared item for one Imp makes that Imp's own version (`overrides` points at the
///   shared one). The shared one stays as it is for every other Imp.
/// - Removing an Imp's version brings the shared one back for that Imp. Removing a shared item (an
///   explicit Every Imp action) leaves the Imps' own versions with them, as their own.
public enum SettingScope: String, Sendable, Hashable, CaseIterable {
    /// Shared: every Imp uses it, this one as it is.
    case everyImp
    /// This Imp's own version of a shared one. The other Imps keep the shared one.
    case changed
    /// Only this Imp has it.
    case onlyThisImp
}

/// Where a change goes: to the shared items, or to one Imp alone.
public enum ScopeTarget: Hashable, Sendable {
    case everyImp
    case imp(UUID)

    /// The Imp it is for, nil for every Imp.
    public var imp: UUID? {
        if case .imp(let id) = self { return id }
        return nil
    }
}

extension ImpPreferences {
    /// Adds a new Imp by the one rule for new Imps, and returns its id. It gets a name nobody has, the
    /// red every Imp hatches in, a fresh personality and a secret favourite colour, and waits at home. It
    /// has nothing of its own: it follows the default Brain, gets every shared trigger and animation, has
    /// the built-in tools at their defaults and no extra tools. Nothing is copied from another Imp.
    @discardableResult
    public mutating func addNewcomer() -> UUID {
        var profile = ImpProfile.newcomer(joining: imps)
        profile.name = ImpProfile.randomName(avoiding: imps.map(\.name))
        profile.personality = Persona.newcomer(named: profile.name)
        profile.isActive = false
        imps.append(profile)
        return profile.id
    }
}
