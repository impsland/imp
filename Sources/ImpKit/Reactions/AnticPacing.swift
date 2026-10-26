import Foundation

/// When an unprompted routine may start.
public enum AnticPacing {
    /// Seconds a routine waits after Imp becomes free again (a bubble closes, a job ends) before it
    /// may play, so a start time that passed while Imp was busy doesn't fire the moment it's free.
    public static let settle = 3.0

    /// The next time a routine may start: never earlier than `settle` after the last moment Imp was
    /// not free.
    public static func nextStart(_ next: Date, now: Date, free: Bool) -> Date {
        free ? next : max(next, now.addingTimeInterval(settle))
    }
}
