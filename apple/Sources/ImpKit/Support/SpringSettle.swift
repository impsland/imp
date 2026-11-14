import Foundation

/// Whether a set of springs has come to rest. While any is still moving, the face must keep being
/// drawn at full frame rate: drawing it only now and then (the resting pace, which wakes for blinks)
/// would advance the springs in a few big steps, and a turn of the head would play as two or
/// three jerks instead of one smooth move.
public enum SpringSettle {
    /// Close enough to the target, and slow enough, to stop drawing.
    public static let distance = 0.002
    public static let speed = 0.01

    public static func isSettled(values: [Double], targets: [Double], velocities: [Double]) -> Bool {
        for i in values.indices {
            if abs(targets[i] - values[i]) > distance || abs(velocities[i]) > speed { return false }
        }
        return true
    }
}

/// One damped spring, stepped by the real time a frame took, so a value eases towards a goal that
/// only changes now and then (a sensor read 30 times a second, a cursor read at each frame) and
/// moves the same at any frame rate. The time is cut into steps of at most 1/120 s, which keeps the
/// integration stable however long a frame took, and the result within a hair of the same at 30, 60
/// or 120 frames a second.
public enum SpringStep {
    /// The longest gap that still counts as time passing. A longer one is a pause in drawing.
    public static let longestGap: TimeInterval = 0.1
    public static let substep: TimeInterval = 1.0 / 120

    public static func advance(_ value: inout Double, velocity: inout Double, to goal: Double,
                               stiffness: Double, damping: Double, dt: TimeInterval) {
        let elapsed = min(max(dt, 0), longestGap)
        guard elapsed > 0 else { return }
        let n = Int((elapsed / substep).rounded(.up))
        let h = elapsed / Double(n)
        for _ in 0..<n {
            velocity += ((goal - value) * stiffness - velocity * damping) * h
            value += velocity * h
        }
    }
}
