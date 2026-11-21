import AVFoundation
import ImpDesign
import ImpKit
import Photos
import SwiftUI
import UIKit

/// The playful camera: the Imps rush in from the edges and peek over the picture, you drag them where you like, and
/// the photo is what the screen showed, Imps included. `onSend` gets the JPEG. Without it the preview has no Send.
struct CameraView: View {
    /// The Imps on the screen (or the chat's own).
    let imps: [LinkImp]
    var onSend: ((Data) -> Void)?
    var close: () -> Void

    @State private var camera = CameraSession()
    @State private var frames: [UUID: CGRect] = [:]
    @State private var moods: [UUID: Mood] = [:]
    @State private var dragStart: [UUID: CGRect] = [:]
    @State private var leans: [UUID: Double] = [:]
    @State private var laidOut: CGSize?
    @State private var flash = false
    @State private var taking = false
    @State private var shot: Data?
    @State private var saved = false
    @State private var saveFailed = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.openURL) private var openURL

    private var side: (CGSize) -> CGFloat { { $0.width * CameraGeometry.impShare } }

    var body: some View {
        GeometryReader { box in
            let size = box.size
            ZStack {
                Tone.ink
                if camera.state == .running { CameraPreview(session: camera.session) }
                if camera.state == .denied || camera.state == .unavailable { unavailable }
                if camera.state == .running { friends(size) }
                Tone.paper.opacity(flash ? Opacity.hoverFill : 0).allowsHitTesting(false)
                if let shot, let image = UIImage(data: shot) {
                    previewCard(image)
                } else if camera.state == .running {
                    controls(size)
                }
                if camera.state != .running { closeButton.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading) }
            }
            .onAppear { place(size) }
            .onChange(of: size) { _, new in place(new) }
        }
        .ignoresSafeArea()
        .statusBarHidden()
        .task { await camera.start() }
        .onDisappear { camera.stop() }
    }

    // MARK: Imps

    private func friends(_ size: CGSize) -> some View {
        let s = side(size)
        return ZStack {
            ForEach(imps, id: \.id) { imp in
                if let frame = frames[imp.id] {
                    LiveImp(imp: imp, mood: moods[imp.id] ?? .curious)
                        .frame(width: s, height: s)
                        .rotationEffect(.degrees(leans[imp.id] ?? 0))
                        .position(x: frame.midX, y: frame.midY)
                        .gesture(drag(imp.id, size))
                        .onTapGesture { cheer(imp.id) }
                        .allowsHitTesting(shot == nil)
                        .accessibilityIdentifier("camera.imp")
                }
            }
        }
        .frame(width: size.width, height: size.height)
    }

    private func drag(_ id: UUID, _ size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 6)
            .onChanged { value in
                let start = dragStart[id] ?? frames[id] ?? .zero
                dragStart[id] = start
                frames[id] = CameraGeometry.clamped(start.offsetBy(dx: value.translation.width, dy: value.translation.height), in: size)
                leans[id] = max(-14, min(14, Double(value.velocity.width) / 80))
                if moods[id] != .excited { moods[id] = .excited }
            }
            .onEnded { _ in
                dragStart[id] = nil
                withImpAnimation(ImpDesign.Motion.pop, reduceMotion: reduceMotion) { leans[id] = 0 }
                moods[id] = .curious
            }
    }

    private func cheer(_ id: UUID) {
        Haptics.tap(.soft)
        moods[id] = .happy
        Task {
            try? await Task.sleep(for: .seconds(1))
            if moods[id] == .happy { moods[id] = shot == nil ? .curious : .happy }
        }
    }

    /// The Imps spring in from outside the screen to their peeking spots, one after another.
    private func place(_ size: CGSize) {
        guard size.width > 0, laidOut != size else { return }
        let first = laidOut == nil
        laidOut = size
        let s = side(size)
        let spots = CameraGeometry.spots(count: imps.count, in: size, side: s)
        if !first {
            for (imp, spot) in zip(imps, spots) { frames[imp.id] = spot }
            return
        }
        for (imp, spot) in zip(imps, spots) {
            frames[imp.id] = CameraGeometry.start(for: spot, in: size)
            moods[imp.id] = .curious
        }
        if reduceMotion {
            for (imp, spot) in zip(imps, spots) { frames[imp.id] = spot }
            return
        }
        for (i, (imp, spot)) in zip(imps, spots).enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15 + Double(i) * 0.14) {
                guard frames[imp.id] != nil else { return }
                withImpAnimation(ImpDesign.Motion.pop, reduceMotion: reduceMotion) { frames[imp.id] = spot }
            }
        }
    }

    // MARK: Controls

    private var closeButton: some View {
        Button(action: close) {
            Image(systemName: "xmark").font(.icon(.big, weight: .bold)).foregroundStyle(Tone.paper)
                .frame(width: Sizing.hit, height: Sizing.hit)
                .background(Circle().fill(Tone.scrim))
        }
        .padding(.leading, Spacing.roomy).padding(.top, Sizing.cameraTop)
        .accessibilityLabel("Close")
        .accessibilityIdentifier("camera.close")
    }

    private func controls(_ size: CGSize) -> some View {
        ZStack {
            HStack {
                closeButton
                Spacer()
                if camera.canFlip {
                    Button { camera.flip() } label: {
                        Image(systemName: "arrow.triangle.2.circlepath.camera").font(.icon(.big, weight: .bold)).foregroundStyle(Tone.paper)
                            .frame(width: Sizing.hit, height: Sizing.hit)
                            .background(Circle().fill(Tone.scrim))
                    }
                    .padding(.trailing, Spacing.roomy).padding(.top, Sizing.cameraTop)
                    .accessibilityLabel("Flip the camera")
                    .accessibilityIdentifier("camera.flip")
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
            ShutterButton { Task { await shoot(size) } }
                .disabled(taking)
                .padding(.bottom, Sizing.cameraBottom)
                .frame(maxHeight: .infinity, alignment: .bottom)
                .accessibilityIdentifier("camera.shutter")
        }
    }

    private var unavailable: some View {
        VStack(spacing: Spacing.roomy) {
            Image(systemName: "camera.fill").font(.icon(.huge)).foregroundStyle(Tone.paper.opacity(Opacity.dimmed))
            Text(camera.state == .denied ? "Imp needs the camera to take photos. You can allow it in Settings." : "This device has no camera to use.")
                .font(Typeface.body).foregroundStyle(Tone.paper).multilineTextAlignment(.center)
            if camera.state == .denied {
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                }
                .buttonStyle(.primary)
                .accessibilityIdentifier("camera.settings")
            }
        }
        .padding(Spacing.huge)
    }

    // MARK: Shot

    private func shoot(_ size: CGSize) async {
        guard !taking else { return }
        taking = true
        defer { taking = false }
        Haptics.tap(.light)
        withImpAnimation(ImpDesign.Motion.quick, reduceMotion: reduceMotion) { flash = true }
        let photo = await camera.capture()
        withImpAnimation(ImpDesign.Motion.fade, reduceMotion: reduceMotion) { flash = false }
        guard let photo, let data = compose(photo, view: size) else { Haptics.notify(.error); return }
        for imp in imps { moods[imp.id] = .happy }
        Haptics.notify(.success)
        saved = false
        saveFailed = false
        shot = data
    }

    /// The photo cut to what the screen showed, with each Imp's still drawn where it was.
    private func compose(_ photo: CGImage, view: CGSize) -> Data? {
        let crop = CameraGeometry.fillCrop(photo: CGSize(width: photo.width, height: photo.height), view: view).integral
        guard let cut = photo.cropping(to: crop) else { return nil }
        let pixels = CGSize(width: cut.width, height: cut.height)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let image = UIGraphicsImageRenderer(size: pixels, format: format).image { _ in
            UIImage(cgImage: cut).draw(in: CGRect(origin: .zero, size: pixels))
            let s = side(view)
            for imp in imps {
                guard let frame = frames[imp.id] else { continue }
                let renderer = ImageRenderer(content: ImpFigure(imp: imp, mood: moods[imp.id] ?? .curious, date: .now, breathes: false)
                    .frame(width: s, height: s))
                renderer.scale = 3
                renderer.isOpaque = false
                renderer.uiImage?.draw(in: CameraGeometry.croppedFrame(frame, view: view, cropped: pixels))
            }
        }
        guard let cg = image.cgImage, let encoded = EncodedImage.encode(cg, maxPixel: 2048) else { return nil }
        return encoded.data
    }

    private func previewCard(_ image: UIImage) -> some View {
        ZStack {
            Tone.ink
            VStack(spacing: Spacing.roomy) {
                Image(uiImage: image).resizable().scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: Radius.large))
                    .padding(.horizontal, Spacing.snug)
                    .padding(.top, Sizing.cameraTop)
                HStack(spacing: Spacing.roomy) {
                    pill("Retake", "arrow.counterclockwise", id: "camera.retake") {
                        withImpAnimation(ImpDesign.Motion.quick, reduceMotion: reduceMotion) { shot = nil }
                        for imp in imps { moods[imp.id] = .curious }
                    }
                    pill(saved ? "Saved" : "Save", saved ? "checkmark" : "square.and.arrow.down", id: "camera.save") { save() }
                    if let onSend, let shot {
                        pill("Send", "paperplane.fill", id: "camera.send", prominent: true) { onSend(shot) }
                    }
                }
                .padding(.bottom, Sizing.cameraBottom)
                if saveFailed {
                    Text("Allow adding photos in Settings to save.").font(Typeface.caption).foregroundStyle(Tone.paper)
                }
            }
        }
        .transition(.opacity)
    }

    private func pill(_ title: LocalizedStringKey, _ icon: String, id: String, prominent: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon).font(Typeface.label)
                .foregroundStyle(prominent ? Tone.ink : Tone.paper)
                .padding(.horizontal, Spacing.roomy).padding(.vertical, Spacing.medium)
                .background(Capsule().fill(prominent ? Tone.paper : Tone.paper.opacity(Opacity.tintFill)))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(id)
    }

    private func save() {
        guard let shot, !saved else { return }
        Task {
            let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            guard status == .authorized || status == .limited else { saveFailed = true; return }
            do {
                try await PHPhotoLibrary.shared().performChanges {
                    PHAssetCreationRequest.forAsset().addResource(with: .photo, data: shot, options: nil)
                }
                saved = true
                Haptics.notify(.success)
            } catch { saveFailed = true }
        }
    }
}

/// An AVCaptureVideoPreviewLayer that fills its view (aspect fill), as the photo is cropped to.
private struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    final class Host: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var preview: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }
    func makeUIView(context: Context) -> Host {
        let host = Host()
        host.preview.session = session
        host.preview.videoGravity = .resizeAspectFill
        return host
    }
    func updateUIView(_ host: Host, context: Context) {}
}
