import AVFoundation
import ImpDesign
import ImpKit
import Observation
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// The photos, sounds, videos and files waiting in the chat box to go with the next message (at most
/// `MediaFile.maxCount`, each at most 25 MiB). The box shows them as chips; sending hands them to the Imp.
@MainActor
@Observable
final class AttachmentDraft {
    private(set) var files: [MediaFile] = []
    /// Why something could not be added (said once, under the chips).
    var note: String?

    var isEmpty: Bool { files.isEmpty }
    /// How many more fit.
    var remaining: Int { max(0, MediaFile.maxCount - files.count) }

    func clear() { files = []; note = nil }

    func remove(_ id: UUID) {
        files.removeAll { $0.id == id }
        note = nil
    }

    /// Adds one file when there is room.
    func add(_ file: MediaFile) {
        guard MediaFile.canAdd(to: files.count) else { return say(.tooMany) }
        if let problem = MediaFile.check(bytes: file.data.count) { return say(problem) }
        files.append(file)
        note = nil
    }

    func say(_ problem: MediaFile.Problem) {
        note = switch problem {
        case .tooBig: String(localized: "That file is bigger than 25 MB.")
        case .empty: String(localized: "That file is empty.")
        case .unreadable: String(localized: "That file can't be read.")
        case .tooMany: String(localized: "Up to \(MediaFile.maxCount) files go with one message.")
        }
    }

    /// Files chosen in the Files app. Each is copied to a temporary file first, so a video's still stays readable.
    func add(urls: [URL]) {
        for url in urls {
            guard MediaFile.canAdd(to: files.count) else { return say(.tooMany) }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                add(try MediaFile.load(Self.temporaryCopy(of: url)))
            } catch let problem as MediaFile.Problem {
                say(problem)
            } catch {
                say(.unreadable)
            }
        }
    }

    /// Pictures and videos picked from the photo library.
    func add(items: [PhotosPickerItem]) async {
        for item in items {
            guard MediaFile.canAdd(to: files.count) else { return say(.tooMany) }
            if item.supportedContentTypes.contains(where: { $0.conforms(to: .movie) }) {
                do {
                    guard let movie = try await item.loadTransferable(type: PickedMovie.self) else { return say(.unreadable) }
                    add(try MediaFile.load(movie.url))
                } catch let problem as MediaFile.Problem {
                    say(problem)
                } catch {
                    say(.unreadable)
                }
            } else if let data = try? await item.loadTransferable(type: Data.self) {
                addPicture(data: data)
            } else {
                say(.unreadable)
            }
        }
    }

    /// A picture's bytes, scaled to 2048 pixels on the long side.
    func addPicture(data: Data, name: String = "photo") {
        guard let cg = EncodedImage.decode(data), let encoded = EncodedImage.encode(cg, maxPixel: 2048) else { return say(.unreadable) }
        add(MediaFile(encoded, name: name))
    }

    nonisolated static func temporaryCopy(of url: URL) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("attachments-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let copy = folder.appendingPathComponent(url.lastPathComponent)
        try FileManager.default.copyItem(at: url, to: copy)
        return copy
    }
}

/// A video from the photo library, as a file (so it is never held in memory just to be checked).
struct PickedMovie: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { SentTransferredFile($0.url) } importing: { received in
            PickedMovie(url: try AttachmentDraft.temporaryCopy(of: received.file))
        }
    }
}

// MARK: - Chips

/// The files waiting to be sent, one chip each with a way to take it out.
struct AttachmentChips: View {
    let files: [MediaFile]
    let remove: (UUID) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Spacing.cozy) {
                ForEach(files) { file in
                    AttachmentChip(file: file) { remove(file.id) }
                }
            }
            .padding(.vertical, Spacing.tight)
        }
        .scrollClipDisabled()
    }
}

struct AttachmentChip: View {
    let file: MediaFile
    let remove: () -> Void
    @State private var still: UIImage?
    private let side: CGFloat = 64

    var body: some View {
        content
            .overlay(alignment: .topTrailing) {
                Button(action: remove) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 20))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(Tone.onAccent, Tone.accent)
                        .padding(Spacing.hairline)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Remove \(file.name)"))
                .accessibilityIdentifier("chat.chip.remove")
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("chat.chip")
            .task(id: file.id) { await loadStill() }
    }

    @ViewBuilder private var content: some View {
        let shape = RoundedRectangle(cornerRadius: Radius.medium, style: .continuous)
        switch file.kind {
        case .image, .video:
            ZStack {
                Tone.card
                if let still {
                    Image(uiImage: still).resizable().scaledToFill()
                } else {
                    Image(systemName: file.kind == .image ? "photo" : "video").foregroundStyle(Tone.muted)
                }
                if file.kind == .video {
                    Image(systemName: "play.fill")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Tone.paper)
                        .frame(width: 24, height: 24)
                        .background(Circle().fill(Tone.scrim))
                }
            }
            .frame(width: side, height: side)
            .clipShape(shape)
            .accessibilityLabel(Text(file.kind == .image ? "Photo \(file.name)" : "Video \(file.name)"))
        case .audio, .file:
            HStack(spacing: Spacing.tight) {
                Image(systemName: file.kind == .audio ? "waveform" : "doc")
                    .foregroundStyle(Tone.text)
                Text(verbatim: file.name)
                    .font(Typeface.small)
                    .foregroundStyle(Tone.text)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 120)
            }
            .padding(.horizontal, Spacing.cozy)
            .frame(height: side)
            .background(Tone.card, in: shape)
            .accessibilityLabel(Text(file.kind == .audio ? "Sound \(file.name)" : "File \(file.name)"))
        }
    }

    private func loadStill() async {
        switch file.kind {
        case .image: still = UIImage(data: file.data)
        case .video:
            if let url = file.source, let cg = await VideoStill.frame(of: url, maxPixel: 240) { still = UIImage(cgImage: cg) }
        default: break
        }
    }
}

// MARK: - Recording

/// Shown in place of the text box while the microphone records: a red dot, the time, a level meter,
/// cancel and done. (The meter is plain bars that follow the level: no continuous animation.)
struct RecordingRow: View {
    let recorder: SoundRecorder
    let done: () -> Void
    let cancel: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: Spacing.cozy) {
            Circle().fill(Tone.danger).frame(width: Sizing.dot * 2, height: Sizing.dot * 2)
                .accessibilityHidden(true)
            Text(SoundRecorder.clock(recorder.elapsed))
                .font(Typeface.body.monospacedDigit())
                .foregroundStyle(Tone.text)
                .accessibilityIdentifier("chat.recording.time")
            meter
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: cancel) { glyph("xmark", fill: Tone.card, ink: Tone.text) }
                .buttonStyle(.plain)
                .accessibilityLabel("Cancel the recording")
                .accessibilityIdentifier("chat.recording.cancel")
            Button(action: done) { glyph("checkmark", fill: Tone.accent, ink: Tone.onAccent) }
                .buttonStyle(.plain)
                .accessibilityLabel("Attach the recording")
                .accessibilityIdentifier("chat.recording.done")
        }
        .padding(.leading, Spacing.roomy)
        .padding(.trailing, Spacing.tight)
        .frame(minHeight: Sizing.hit)
        .background(Tone.card, in: RoundedRectangle(cornerRadius: Radius.bubble, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chat.recording")
    }

    private var meter: some View {
        let level = min(1, recorder.level * 1.4)
        return HStack(spacing: Spacing.hairline) {
            ForEach(0..<5, id: \.self) { i in
                let shape = [0.6, 0.9, 1.0, 0.8, 0.5][i]
                Capsule().fill(Tone.accent)
                    .frame(width: 3, height: 4 + 16 * level * shape)
            }
        }
        .frame(height: 20)
        .impAnimation(ImpDesign.Motion.quick, value: level)
        .accessibilityHidden(true)
    }

    private func glyph(_ name: String, fill: Color, ink: Color) -> some View {
        Image(systemName: name)
            .font(.icon(.big, weight: .bold))
            .foregroundStyle(ink)
            .frame(width: Sizing.hit - Spacing.cozy, height: Sizing.hit - Spacing.cozy)
            .background(Circle().fill(fill))
    }
}

// MARK: - System camera

/// The system camera, as a sheet. A minimal stand-in for the playful camera: it hands back the picture, upright.
struct SystemCamera: UIViewControllerRepresentable {
    static var isAvailable: Bool { UIImagePickerController.isSourceTypeAvailable(.camera) }

    let picked: (UIImage) -> Void
    let cancelled: () -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: SystemCamera
        init(_ parent: SystemCamera) { self.parent = parent }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let image = info[.originalImage] as? UIImage { parent.picked(image) } else { parent.cancelled() }
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { parent.cancelled() }
    }
}

extension UIImage {
    /// The picture with its orientation applied, as a plain upright bitmap.
    var upright: CGImage? {
        guard imageOrientation != .up else { return cgImage }
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in draw(in: CGRect(origin: .zero, size: size)) }.cgImage
    }
}
