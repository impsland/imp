import Foundation

/// When a bubble's "Hide after" clock may run. Only a finished one (an answer, an error, a hint)
/// times out, and never while the user is with it: the pointer is on it, its audio or video is
/// playing, or they made it theirs (read it in full, moved or resized it). The clock starts over,
/// in full, once none of that holds any more.
public enum BubbleTimeout {
    public static func mayHide(finished: Bool, hovered: Bool, kept: Bool, playing: Bool) -> Bool {
        finished && !hovered && !kept && !playing
    }
}
