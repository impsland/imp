import AppKit
import ImpDesign
import ImpKit
import SwiftUI

/// The message box for Imp: ↩ sends, ⇧↩ new line, ⎋ closes. ⌘V (or ⌃V) pastes text, or attaches a copied
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
    @State private var recorder = SoundRecorder()
    @State private var recording = false
    @State private var dropping = false
    @FocusState private var focused: Bool

    var body: some View {
        let empty = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && bubble.attachments.isEmpty
        VStack(alignment: .leading, spacing: Spacing.snug) {
            if !bubble.attachments.isEmpty {
                HStack(spacing: Spacing.snug) {
                    ForEach(bubble.attachments) { file in
                        MediaChip(file: file) { model.removeAttachment(file.id) }
                    }
                }
                .padding(.leading, Spacing.snug).padding(.top, Spacing.snug)
            }
            if let note = bubble.attachmentNote {
                Text(note).font(Typeface.small).foregroundStyle(Tone.muted).padding(.leading, Spacing.snug)
            }
            field(empty: empty || busy)
                .opacity(recording ? 0 : 1)
                .overlay { if recording { RecordingRow(recorder: recorder, done: finishRecording, cancel: cancelRecording) } }
        }
        .padding(chat ? Spacing.snug : 0)
        .background {
            if chat {
                let shape = RoundedRectangle(cornerRadius: Radius.medium, style: .continuous)
                shape.fill(Tone.well).focusRing(shape, shown: focused)
            }
        }
        .overlay { if dropping && !measuring { dropHint } }
        .onDrop(of: [.fileURL], isTargeted: $dropping) { providers in drop(providers) }
        .onChange(of: recorder.timedOut) { _, out in if out { finishRecording() } }
        .onAppear { if !measuring { installPasteMonitor() } }
        .onDisappear {
            removePasteMonitor()
            if recording { recorder.cancel() }
        }
    }

    /// Files dragged over the box: it fills with the Imp's colour, where they will land.
    private var dropHint: some View {
        RoundedRectangle(cornerRadius: Radius.medium, style: .continuous)
            .fill(tint.opacity(Opacity.tintFill))
            .allowsHitTesting(false)
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
            if !measuring { addMenu }
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

    /// The + beside the mic: a file from disk, a sound recorded here, or a photo from the Mac's camera.
    private var addMenu: some View {
        Menu {
            Button("Choose a file…", systemImage: "doc.badge.plus") { chooseFiles() }
            Button("Record a sound", systemImage: "waveform") { startRecording() }
            Button("Take a photo", systemImage: "camera") { MacCamera.present { model.attach($0) } }
        } label: {
            Image(systemName: "plus")
                .font(.icon(.medium))
                .foregroundStyle(Tone.muted)
                .frame(width: BubbleMetrics.send, height: BubbleMetrics.send)
                .contentShape(Circle())
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
        .fixedSize()
        // The box goes on the menu as well as on its label, so the + sits centred on the same line as the mic and the
        // send button.
        .frame(width: BubbleMetrics.send, height: BubbleMetrics.send)
        .contentShape(Rectangle())
        .disabled(asleep || !MediaFile.canAdd(to: bubble.attachments.count))
        .help(MediaFile.canAdd(to: bubble.attachments.count) ? "Add a photo, sound or video" : "Up to \(MediaFile.maxCount) files go with one message.")
        .accessibilityLabel("Add a photo, sound or video")
    }

    private func chooseFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.image, .audio, .movie, .video]
        panel.message = String(localized: "Choose photos, sounds or videos to send")
        NSApp.activate()
        panel.begin { response in
            guard response == .OK else { return }
            let media = Pasteboard.media(from: panel.urls)
            model.receive(media.files, problem: media.problem)
        }
    }

    private func startRecording() {
        Task {
            do {
                try await recorder.start()
                recording = true
            } catch SoundRecorder.Problem.denied {
                model.noteAttachment(String(localized: "Imp can't hear you. Allow the microphone in System Settings."))
            } catch {
                model.noteAttachment(String(localized: "The recording didn't start."))
            }
        }
    }

    private func finishRecording() {
        guard recording else { return }
        recording = false
        if let sound = recorder.finish(name: "sound") { model.attach(sound) }
    }

    private func cancelRecording() {
        recording = false
        recorder.cancel()
    }

    /// Files dropped on the text box.
    private func drop(_ providers: [NSItemProvider]) -> Bool {
        let loads = providers.filter { $0.hasItemConformingToTypeIdentifier("public.file-url") }
        guard !loads.isEmpty else { return false }
        for provider in loads {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in
                    let media = Pasteboard.media(from: [url])
                    model.receive(media.files, problem: media.problem)
                }
            }
        }
        return true
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
            let media = Pasteboard.pastedMedia()
            if !media.isEmpty {
                media.files.forEach { model.attach($0) }
                if let problem = media.problem { model.attachFailed(problem) }
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

/// A photo, sound or video waiting to be sent with the message, with a way to take it back.
struct MediaChip: View {
    let file: MediaFile
    let remove: () -> Void
    @State private var hover = false
    @State private var thumbnail: NSImage?

    var body: some View {
        content
            .clipShape(RoundedRectangle(cornerRadius: Radius.tile, style: .continuous))
            .overlay(alignment: .topTrailing) {
                Button(action: remove) {
                    Image(systemName: "xmark.circle.fill")
                        .font(Typeface.body)
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(Tone.paper, Tone.scrim)
                }
                .buttonStyle(.plain)
                .help("Remove the file")
                .offset(x: Spacing.snug, y: -Spacing.snug)
                .opacity(hover ? 1 : Opacity.hoverFill)
            }
            .onHover { hover = $0 }
            .help("Sent with your message")
            .accessibilityElement(children: .combine)
            .accessibilityLabel(label)
            .accessibilityAction(named: Text("common.remove"), remove)
            .task(id: file.id) { thumbnail = await Self.thumbnail(of: file) }
    }

    @ViewBuilder private var content: some View {
        switch file.kind {
        case .image, .video:
            Group {
                if let thumbnail {
                    Image(nsImage: thumbnail).resizable().aspectRatio(contentMode: .fill)
                } else {
                    Rectangle().fill(Tone.card).overlay { Image(systemName: icon).foregroundStyle(Tone.muted) }
                }
            }
            .frame(width: BubbleMetrics.thumb, height: BubbleMetrics.thumb)
            .overlay {
                if file.kind == .video {
                    Image(systemName: "play.fill")
                        .font(.icon(.medium, weight: .bold))
                        .foregroundStyle(Tone.paper)
                        .frame(width: Sizing.mark, height: Sizing.mark)
                        .background(Circle().fill(Tone.scrim))
                }
            }
        case .audio, .file:
            HStack(spacing: Spacing.snug) {
                Image(systemName: icon).font(.icon(.medium)).foregroundStyle(Tone.muted)
                Text(file.name).font(Typeface.small).foregroundStyle(Tone.text).lineLimit(1).truncationMode(.middle)
            }
            .padding(.horizontal, Spacing.cozy)
            .frame(width: BubbleMetrics.thumb * 2, height: BubbleMetrics.thumb, alignment: .leading)
            .background(Tone.card)
        }
    }

    private var icon: String {
        switch file.kind {
        case .image: "photo"
        case .audio: "waveform"
        case .video: "film"
        case .file: "doc"
        }
    }

    private var label: String {
        switch file.kind {
        case .image: String(localized: "Attached picture")
        case .audio: String(localized: "Attached sound")
        case .video: String(localized: "Attached video")
        case .file: String(localized: "Attached file")
        }
    }

    private static func thumbnail(of file: MediaFile) async -> NSImage? {
        switch file.kind {
        case .image: return NSImage(data: file.data)
        case .video:
            guard let url = file.source, let frame = await VideoStill.frame(of: url) else { return nil }
            return NSImage(cgImage: frame, size: .zero)
        case .audio, .file: return nil
        }
    }
}

/// Recording a sound for the message: the time, a meter that follows the voice, and cancel or done.
struct RecordingRow: View {
    let recorder: SoundRecorder
    let done: () -> Void
    let cancel: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: Spacing.cozy) {
            LevelMeter(level: recorder.level, active: true)
            Text(SoundRecorder.clock(recorder.elapsed))
                .font(Typeface.body.monospacedDigit())
                .foregroundStyle(Tone.text)
                .frame(maxWidth: .infinity, alignment: .leading)
            IconButton(icon: "xmark", help: "Cancel the recording", action: cancel)
            IconButton(icon: "checkmark", help: "Attach the recording", active: true, action: done)
        }
        .padding(.leading, Spacing.snug)
        .frame(minHeight: BubbleMetrics.send)
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
