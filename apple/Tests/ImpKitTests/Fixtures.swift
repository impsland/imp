import ImpKit

extension ImpPreferences {
    /// Settings with one Imp waiting at home, for tests of what a troupe does. A fresh install has no Imp at all
    /// (`ImpPreferences()`).
    static func withWaitingImp() -> ImpPreferences {
        var p = ImpPreferences()
        var imp = ImpProfile.imp
        imp.isActive = false
        p.imps = [imp]
        return p
    }
}
