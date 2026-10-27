import AppKit
import ImpKit
import SwiftUI

/// Imp's speech bubble: a frosted glass card with no header. What it shows depends on the
/// phase: a text field, a live transcript, what Imp is working on (with tool steps), or the answer.
struct BubbleView: View {
    static let width: CGFloat = 320
    /// A long reply opened with "Read all".
    static let readingWidth: CGFloat = 440
    /// Transparent room around the card for its shadow and the floating close button. The shadow
    /// must fade out inside it (it reaches about 2 × radius + offset), or the panel's edge cuts it off.
    static let margin: CGFloat = 28

    let model: ImpModel
    let layout: BubbleLayout
    /// When measuring, nothing scrolls or animates, so we learn the natural height.
    var measuring = false

    var body: some View {
        if let bubble = model.bubble {
            BubbleCard(bubble: bubble, model: model, layout: layout, measuring: measuring)
        }
    }
}

struct BubbleCard: View {
    let bubble: Bubble
    let model: ImpModel
    let layout: BubbleLayout
    var measuring = false
    @State private var hover = false

    var body: some View {
        VStack(spacing: 5) {
            card
                // A double-click on a finished answer replies (like the reply button). Not while
                // reading in full: there a double-click selects a word.
                .simultaneousGesture(TapGesture(count: 2).onEnded {
                    if bubble.phase == .result && !bubble.isStreaming && !layout.expanded && !measuring { model.startTyping() }
                })
                .overlay {
                    if layout.expanded && bubble.phase == .result && !measuring {
                        ResizeHandles { edge, ended in layout.onResize?(edge, ended) }
                    }
                }
                .overlay(alignment: layout.closeCorner == .outsideLeading ? .topLeading : .topTrailing) {
                    CloseButton { model.dismissBubble() }
                        .offset(closeOffset)
                        .opacity(closeVisible ? 1 : 0)
                        .animation(.easeOut(duration: 0.15), value: closeVisible)
                }
                // The chat in the other top corner (✕'s mirror); in the chat, the way back.
                .overlay(alignment: layout.closeCorner == .outsideLeading ? .topTrailing : .topLeading) {
                    if bubble.phase == .chat || !model.history.isEmpty || !model.history.chats.isEmpty || model.work != nil {
                        let open = bubble.phase == .chat
                        CornerButton(icon: open ? "chevron.backward" : "bubble.left.and.bubble.right.fill", weight: .bold,
                                     help: open ? "Back to the bubble" : "Chat with \(model.profile.name): everything you said, and keep talking") {
                            open ? model.closeChat() : model.openChat()
                        }
                        .offset(historyOffset)
                        .opacity(closeVisible ? 1 : 0)
                        .animation(.easeOut(duration: 0.15), value: closeVisible)
                    }
                }
                // Reply below the chat button, Copy below ✕: the card holds only the content. (The
                // chat has its own text box.)
                .overlay(alignment: layout.closeCorner == .outsideLeading ? .bottomTrailing : .bottomLeading) {
                    if bubble.phase == .result && !bubble.isStreaming {
                        CornerButton(icon: "arrowshape.turn.up.left.fill", weight: .bold, help: "Reply to \(model.profile.name)") {
                            model.startTyping()
                        }
                        .offset(x: layout.closeCorner == .outsideLeading ? 10 : -10, y: 15)
                        .opacity(closeVisible ? 1 : 0)
                        .animation(.easeOut(duration: 0.15), value: closeVisible)
                    }
                }
                // Copy sits below ✕, on the same side, and shows with it: the answer stays clean.
                .overlay(alignment: layout.closeCorner == .outsideLeading ? .bottomLeading : .bottomTrailing) {
                    if bubble.isCopyable {
                        CopyCornerButton { model.copyBubble() }
                            .offset(x: layout.closeCorner == .outsideLeading ? -10 : 10, y: 15)
                            .opacity(closeVisible ? 1 : 0)
                            .animation(.easeOut(duration: 0.15), value: closeVisible)
                    }
                }
            // The chat is a panel, not a speech bubble: no tail (its room stays, so it doesn't jump).
            Trail(offset: layout.tailX, width: width)
                .opacity(layout.detached || bubble.phase == .chat ? 0 : 1)
        }
        .frame(width: width)
        .padding(BubbleView.margin)
        .environment(\.impTint, Color.imp(model.profile.hue))
        .onHover { inside in
            hover = inside
            inside ? model.pauseAutoHide() : model.scheduleHide()
        }
    }

    /// Always there when you might need a way out: typing, listening, reading in full, or a
    /// bubble you moved. Otherwise it appears on hover.
    private var closeVisible: Bool {
        hover || layout.expanded || layout.detached || [.typing, .listening, .chat].contains(bubble.phase)
    }

    /// The chat reads like a long reply: at reading width.
    private var width: CGFloat { bubble.phase == .chat ? BubbleView.readingWidth : layout.width }

    private var historyOffset: CGSize {
        switch layout.closeCorner {
        case .outsideTrailing: CGSize(width: -10, height: -15)
        case .outsideLeading: CGSize(width: 10, height: -15)
        case .inside: CGSize(width: 8, height: 8)
        }
    }

    private var closeOffset: CGSize {
        switch layout.closeCorner {
        case .outsideTrailing: CGSize(width: 10, height: -15)
        case .outsideLeading: CGSize(width: -10, height: -15)
        case .inside: CGSize(width: -8, height: 8)
        }
    }

    private var card: some View {
        let result = bubble.phase == .result
        return VStack(alignment: .leading, spacing: result ? 4 : 10) {
            switch bubble.phase {
            case .typing:
                TypingField(model: model, bubble: bubble, measuring: measuring)
            case .listening:
                ListeningRow(model: model, transcript: bubble.text, measuring: measuring)
            case .thinking:
                WorkingView(bubble: bubble, layout: layout, measuring: measuring)
            case .result:
                ResultView(bubble: bubble, model: model, layout: layout, measuring: measuring)
            case .error, .hint:
                NoticeView(bubble: bubble, model: model)
            case .chat:
                ChatView(model: model, bubble: bubble, layout: layout, measuring: measuring)
            }
        }
        .padding(.horizontal, bubble.phase == .typing ? 8 : 14)
        .padding(.top, bubble.phase == .typing ? 8 : 12)
        .padding(.bottom, bubble.phase == .typing ? 8 : (result && ResultView.hasFooter(bubble, layout) ? 5 : 12))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            // Grab the card anywhere that isn't text or a button to move it.
            Glass(cornerRadius: 20, tint: bubble.phase == .error ? .red : .imp(model.profile.hue))
                .gesture(DragGesture(minimumDistance: 3, coordinateSpace: .global)
                    .onChanged { _ in layout.onDrag?(false) }
                    .onEnded { _ in layout.onDrag?(true) })
        }
    }
}

// MARK: - Surfaces

extension EnvironmentValues {
    /// The colour of the Imp this bubble belongs to: buttons and accents follow it.
    @Entry var impTint: Color = .imp
}
