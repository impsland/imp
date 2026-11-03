/// When the speech bubble shows its little trail down to Imp. Only a small bubble that still
/// belongs to Imp has one: the chat, a bubble read in full (a panel of its own) and a bubble
/// the user moved away have none.
public enum BubbleTail {
    public static func isShown(chat: Bool, expanded: Bool, detached: Bool) -> Bool {
        !chat && !expanded && !detached
    }

    /// Whether a move of the bubble's window is the user dragging it. Moves we make ourselves
    /// (resizing for "Read all", following Imp) must never detach the bubble from Imp.
    public static func isUserDrag(dragging: Bool, placingOurselves: Bool) -> Bool {
        dragging && !placingOurselves
    }
}
