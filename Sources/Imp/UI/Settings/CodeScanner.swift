import AVFoundation
import AppKit
import SwiftUI
import Vision

/// Reads another device's Imp code with this Mac's camera: the built-in one, a Continuity Camera
/// iPhone or a USB camera, whichever macOS prefers. Frames are looked at a few times a second with
/// Vision and never kept.
@MainActor @Observable
final class CodeScanner {
    enum State: Equatable {
        case starting
        case scanning
        /// Imp may not use the camera (System Settings › Privacy & Security › Camera).
        case denied
        case noCamera
    }

    private(set) var state = State.starting
    @ObservationIgnored private let feed = CameraFeed()

    var session: AVCaptureSession { feed.session }

    /// Starts the camera. `found` hears the text of each code it sees (each text once).
    func start(found: @escaping @MainActor (String) -> Void) async {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: break
        case .notDetermined:
            guard await AVCaptureDevice.requestAccess(for: .video) else { state = .denied; return }
        default:
            state = .denied
            return
        }
        let started = await feed.start { text in
            Task { @MainActor in found(text) }
        }
        state = started ? .scanning : .noCamera
    }

    func stop() { feed.stop() }

    /// The codes in a picture, such as a screenshot of another device's code.
    nonisolated static func codes(in image: CGImage) -> [String] {
        let request = VNDetectBarcodesRequest()
        request.symbologies = [.qr]
        try? VNImageRequestHandler(cgImage: image).perform([request])
        return (request.results ?? []).compactMap(\.payloadStringValue)
    }

    /// Where to let Imp use the camera.
    static let privacySettings = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera")!
}

/// The capture session and what reads its frames. Only ever touched on its own queue, except for the
/// preview layer that shows the session.
private final class CameraFeed: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "app.imp.Imp.camera")
    private var onCode: (@Sendable (String) -> Void)?
    private var seen: Set<String> = []
    private var lastLook = Date.distantPast

    /// Looks at a frame this often: a code held up to the camera is read well within a second.
    private static let interval: TimeInterval = 0.2

    /// Starts the camera macOS prefers. False when there's none, or it can't be used.
    func start(onCode: @escaping @Sendable (String) -> Void) async -> Bool {
        await withCheckedContinuation { done in
            queue.async { [self] in
                self.onCode = onCode
                seen = []
                guard !session.isRunning else { return done.resume(returning: true) }
                guard let camera = AVCaptureDevice.default(for: .video),
                      let input = try? AVCaptureDeviceInput(device: camera) else { return done.resume(returning: false) }
                let output = AVCaptureVideoDataOutput()
                output.alwaysDiscardsLateVideoFrames = true
                output.setSampleBufferDelegate(self, queue: queue)
                session.beginConfiguration()
                session.sessionPreset = .high
                guard session.canAddInput(input), session.canAddOutput(output) else {
                    session.commitConfiguration()
                    return done.resume(returning: false)
                }
                session.addInput(input)
                session.addOutput(output)
                session.commitConfiguration()
                session.startRunning()
                done.resume(returning: session.isRunning)
            }
        }
    }

    func stop() {
        queue.async { [self] in
            onCode = nil
            session.stopRunning()
            session.beginConfiguration()
            session.inputs.forEach(session.removeInput)
            session.outputs.forEach(session.removeOutput)
            session.commitConfiguration()
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        let now = Date()
        guard let onCode, now.timeIntervalSince(lastLook) >= Self.interval,
              let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        lastLook = now
        let request = VNDetectBarcodesRequest()
        request.symbologies = [.qr]
        try? VNImageRequestHandler(cvPixelBuffer: pixels).perform([request])
        for text in (request.results ?? []).compactMap(\.payloadStringValue) where seen.insert(text).inserted {
            onCode(text)
        }
    }
}

/// What the camera sees, mirrored like a mirror (as people expect of a camera facing them).
struct CameraPreview: NSViewRepresentable {
    let session: AVCaptureSession

    func makeNSView(context: Context) -> PreviewView { PreviewView(session: session) }
    func updateNSView(_ view: PreviewView, context: Context) {}

    final class PreviewView: NSView {
        private let preview: AVCaptureVideoPreviewLayer

        init(session: AVCaptureSession) {
            preview = AVCaptureVideoPreviewLayer(session: session)
            super.init(frame: .zero)
            wantsLayer = true
            preview.videoGravity = .resizeAspectFill
            preview.setAffineTransform(CGAffineTransform(scaleX: -1, y: 1))
            layer?.addSublayer(preview)
        }

        required init?(coder: NSCoder) { nil }

        override func layout() {
            super.layout()
            // Bounds and position, not frame: the layer is flipped.
            preview.bounds = bounds
            preview.position = CGPoint(x: bounds.midX, y: bounds.midY)
        }
    }
}
