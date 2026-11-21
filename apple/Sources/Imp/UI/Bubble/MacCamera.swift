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
        let panel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 440), styleMask: [.titled, .closable],
                             backing: .buffered, defer: false)
        panel.title = String(localized: "Take a photo")
        panel.isReleasedWhenClosed = false
        panel.contentView = NSHostingView(rootView: MacCameraView(camera: camera, finish: { file in
            if let file { onPhoto(file) }
            panel.close()
        }))
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
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black)
            .clipShape(RoundedRectangle(cornerRadius: Radius.tile, style: .continuous))
            HStack {
                if still == nil {
                    Spacer()
                    Button { shoot() } label: {
                        Circle().strokeBorder(Color.white, lineWidth: 3).background(Circle().fill(Color.white.opacity(0.85)).padding(5))
                            .frame(width: 46, height: 46)
                    }
                    .buttonStyle(.plain)
                    .disabled(camera.state != .running || taking)
                    .help("Take the photo")
                    .accessibilityLabel("Take the photo")
                    Spacer()
                } else {
                    Button("Retake") { still = nil }
                    Spacer()
                    Button("Use Photo") { use() }.keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(Spacing.cozy)
        .frame(width: 520, height: 440)
        .task { await camera.start() }
    }

    private func message(_ text: String) -> some View {
        Text(text).font(Typeface.body).foregroundStyle(Color.white).multilineTextAlignment(.center).padding()
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
