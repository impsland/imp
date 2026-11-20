import AppKit
import ImpDesign
import ImpKit
import SwiftUI

/// Type to Imp: ↩ sends, ⇧↩ new line, ⎋ closes. ⌘V (or ⌃V) pastes text, or attaches a copied
/// picture to send along. In the chat (`chat`) it sits in a well under the transcript, and waits
/// while the Imp is still answering.
struct TypingField: View {
    @Environment(\.impTint) private var tint
    let model: ImpModel
    let bubble: Bubble
    var measuring = false
    var chat = false
    @State private var text = ""
    @State private var pasteMonitor: Any?
    @FocusState private var focused: Bool

    var body: some View {
        let empty = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && bubble.attachment == nil
        VStack(alignment: .leading, spacing: Spacing.snug) {
            if let picture = bubble.attachment, let image = NSImage(data: picture.data) {
                AttachmentChip(image: image) { model.removeAttachment() }
                    .padding(.leading, Spacing.snug).padding(.top, Spacing.hairline)
            }
            field(empty: empty || busy)
        }
        .padding(chat ? Spacing.snug : 0)
        .background {
            if chat {
                let shape = RoundedRectangle(cornerRadius: Radius.medium, style: .continuous)
                shape.fill(Tone.well).focusRing(shape, shown: focused)
            }
        }
        .onAppear { if !measuring { installPasteMonitor() } }
        .onDisappear { removePasteMonitor() }
    }

    private func field(empty: Bool) -> some View {
        HStack(alignment: .bottom, spacing: Spacing.hairline) {
            // Measured with what's typed (`bubble.text`), so the bubble is as tall as the lines in it.
            TextField(asleep ? String(localized: "\(model.profile.name) is asleep")
                      : chat ? String(localized: "Message \(model.profile.name)…") : bubble.prompt ?? String(localized: "Ask Imp anything…"),
                      text: measuring ? .constant(bubble.text) : $text, axis: .vertical)
                .textFieldStyle(.plain)
                .font(Typeface.body)
                .lineLimit(1...model.prefs.inputMaxLines)
                // Room above the first line's capitals and below the last line's descenders.
                .padding(.vertical, Spacing.hairline)
                .frame(minHeight: BubbleMetrics.send)
                .padding(.leading, Spacing.snug)
                .focused($focused)
                .onKeyPress(.return, phases: .down) { press in
                    guard press.modifiers.contains(.shift) else { send(); return .handled }
                    // A new line at the caret (not at the end), which the field keeps in view.
                    NSApp.sendAction(#selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)), to: nil, from: nil)
                    return .handled
                }
                .onChange(of: text) { _, now in if !chat && !measuring { model.typingChanged(now) } }
                .onExitCommand { model.dismissBubble() }
                .disabled(asleep)
            if !chat && model.visit == nil { IconButton(icon: "mic", help: "Talk instead") { model.talk() } }
            Button(action: send) {
                Image(systemName: "arrow.up")
                    .font(Typeface.label.weight(.bold))
                    .foregroundStyle(empty ? AnyShapeStyle(Tone.faint) : AnyShapeStyle(OnTint(tint)))
                    .frame(width: BubbleMetrics.send, height: BubbleMetrics.send)
                    .background(Circle().fill(empty ? AnyShapeStyle(Tone.card) : AnyShapeStyle(TintFill(tint))))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(empty)
            .help(asleep ? "\(model.profile.name) is asleep" : busy ? "\(model.profile.name) is still answering" : "Send (↩)")
            .impAnimation(ImpDesign.Motion.hover, value: empty)
        }
        .task(id: bubble.id) {
            guard !measuring else { return }
            text = bubble.text
            try? await Task.sleep(for: .milliseconds(80))
            focused = true
        }
    }

    /// In the chat, a new message waits until the answer to the last one is in (sending would
    /// stop it).
    private var busy: Bool { chat && model.work != nil || asleep }

    /// An Imp that can't think (no usable brain, or its home is away) can't be asked anything.
    private var asleep: Bool { !model.wakefulness.isAwake }

    private func send() {
        guard !busy else { return }
        let t = text
        text = ""
        model.submitTyped(t)
    }

    /// ⌘V and ⌃V while typing here: a copied picture becomes the attachment. Text is pasted at the
    /// cursor (⌃V too, which macOS would otherwise treat as "page down"). By key code, so it works
    /// with any keyboard layout.
    private func installPasteMonitor() {
        guard pasteMonitor == nil else { return }
        pasteMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let mods = event.modifierFlags.intersection([.command, .control, .option])
            guard focused, model.visit == nil, event.keyCode == 9 /* V */, mods == .command || mods == .control else { return event }
            if let picture = Pasteboard.picture() {
                model.attach(picture)
            } else {
                NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: nil)
            }
            return nil
        }
    }

    private func removePasteMonitor() {
        if let pasteMonitor { NSEvent.removeMonitor(pasteMonitor) }
        pasteMonitor = nil
    }
}

/// A picture waiting to be sent with the message, with a way to take it back.
struct AttachmentChip: View {
    let image: NSImage
    let remove: () -> Void
    @State private var hover = false

    var body: some View {
        Image(nsImage: image)
            .resizable()
            .aspectRatio(contentMode: .fill)
            .frame(width: BubbleMetrics.thumb, height: BubbleMetrics.thumb)
            .clipShape(RoundedRectangle(cornerRadius: Radius.tile, style: .continuous))
            .overlay(alignment: .topTrailing) {
                Button(action: remove) {
                    Image(systemName: "xmark.circle.fill")
                        .font(Typeface.body)
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(Tone.paper, Tone.scrim)
                }
                .buttonStyle(.plain)
                .help("Remove the picture")
                .offset(x: Spacing.snug, y: -Spacing.snug)
                .opacity(hover ? 1 : Opacity.hoverFill)
            }
            .onHover { hover = $0 }
            .help("Sent with your message")
            .accessibilityLabel("Attached picture")
            .accessibilityAction(named: Text("common.remove"), remove)
    }
}

/// Live transcript with a little level meter that follows your voice.
struct ListeningRow: View {
    let model: ImpModel
    let transcript: String
    var measuring = false

    var body: some View {
        HStack(alignment: .center, spacing: Spacing.cozy) {
            LevelMeter(level: measuring ? 0.4 : model.micLevel, active: !measuring)
            Text(transcript.isEmpty ? String(localized: "Listening…") : transcript)
                .font(Typeface.body)
                .foregroundStyle(transcript.isEmpty ? Tone.muted : Tone.text)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            IconButton(icon: "message.fill", help: "menu.imp.message") { model.startTyping() }
        }
    }
}

struct LevelMeter: View {
    @Environment(\.impTint) private var tint
    let level: Double
    /// False while the bubble is only being measured. The bars also rest while nothing is heard.
    var active = true

    var body: some View {
        TimelineView(.animation(minimumInterval: Energy.shared.interval(fps: 30), paused: !active || level < 0.01)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: Spacing.hairline) {
                ForEach(0..<4, id: \.self) { i in
                    let wobble = 0.5 + 0.5 * sin(t * 9 + Double(i) * 1.3)
                    Capsule()
                        .fill(tint)
                        .frame(width: BubbleMetrics.bar, height: BubbleMetrics.dot + 13 * min(1, level * 1.4) * (0.45 + 0.55 * wobble))
                }
            }
            .frame(width: BubbleMetrics.meterWidth, height: BubbleMetrics.corner)
        }
    }
}
