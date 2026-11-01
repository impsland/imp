import Foundation

/// What one device may have an Imp here work on for it at a time (see `docs/LINK.md`, "Trust"): one
/// answer runs, a few wait, and the rest are told it is busy, so another device can't pile work up.
public struct LinkLane<Job> {
    public enum Admission: Equatable, Sendable {
        case run, wait, busy
    }

    /// How many may wait behind the one that runs.
    public static var waiting: Int { 3 }
    /// How many files one device may be sent at once.
    public static var files: Int { 2 }

    public private(set) var isRunning = false
    public private(set) var queue: [Job] = []

    public init() {}

    /// `run` if it may start now (the caller starts it), `wait` if it was queued, `busy` if it is turned away.
    public mutating func submit(_ job: Job) -> Admission {
        if !isRunning { isRunning = true; return .run }
        guard queue.count < Self.waiting else { return .busy }
        queue.append(job)
        return .wait
    }

    /// The running job ended: the next one to start, if any waits.
    public mutating func finish() -> Job? {
        guard !queue.isEmpty else { isRunning = false; return nil }
        return queue.removeFirst()
    }

    /// Drops everything waiting (the device went away); what runs goes on.
    public mutating func clear() -> [Job] {
        defer { queue = [] }
        return queue
    }

    public var isIdle: Bool { !isRunning && queue.isEmpty }
}
