import Foundation

/// An Imp's own body clock. Breath, blinks and every mood's wiggle are pure functions of time,
/// so Imps sharing one clock would blink and bob in unison. Each Imp reads them through its own
/// offset instead (stable per Imp, from its id). Costs nothing: one addition per frame.
public struct BodyClock: Equatable, Sendable {
    public let offset: TimeInterval

    public static let shared = BodyClock(offset: 0)

    public init(offset: TimeInterval) { self.offset = offset }

    /// Somewhere in the first ten minutes, from the id's bytes (FNV-1a), so it's the same every launch.
    public init(_ id: UUID) {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        withUnsafeBytes(of: id.uuid) { for byte in $0 { hash = (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01b3 } }
        offset = Double(hash % 600_000) / 1000
    }

    /// This Imp's time at `date`.
    public func time(_ date: Date) -> TimeInterval { date.timeIntervalSinceReferenceDate + offset }
}
