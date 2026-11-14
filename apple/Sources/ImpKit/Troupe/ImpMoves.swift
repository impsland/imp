import Foundation

/// What a drag does at the edge of the app window. The window is a place an Imp stands in, and
/// the desktop is where a free Imp lives, so an Imp that crosses the edge changes where it is.
///
/// The rules, in one place:
/// - In the window the Imp follows the pointer unclamped. It is kept inside the canvas only when it settles.
/// - It is handed to its own desktop panel the moment its frame is no longer wholly inside the window
///   (the Imp's frame decides, not the pointer). The panel appears exactly where the Imp is drawn and keeps
///   the grab: where the pointer holds the Imp stays the same.
/// - A free Imp let go with the pointer over the window goes home to where it is drawn, under the same grab.
///
/// All rectangles and points here share one space (the screen, y up).
public enum ImpDrag {
    public enum Result: Equatable, Sendable { case stay, letOut, sendHome }

    /// While the hand is still down: an Imp in the window is handed to its own panel as soon as
    /// its `figure` is not wholly inside the `arena` (the window), and the same drag goes on there.
    public static func whileDragging(isFree: Bool, figure: CGRect, arena: CGRect) -> Result {
        !isFree && !arena.contains(figure) ? .letOut : .stay
    }

    /// When the hand lets go: a free Imp dropped over the window goes home.
    public static func onDrop(isFree: Bool, pointerInWindow: Bool) -> Result {
        isFree && pointerInWindow ? .sendHome : .stay
    }

    /// Where the pointer holds an Imp: from the middle of the Imp to the pointer.
    public static func grab(pointer: CGPoint, centre: CGPoint) -> CGSize {
        CGSize(width: pointer.x - centre.x, height: pointer.y - centre.y)
    }

    /// The origin of an Imp's panel (`side` points square) that keeps the pointer where `grab` says.
    public static func origin(pointer: CGPoint, grab: CGSize, side: CGFloat) -> CGPoint {
        CGPoint(x: pointer.x - grab.width - side / 2, y: pointer.y - grab.height - side / 2)
    }
}

/// A change the Undo bar can take back.
public struct UndoOffer: Equatable, Sendable {
    public enum Kind: Equatable, Sendable { case letOut, sendHome, hide }

    public let kind: Kind
    public let imp: UUID
    public let expires: Date
    private let offered: Date

    public init(_ kind: Kind, imp: UUID, seconds: Int, at now: Date = Date()) {
        self.init(kind, imp: imp, seconds: Double(seconds), at: now)
    }

    public init(_ kind: Kind, imp: UUID, seconds: Double, at now: Date = Date()) {
        self.kind = kind
        self.imp = imp
        offered = now
        expires = now.addingTimeInterval(seconds)
    }

    /// Whether the bar is still showing at `now`.
    public func isOpen(at now: Date) -> Bool { now >= offered && now < expires }
}

/// When a hidden Imp peeks out from the floor. The numbers come from the design tokens.
public struct PeekPlan: Equatable, Sendable {
    public var minSeconds: Double
    public var maxSeconds: Double
    public var showSeconds: Double
    public var quietSeconds: Double

    public init(minSeconds: Double, maxSeconds: Double, showSeconds: Double, quietSeconds: Double) {
        self.minSeconds = minSeconds
        self.maxSeconds = maxSeconds
        self.showSeconds = showSeconds
        self.quietSeconds = quietSeconds
    }

    /// The wait before the next peek, for a random `unit` from 0 to 1.
    public func wait(unit: Double) -> TimeInterval {
        minSeconds + min(1, max(0, unit)) * (maxSeconds - minSeconds)
    }

    /// Only one Imp peeks at a time, only while the window is seen and the user has not typed for a while.
    public func mayPeek(windowVisible: Bool, secondsSinceTyping: Double, peeking: Bool, hidden: Int) -> Bool {
        windowVisible && !peeking && hidden > 0 && secondsSinceTyping >= quietSeconds
    }

    /// Who peeks next: the one after `last` in the list, so they take turns.
    public func pick(from hidden: [UUID], after last: UUID?) -> UUID? {
        guard let first = hidden.first else { return nil }
        guard let last, let i = hidden.firstIndex(of: last) else { return first }
        return hidden[(i + 1) % hidden.count]
    }
}

/// The Imps a person hid on a screen that has no profile flag for it (the phone). They keep their
/// order, they are not on the stage, and they peek from the floor until one is brought back.
public struct HiddenImps: Codable, Equatable, Sendable {
    public private(set) var ids: [UUID] = []

    public init() {}

    public func contains(_ id: UUID) -> Bool { ids.contains(id) }

    public mutating func hide(_ id: UUID) {
        if !contains(id) { ids.append(id) }
    }

    public mutating func bringBack(_ id: UUID) { ids.removeAll { $0 == id } }

    public mutating func bringBackAll() { ids = [] }

    /// Drops Imps that are not in `roster` any more.
    public mutating func forget(except roster: [UUID]) { ids = ids.filter(roster.contains) }

    /// The roster without the hidden ones.
    public func standing(in roster: [UUID]) -> [UUID] { roster.filter { !contains($0) } }

    /// The hidden ones that are still in `roster`, in its order.
    public func onFloor(in roster: [UUID]) -> [UUID] { roster.filter(contains) }
}
