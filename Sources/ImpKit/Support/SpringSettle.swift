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
