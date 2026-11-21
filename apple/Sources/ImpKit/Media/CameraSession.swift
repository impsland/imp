import AVFoundation
import Foundation
import ImageIO
import Observation

/// A camera for taking a photo: the Mac's, or the iPhone's back and front ones. The apps draw `session`
/// in a preview and call `capture()` for the still. The same on both platforms.
@MainActor
@Observable
public final class CameraSession: NSObject {
    public enum State: Equatable, Sendable { case idle, denied, unavailable, running }

    public private(set) var state = State.idle
    public private(set) var position = AVCaptureDevice.Position.back
    /// The capture session a preview layer shows.
    @ObservationIgnored public let session = AVCaptureSession()
    @ObservationIgnored private let output = AVCapturePhotoOutput()
    @ObservationIgnored private var input: AVCaptureDeviceInput?
    @ObservationIgnored private var configured = false
    @ObservationIgnored private var pending: CheckedContinuation<CGImage?, Never>?
    @ObservationIgnored private let queue = DispatchQueue(label: "app.imp.camera")

    public override init() { super.init() }

    /// Asks for the camera if needed, then starts the picture running.
    public func start() async {
        guard await AVCaptureDevice.requestAccess(for: .video) else { state = .denied; return }
        guard configure() else { state = .unavailable; return }
        nonisolated(unsafe) let session = session
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            queue.async { if !session.isRunning { session.startRunning() }; done.resume() }
        }
        state = .running
    }

    public func stop() {
        nonisolated(unsafe) let session = session
        queue.async { if session.isRunning { session.stopRunning() } }
        if state == .running { state = .idle }
    }

    /// Switches between the back and front cameras (a Mac has one).
    public func flip() {
        position = position == .back ? .front : .back
        guard swapInput() else { position = position == .back ? .front : .back; return }
    }

    public var canFlip: Bool {
        #if os(iOS)
        AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front) != nil
        #else
        false
        #endif
    }

    private func device(_ position: AVCaptureDevice.Position) -> AVCaptureDevice? {
        #if os(iOS)
        AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position)
        #else
        AVCaptureDevice.default(for: .video)
        #endif
    }

    private func configure() -> Bool {
        if configured { return true }
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        session.sessionPreset = .photo
        guard let camera = device(position), let input = try? AVCaptureDeviceInput(device: camera), session.canAddInput(input),
              session.canAddOutput(output) else { return false }
        session.addInput(input)
        session.addOutput(output)
        self.input = input
        configured = true
        return true
    }

    private func swapInput() -> Bool {
        guard let camera = device(position), let next = try? AVCaptureDeviceInput(device: camera) else { return false }
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        if let input { session.removeInput(input) }
        guard session.canAddInput(next) else {
            if let input { session.addInput(input) }
            return false
        }
        session.addInput(next)
        input = next
        return true
    }

    /// Takes the picture (upright, at most 2560 points on the long side). Nil if the camera failed.
    public func capture() async -> CGImage? {
        guard state == .running, pending == nil else { return nil }
        #if os(iOS)
        output.connection(with: .video)?.videoRotationAngle = 90
        output.connection(with: .video)?.isVideoMirrored = position == .front
        #endif
        return await withCheckedContinuation { (done: CheckedContinuation<CGImage?, Never>) in
            pending = done
            output.capturePhoto(with: AVCapturePhotoSettings(), delegate: self)
        }
    }

    fileprivate func finish(_ data: Data?) {
        let image = data.flatMap { Self.upright($0) }
        pending?.resume(returning: image)
        pending = nil
    }

    /// The photo's pixels with the camera's orientation applied.
    static func upright(_ data: Data, maxPixel: Int = 2560) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                        kCGImageSourceCreateThumbnailWithTransform: true,
                                        kCGImageSourceThumbnailMaxPixelSize: maxPixel]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}

extension CameraSession: AVCapturePhotoCaptureDelegate {
    public nonisolated func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        let data = error == nil ? photo.fileDataRepresentation() : nil
        Task { @MainActor in self.finish(data) }
    }
}
