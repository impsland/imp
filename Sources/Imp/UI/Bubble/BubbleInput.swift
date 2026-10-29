import AppKit
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
        VStack(alignment: .leading, spacing: 6) {
            if let picture = bubble.attachment, let image = NSImage(data: picture.data) {
                AttachmentChip(image: image) { model.removeAttachment() }
                    .padding(.leading, 6).padding(.top, 2)
            }
            field(empty: empty || busy)
        }
        .padding(chat ? 5 : 0)
        .background {
            if chat {
                RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.primary.opacity(0.07))
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(focused ? tint.opacity(0.6) : Color.primary.opacity(0.1), lineWidth: focused ? 1.5 : 1)
            }
        }
        .onAppear { if !measuring { installPasteMonitor() } }
        .onDisappear { removePasteMonitor() }
    }

    private func field(empty: Bool) -> some View {
        HStack(alignment: .bottom, spacing: 2) {
            // Measured with what's typed (`bubble.text`), so the bubble is as tall as the lines in it.
            TextField(chat ? "Message \(model.profile.name)…" : bubble.prompt ?? "Ask Imp anything…",
                      text: measuring ? .constant(bubble.text) : $text, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .lineLimit(1...6)
                // Room above the first line's capitals and below the last line's descenders.
                .padding(.vertical, 2)
                .frame(minHeight: 26)
                .padding(.leading, 6)
                .focused($focused)
                .onKeyPress(.return, phases: .down) { press in
                    guard press.modifiers.contains(.shift) else { send(); return .handled }
                    // A new line at the caret (not at the end), which the field keeps in view.
                    NSApp.sendAction(#selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)), to: nil, from: nil)
                    return .handled
                }
                .onChange(of: text) { _, now in if !chat && !measuring { model.typingChanged(now) } }
                .onExitCommand { model.dismissBubble() }
            if !chat { IconButton(icon: "mic", help: "Talk instead") { model.talk() } }
            Button(action: send) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(empty ? AnyShapeStyle(Color.secondary.opacity(0.35)) : AnyShapeStyle(tint.gradient)))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(empty)
            .help(busy ? "\(model.profile.name) is still answering" : "Send (↩)")
            .animation(.easeOut(duration: 0.15), value: empty)
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
    private var busy: Bool { chat && model.work != nil }

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
            guard focused, event.keyCode == 9 /* V */, mods == .command || mods == .control else { return event }
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
            .frame(width: 56, height: 56)
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Color.primary.opacity(0.12)))
            .overlay(alignment: .topTrailing) {
                Button(action: remove) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 15))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, Color.black.opacity(0.6))
                }
                .buttonStyle(.plain)
                .help("Remove the picture")
                .offset(x: 6, y: -6)
                .opacity(hover ? 1 : 0.85)
            }
            .onHover { hover = $0 }
            .help("Sent with your message")
            .accessibilityLabel("Attached picture")
            .accessibilityAction(named: "Remove", remove)
    }
}

/// Live transcript with a little level meter that follows your voice.
struct ListeningRow: View {
    let model: ImpModel
    let transcript: String
    var measuring = false

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            LevelMeter(level: measuring ? 0.4 : model.micLevel)
            Text(transcript.isEmpty ? "Listening…" : transcript)
                .font(.system(size: 14))
                .foregroundStyle(transcript.isEmpty ? .secondary : .primary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            IconButton(icon: "keyboard", help: "Type instead") { model.startTyping() }
        }
    }
}

struct LevelMeter: View {
    @Environment(\.impTint) private var tint
    let level: Double

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 2.5) {
                ForEach(0..<4, id: \.self) { i in
                    let wobble = 0.5 + 0.5 * sin(t * 9 + Double(i) * 1.3)
                    Capsule()
                        .fill(tint.gradient)
                        .frame(width: 3, height: 5 + 13 * min(1, level * 1.4) * (0.45 + 0.55 * wobble))
                }
            }
            .frame(width: 22, height: 20)
        }
    }
}
