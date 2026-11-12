import Foundation
import ImpCore

/// What one device may have an Imp here work on for it at a time (see `docs/connecting/link.md`, "Trust"):
/// one answer runs, a few wait, and the rest are told it is busy, so another device can't pile work up.
/// The core decides who is let in. The lane keeps the jobs.
public struct LinkLane<Job> {
    public enum Admission: Equatable, Sendable {
        case run, wait, busy
    }

    /// How many may wait behind the one that runs.
    public static var waiting: Int { Int(linkLaneLimits().waiting) }
    /// How many files one device may be sent at once.
    public static var files: Int { Int(linkLaneLimits().files) }

    public private(set) var isRunning = false
    public private(set) var queue: [Job] = []

    public init() {}

    /// `run` if it may start now (the caller starts it), `wait` if it was queued, `busy` if it is turned away.
    public mutating func submit(_ job: Job) -> Admission {
        switch linkLaneAdmit(running: isRunning, queued: UInt32(queue.count)) {
        case "run": isRunning = true; return .run
        case "wait": queue.append(job); return .wait
        default: return .busy
        }
    }

    /// The running job ended: the next one to start, if any waits.
    public mutating func finish() -> Job? {
        guard !queue.isEmpty else { isRunning = false; return nil }
        return queue.removeFirst()
    }

    /// Drops everything waiting (the device went away). What runs goes on.
    public mutating func clear() -> [Job] {
        defer { queue = [] }
        return queue
    }

    public var isIdle: Bool { !isRunning && queue.isEmpty }
}
