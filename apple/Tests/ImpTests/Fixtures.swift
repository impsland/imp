import ImpKit

extension ImpProfile {
    /// An Imp at home, for a test whose app starts with none (a fresh install has no Imp).
    static var waiting: ImpProfile {
        var p = ImpProfile.imp
        p.isActive = false
        return p
    }
}
