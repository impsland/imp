import Foundation
import ImpKit

/// What a visiting Imp is here: its body is on this Mac's desktop, its brain at its home (see "Visit"
/// in `docs/LINK.md`). Its looks, chat, work and mood come from there, and what you ask it goes there.
struct Visiting: Equatable {
    var look: LinkImp
    var homeID: UUID
    /// The home's name, as it is shown ("Mac mini is away").
    var homeName: String
    /// The home is connected. A visit whose home isn't sleeps.
    var isAwake: Bool
    /// The side of the desktop it came in by (it leaves by it when it goes home).
    var side: LinkSide

    /// Its looks as a profile, for the renderer and the bubble. It has no model or tools here.
    var profile: ImpProfile {
        var profile = ImpProfile(id: look.id, name: look.name, hue: look.hue, favoriteHue: look.hue, scale: look.scale, personality: "")
        profile.traits = look.traits
        return profile
    }
}
