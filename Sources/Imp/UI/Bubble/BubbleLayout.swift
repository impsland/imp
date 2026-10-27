import AppKit
import ImpKit
import SwiftUI

/// How the bubble is laid out right now (decided by the panel controller, which measures it).
@MainActor @Observable
final class BubbleLayout {
    var tailX: CGFloat = 0
    /// Reply text taller than this is cut short (collapsed, fading out) or scrolls (expanded).
    /// `nil` shows it all.
    var textLimit: CGFloat?
    /// The user chose to read a long reply in full: a wider card with scrolling text.
    var expanded = false
    /// The user dragged the bubble away from Imp: it stays put and loses its trailing dots.
    var detached = false
    /// Reading mode, resized by the user (dragging the card's edges).
    var customWidth: CGFloat?
    var customTextHeight: CGFloat?
    /// The answer's steps are listed ("3 steps"), and these are opened to show request and response.
    /// Here, not in the view, so measuring sees them and the panel grows to fit.
    var showSteps = false
    var openSteps: Set<UUID> = []
    /// History pages shown (see `ChatView.page`): more as you ask for earlier turns.
    var chatPages = 1
    /// Where pictures and videos sit in the reply text (reported by a measuring probe).
    @ObservationIgnored var mediaSpans: [ReadAllCut.Span] = []
    /// The user is dragging the card's edges or a corner (`true` when they let go).
    @ObservationIgnored var onResize: ((_ edges: Edge.Set, _ ended: Bool) -> Void)?
    /// Where the ✕ goes, so it's always on screen (decided after the bubble is placed).
    var closeCorner = CloseCorner.outsideTrailing

    enum CloseCorner { case outsideTrailing, outsideLeading, inside }
    /// Asks the panel controller to lay the bubble out again (after "Read all" / "Show less").
    @ObservationIgnored var onToggle: (() -> Void)?
    /// The user is dragging the card (`true` when they let go). The panel controller moves it.
    @ObservationIgnored var onDrag: ((_ ended: Bool) -> Void)?

    var width: CGFloat { customWidth ?? (expanded ? BubbleView.readingWidth : BubbleView.width) }

    func copy() -> BubbleLayout {
        let c = BubbleLayout()
        c.tailX = tailX; c.textLimit = textLimit; c.expanded = expanded; c.detached = detached; c.closeCorner = closeCorner
        c.customWidth = customWidth; c.customTextHeight = customTextHeight
        c.showSteps = showSteps; c.openSteps = openSteps; c.chatPages = chatPages
        c.mediaSpans = mediaSpans
        return c
    }
}
