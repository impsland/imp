import AppKit
import AVFoundation
import ImpDesign
import ImpKit
import SwiftUI

/// "Take a photo": a small window with the Mac's camera, a shutter, then Retake or Use Photo.
@MainActor
enum MacCamera {
    private static var window: NSWindow?

    static func present(onPhoto: @escaping (MediaFile) -> Void) {
        window?.close()
        let camera = CameraSession()
        let panel = NSWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        panel.title = String(localized: "Take a photo")
        panel.isReleasedWhenClosed = false
        let content = NSHostingView(rootView: MacCameraView(camera: camera, finish: { file in
            if let file { onPhoto(file) }
            panel.close()
        }))
        panel.contentView = content
        panel.setContentSize(content.fittingSize)
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: panel, queue: .main) { _ in
            MainActor.assumeIsolated { camera.stop(); if window === panel { window = nil } }
        }
        panel.center()
        window = panel
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
    }
}

private struct MacCameraView: View {
    let camera: CameraSession
    let finish: (MediaFile?) -> Void
    @State private var still: CGImage?
    @State private var taking = false

    /// The viewfinder: as wide as a sheet's content, in the 4:3 of a Mac camera.
    private static let finderWidth = Sizing.sheetWidth - 2 * Spacing.cozy

    var body: some View {
        VStack(spacing: Spacing.cozy) {
            ZStack {
                if let still {
                    Image(decorative: still, scale: 1).resizable().aspectRatio(contentMode: .fit)
                } else {
                    switch camera.state {
                    case .denied: message(String(localized: "Imp can't see the camera. Allow it in System Settings."))
                    case .unavailable: message(String(localized: "No camera found."))
                    case .idle, .running: MacCameraPreview(session: camera.session)
                    }
                }
            }
            .frame(width: Self.finderWidth, height: Self.finderWidth * 3 / 4)
            .background(Tone.ink)
            .clipShape(RoundedRectangle(cornerRadius: Radius.tile, style: .continuous))
            HStack {
                if still == nil {
                    Spacer()
                    ShutterButton { shoot() }
                        .disabled(camera.state != .running || taking)
                        .help("Take the photo")
                    Spacer()
                } else {
                    Button("Retake") { still = nil }
                        .buttonStyle(ImpButtonStyle(kind: .secondary))
                    Spacer()
                    Button("Use Photo") { use() }
                        .buttonStyle(ImpButtonStyle(kind: .primary))
                        .keyboardShortcut(.defaultAction)
                }
            }
            .frame(minHeight: Sizing.shutter + Spacing.small)
        }
        .padding(Spacing.cozy)
        .task { await camera.start() }
    }

    private func message(_ text: String) -> some View {
        Text(text).font(Typeface.body).foregroundStyle(Tone.paper).multilineTextAlignment(.center).padding(Spacing.large)
    }

    private func shoot() {
        taking = true
        Task {
            still = await camera.capture()
            taking = false
        }
    }

    private func use() {
        guard let still, let encoded = EncodedImage.encode(still) else { return finish(nil) }
        finish(MediaFile(encoded, name: "photo"))
    }
}

private struct MacCameraPreview: NSViewRepresentable {
    let session: AVCaptureSession

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspect
        view.layer = layer
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {}
}
