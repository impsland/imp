import AppKit
import ImpKit
import SwiftUI

/// The answer: its text, then a quiet footer.
struct ResultView: View {
    @Environment(\.impTint) private var tint
    let bubble: Bubble
    let model: ImpModel
    let layout: BubbleLayout
    var measuring = false
    /// Footer buttons are small: the answer is the point.
    static let button: CGFloat = 22

    var body: some View {
        if !bubble.text.isEmpty {
            let blocks = Markdown.blocks(bubble.text)
            let voice = VoiceReply.style(bubble, prefs: model.prefs) != nil
            let reply = MarkdownView(blocks: blocks, base: Workspace.directory(for: model.id),
                                     onImageLoad: measuring ? nil : { layout.onToggle?() },
                                     onMedia: measuring ? { layout.mediaSpans = $0 } : nil,
                                     mediaOwner: bubble.id.uuidString, autoplay: model.prefs.autoplaysMedia,
                                     voice: voice, measuring: measuring)
            if voice && Markdown.isOnlyVoice(blocks) {
                // Nothing but a voice: the puff of smoke is the answer, in the middle of the card.
                VoiceOrb(look: VoiceLook(hue: model.profile.hue), owner: bubble.id.uuidString, size: 56, measuring: measuring)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background { reply }
            } else {
                answer(reply)
            }
        }
        if layout.expanded && layout.showSteps { StepList(steps: bubble.steps, layout: layout, animated: false) }
        if Self.hasFooter(bubble, layout) { footer }
    }

    @ViewBuilder private func answer(_ reply: MarkdownView) -> some View {
        let text = reply
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
        if let limit = layout.textLimit {
            if layout.expanded {
                ReadingScroll(height: limit) { text.padding(.trailing, 10).padding(.bottom, 14) }
            } else if layout.mediaSpans.contains(where: { abs($0.bottom - limit) < 1 }) {
                // Cut right below a picture: the picture shows whole, "Read all" waits under it.
                VStack(spacing: 6) {
                    reply
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .frame(height: limit, alignment: .top)
                        .clipped()
                    readAll
                }
            } else {
                // A long reply, cut short: it fades out, with a way to read the rest.
                // (Not selectable here, so the text doesn't fight "Read all" for the cursor.)
                reply
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(height: limit, alignment: .top)
                    .clipped()
                    .mask(LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black, location: 0.7),
                                                 .init(color: .clear, location: 1)], startPoint: .top, endPoint: .bottom))
                    .overlay(alignment: .bottom) { readAll }
            }
        } else {
            text
        }
    }

    private var readAll: some View {
        Button { toggle() } label: {
            Label("Read all", systemImage: "chevron.down")
                .font(.system(size: 11, weight: .semibold))
                .padding(.horizontal, 10).padding(.vertical, 4)
                .background(Capsule().fill(Color(nsColor: .controlBackgroundColor)))
                .overlay(Capsule().strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.12), radius: 4, y: 1)
        }
        .buttonStyle(.plain)
        .foregroundStyle(tint)
        .help("Show the whole reply")
    }

    private func toggle() {
        withAnimation(.snappy(duration: 0.2)) { layout.expanded.toggle() }
        if !layout.expanded { layout.customWidth = nil; layout.customTextHeight = nil; layout.showSteps = false }
        if layout.expanded { model.keepBubble() }           // reading it in full: it waits for you
        layout.onToggle?()
    }

    /// Only for what belongs to the answer itself: "Show less", a setup link, and (read in full)
    /// its steps. A finished answer stays as small as it can, so pictures get the room: the tools
    /// it used show in the full view and in the chat. Reply, copy and close sit on the card's corners.
    static func hasFooter(_ bubble: Bubble, _ layout: BubbleLayout) -> Bool {
        !bubble.isStreaming && (layout.expanded || bubble.link != nil)
    }

    private var footer: some View {
        HStack(spacing: 2) {
            if layout.expanded {
                IconButton(icon: "chevron.up", help: "Show less", size: Self.button) { toggle() }
            }
            if layout.expanded && !bubble.steps.isEmpty {
                // Re-measured, so the panel grows with the list (instead of cutting the card off).
                // A count, not a step's title: a command line would never fit in a pill.
                Button { layout.showSteps.toggle(); layout.onToggle?() } label: {
                    Label(bubble.steps.count == 1 ? "1 step" : "\(bubble.steps.count) steps",
                          systemImage: layout.showSteps ? "chevron.down" : "hammer")
                }
                .modifier(FooterPill())
                .fixedSize()
                .help(layout.showSteps ? "Hide what Imp did" : "What Imp did")
            }
            Spacer(minLength: 6)
            if let link = bubble.link {
                Button(link.title) { model.perform(link) }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(tint)
                    .padding(.trailing, 4)
            }
        }
    }
}

/// The footer's small capsule buttons: one line, one size.
struct FooterPill: ViewModifier {
    func body(content: Content) -> some View {
        content
            .buttonStyle(.plain)
            .labelStyle(.titleAndIcon)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.tail)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(Capsule().fill(Color.primary.opacity(0.07)))
    }
}

/// Errors and hints: an icon, the message, and the one thing to do about it.
struct NoticeView: View {
    @Environment(\.impTint) private var tint
    let bubble: Bubble
    let model: ImpModel

    var body: some View {
        let error = bubble.phase == .error
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: error ? "exclamationmark.triangle.fill" : "lightbulb.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(error ? Color.orange : tint)
                .frame(width: 26, height: 26)
                .background(Circle().fill((error ? Color.orange : tint).opacity(0.14)))
            VStack(alignment: .leading, spacing: 8) {
                if !bubble.title.isEmpty {
                    Text(bubble.title).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary).lineLimit(1)
                }
                Text(bubble.text)
                    .font(.system(size: 13))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                if let link = bubble.link {
                    Button { model.perform(link) } label: {
                        Text(link.title)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 12).padding(.vertical, 5)
                            .background(Capsule().fill(tint.gradient))
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
