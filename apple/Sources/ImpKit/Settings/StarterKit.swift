import Foundation

/// The starter kit: the triggers Imp offers on a fresh install (`spec/presets/starter-kit.json`, compiled
/// in as `Presets.starterKitJSON`). It is data, read by `Kit.parse` and added by `ImpPreferences.add(_:…)`
/// like a kit from The Den or a file: nothing in the app makes triggers of its own.
///
/// When it is offered: added for every Imp on a fresh install (`ImpPreferences.firstLaunch`), and again
/// only when the person asks (Add the starter kit in Triggers, which shows the usual kit review). A trigger
/// the person changed or deleted is never put back on its own.
extension Kit {
    /// The starter kit's JSON, for the kit review.
    public static var starterJSON: String { Presets.starterKitJSON }

    /// The starter kit, read like any other kit.
    public static func starter() throws -> Kit { try Kit.parse(starterJSON) }
}

extension ImpPreferences {
    /// The settings of a fresh install: bare settings, with every item of the starter kit added for every Imp.
    public static var firstLaunch: ImpPreferences {
        var prefs = ImpPreferences()
        if let kit = try? Kit.starter() { prefs.addAll(of: kit) }
        return prefs
    }

    /// Adds every item of `kit` for every Imp.
    mutating func addAll(of kit: Kit) {
        add(kit, imps: Set(kit.imps.map(\.id)), triggers: Set(kit.triggers.map(\.id)), servers: Set(kit.servers.map(\.id)),
            animations: Set(kit.animations.map(\.id)), for: nil)
    }

    /// Whether `trigger` is one of the starter kit's, as it came (any id): exporting leaves those out.
    func isStarter(_ trigger: Shortcut) -> Bool {
        guard let kit = try? Kit.starter() else { return false }
        return kit.triggers.contains { s in
            s.name == trigger.name && s.trigger == trigger.trigger && s.command == trigger.command
                && s.prompt == trigger.prompt && s.conditions == trigger.conditions && s.animation == trigger.animation
        }
    }
}
