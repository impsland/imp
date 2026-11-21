import AppKit
import ImpKit
import SwiftUI
import ImpDesign

/// How the bubble is laid out right now (decided by the panel controller, which measures it).
@MainActor @Observable
final class BubbleLayout {
    var tailX: CGFloat = 0
    /// Reply text taller than this is cut short (collapsed) or scrolls (expanded).
    /// `nil` shows it all.
    var textLimit: CGFloat?
    /// The user chose to read a long reply in full: a wider card with scrolling text.
    var expanded = false
    /// The user dragged the bubble away from Imp: it stays put and loses its trailing dots.
    var detached = false
    /// Reading mode, resized by the user (dragging the card's edges).
    var customWidth: CGFloat?
    var customTextHeight: CGFloat?
    /// The full bubble (the chat): the card's size. The user resizes it, and it is saved in settings.
    var chatSize = BubbleSizing.defaultSize
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
        c.chatSize = chatSize
        c.customWidth = customWidth; c.customTextHeight = customTextHeight
        c.showSteps = showSteps; c.openSteps = openSteps; c.chatPages = chatPages
        c.mediaSpans = mediaSpans
        return c
    }
}

/// The bubble's drawn geometry: the Mac-only card, its corner buttons, player and meters. The
/// bubble is not a screen of rows, so these are its own named sizes.
enum BubbleMetrics {
    /// A one-point anchor or probe view.
    static let anchor: CGFloat = 1
    /// A thin rule beside quoted text and a bar of the level meter.
    static let rule: CGFloat = 2
    static let bar: CGFloat = 3
    /// A small status dot and the dots of the working indicator.
    static let pip: CGFloat = 5
    static let dot: CGFloat = 7
    static let pipRow: CGFloat = 12
    /// The round buttons along the bubble's edges.
    static let corner: CGFloat = 20
    static let button: CGFloat = 24
    static let send: CGFloat = 26
    /// A step's icon and the resize mark.
    static let step: CGFloat = 18
    static let grip: CGFloat = 14
    /// The two pebbles trailing toward the Imp.
    static let trailBig: CGFloat = 10
    static let trailSmall: CGFloat = 6
    static let trailHeight: CGFloat = 19
    /// An attached picture's thumbnail.
    static let thumb = Sizing.attachmentChip
    /// The voice level meter.
    static let meterWidth: CGFloat = 22
    /// A list marker's minimum width in the markdown.
    static let marker: CGFloat = 14
    /// The player: its row, play button and scrub knob.
    static let transport: CGFloat = 44
    static let playInner: CGFloat = 34
    static let knob: CGFloat = 9
    /// The quick bar's Imp portrait and minimum width.
    static let portrait: CGFloat = 54
    static let quickBarWidth: CGFloat = 260
}
