import Foundation

/// The two sides of an Imp's sheet on a phone: its chat with you, and its talks with other Imps.
public enum ImpPane: String, CaseIterable, Sendable {
    case chat, talks
}

/// A sheet over the room on a phone. There is only ever one, and the room stays under it.
public enum PhoneRoute: Hashable, Identifiable, Sendable {
    /// Everything about one Imp: its chat and its talks (`PhoneRouter.pane` says which is shown).
    case imp(UUID)
    /// Making a new Imp.
    case hatch
    /// An Imp's settings. `brain` opens them on the Brain.
    case edit(UUID, brain: Bool)
    /// Waking an Imp that has no Brain, step by step.
    case firstRun(UUID)
    /// The app's settings. `devices` opens them on the linked devices.
    case settings(devices: Bool)

    /// What makes a sheet a different sheet. Every Imp's sheet is the same one: going from one Imp to
    /// another (a tap on an Imp in the room above the sheet) changes what it shows, in place, and does
    /// not put the sheet away and bring another.
    public enum Identity: Hashable, Sendable {
        case imp
        case other(PhoneRoute)
    }

    public var id: Identity {
        if case .imp = self { .imp } else { .other(self) }
    }

    /// The Imp this sheet is about. It comes up into the room left above the sheet, and the sheet wears its colour.
    public var imp: UUID? {
        switch self {
        case .imp(let id), .edit(let id, _), .firstRun(let id): id
        case .hatch, .settings: nil
        }
    }

    /// The sheet can rest at half height, with the room alive above it. The others need the whole screen.
    public var restsAtHalf: Bool {
        switch self {
        case .imp, .settings: true
        case .hatch, .edit, .firstRun: false
        }
    }
}

/// Which sheet is over the room, and where Close leads. One rule for every platform that shows sheets
/// over a room: a step taken from an Imp's sheet (its settings) returns to that sheet, anything else
/// returns to the room.
public struct PhoneRouter: Equatable, Sendable {
    public private(set) var route: PhoneRoute?
    /// The side of the Imp's sheet that is shown.
    public var pane = ImpPane.chat
    /// The Imp's sheet a step was taken from, to return to.
    private var origin: PhoneRoute?

    public init() {}

    /// Opens an Imp's sheet on its chat.
    public mutating func talk(_ id: UUID) { show(id, .chat) }

    /// Opens an Imp's sheet on its talks with other Imps.
    public mutating func talks(_ id: UUID) { show(id, .talks) }

    private mutating func show(_ id: UUID, _ pane: ImpPane) {
        route = .imp(id)
        self.pane = pane
        origin = nil
    }

    /// Opens a sheet. An Imp's settings opened from that Imp's own sheet remember it, so Close goes back there.
    public mutating func open(_ next: PhoneRoute) {
        if case .imp(let id) = next { return show(id, .chat) }
        if case .edit(let id, _) = next, route == .imp(id) {
            origin = route
        } else if case .edit(let id, _) = next, origin == .imp(id) {
            // Already a step from this Imp's sheet (its settings opening on another panel): the way back stays.
        } else {
            origin = nil
        }
        route = next
    }

    /// Close, or the end of a flow. Returns to the Imp's sheet the step was taken from when that Imp is
    /// still here (`exists`), otherwise to the room.
    public mutating func close(exists: (UUID) -> Bool) {
        if let origin, let id = origin.imp, exists(id), route != origin {
            route = origin
        } else {
            route = nil
        }
        origin = nil
    }

    /// The person swiped the sheet away: straight back to the room, wherever it was opened from.
    public mutating func dismissed() {
        route = nil
        origin = nil
    }

    /// An Imp woke up at the end of its first run: its chat comes up.
    public mutating func woke(_ id: UUID) { show(id, .chat) }

    /// An Imp left (it went home, was moved or deleted): a sheet about it has nothing to show.
    public mutating func left(_ id: UUID) {
        if origin?.imp == id { origin = nil }
        if route?.imp == id { route = nil; origin = nil }
    }
}

/// Where an Imp waits while its sheet is open: in the middle of the room left above the sheet, a little
/// below the centre so its speech bubble has room above it. Nil when there is no room for it (the sheet
/// covers the screen), and then the Imp stays where it is.
public enum Summon {
    /// - Parameters:
    ///   - room: The size of the room (the whole screen).
    ///   - top: What the system keeps at the top (the safe area).
    ///   - cover: The share of the room's height the sheet covers, from the bottom (0 to 1).
    ///   - side: The Imp's size.
    ///   - height: How far down the free room the Imp waits (0 top, 1 bottom).
    public static func point(room: CGSize, top: CGFloat, cover: CGFloat, side: CGFloat, height: CGFloat) -> CGPoint? {
        guard cover > 0, room.width > 0 else { return nil }
        let bottom = room.height * (1 - min(max(cover, 0), 1))
        let free = bottom - top
        // Room for the Imp and a bubble over it, or it is better left alone.
        guard free >= side * 1.5 else { return nil }
        let y = top + free * min(max(height, 0), 1)
        return CGPoint(x: room.width / 2, y: min(max(y, top + side / 2), bottom - side / 2))
    }
}
