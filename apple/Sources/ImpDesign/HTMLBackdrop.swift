import Combine
import os
import SwiftUI
import WebKit

/// An HTML document drawn as a backdrop: full size, under everything, never clickable, never focused,
/// and hidden from VoiceOver. It runs in its own web view with no storage that outlives it, no
/// windows, no navigation away from the document and no sound that starts by itself. Pictures and
/// fonts it links to may load. Until it has drawn, what is under it shows through.
///
/// A web view is a process of its own (tens of megabytes) and a moving page keeps a core busy, so the
/// web view lives only while it has to:
/// - The plain page (`plain`) is never loaded: the view under it already looks the same.
/// - A page is loaded once and looked at twice, a moment apart. A still page is kept as that picture and
///   its web view goes. It is drawn again only when the page, the size or light and dark change.
/// - A moving page keeps its web view only while `live` (on screen, the app in front), and never in Low
///   Power Mode or with Reduce Motion: then the last picture stands in. Its frames are held to 30 a second.
public struct HTMLBackdrop: View {
    let html: String
    let plain: String?
    let live: Bool

    /// `plain`: the page that looks like the view under it (nothing is drawn for it). `live`: the page
    /// may move now.
    public init(html: String, plain: String? = nil, live: Bool = true) {
        self.html = html; self.plain = plain; self.live = live
    }

    @State private var still: Still?
    @State private var lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
    @State private var size: CGSize = .zero
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The last picture of a page, and what it was taken for.
    struct Still: Equatable {
        var image: CGImage
        var html: String
        var size: CGSize
        var dark: Bool
        var moving: Bool
        static func == (a: Self, b: Self) -> Bool { a.image === b.image }
    }

    private var current: Bool { still.map { $0.html == html && $0.size == size && $0.dark == (scheme == .dark) } ?? false }

    /// The web view is needed: to look at a page not looked at yet, or to play a moving one.
    private var needsWeb: Bool {
        guard html != plain, size.width > 0, size.height > 0 else { return false }
        guard current, let still else { return true }
        return still.moving && live && !lowPower && !reduceMotion
    }

    public var body: some View {
        // The size is what the backdrop is offered and nothing else: a clear base takes exactly that, and the page
        // (its picture or its web view) is drawn over it at that size and clipped. An overlay never sizes what it
        // is on, so whatever a page draws (wider than the screen, a web view that wants its own size) can't
        // make the window's content larger and move what is laid out with it. The base also gives the layer a
        // size while nothing is drawn yet: that size is what tells it to look at the page at all.
        Color.clear
            .onGeometryChange(for: CGSize.self) { $0.size } action: { size = $0 }  // a resize is looked at again once still
            .overlay(alignment: .topLeading) {
                ZStack {
                    if html != plain, let still {
                        Image(decorative: still.image, scale: 1)
                            .resizable()
                            .scaledToFill()
                    }
                    if needsWeb {
                        HTMLBackdropView(html: html, look: current ? nil : "\(Int(size.width))x\(Int(size.height))-\(scheme == .dark)") { image, moving in
                            still = Still(image: image, html: html, size: size, dark: scheme == .dark, moving: moving)
                        }
                    }
                }
                .frame(width: size.width, height: size.height)
                .clipped()
            }
            .onReceive(NotificationCenter.default.publisher(for: .NSProcessInfoPowerStateDidChange)) { _ in
                lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
            }
            .ignoresSafeArea()
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// The web view's settings, the same on the Mac and the iPhone.
@MainActor
enum HTMLBackdropWeb {
    static func make(_ coordinator: HTMLBackdropView.Coordinator) -> InertWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.mediaTypesRequiringUserActionForPlayback = .all
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        config.preferences.isElementFullscreenEnabled = false
        config.userContentController.addUserScript(WKUserScript(source: frameCap, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        let web = InertWebView(frame: .zero, configuration: config)
        web.navigationDelegate = coordinator
        web.uiDelegate = coordinator
        web.allowsBackForwardNavigationGestures = false
        #if os(macOS)
        web.setValue(false, forKey: "drawsBackground")
        web.underPageBackgroundColor = .clear
        web.allowsMagnification = false
        #else
        web.isOpaque = false
        web.backgroundColor = .clear
        web.scrollView.backgroundColor = .clear
        web.scrollView.isScrollEnabled = false
        web.scrollView.contentInsetAdjustmentBehavior = .never
        web.isUserInteractionEnabled = false
        #endif
        return web
    }

    /// The address the document is loaded at. Only it may be navigated to.
    static let base = URL(string: "about:blank")!

    /// The frame rate a backdrop's scripts get: half the screen's. CSS animations run in the compositor
    /// and cost little. `requestAnimationFrame` loops are what keep a core busy.
    static let framesPerSecond = 30

    /// Holds `requestAnimationFrame` callbacks to `framesPerSecond`. Callbacks asked for in the same frame
    /// still run together, and `cancelAnimationFrame` still cancels.
    static let frameCap = """
    (() => {
      const raf = window.requestAnimationFrame.bind(window), caf = window.cancelAnimationFrame.bind(window);
      const gap = 1000 / \(framesPerSecond) - 2, pending = new Map();
      let next = 0, last = -1e9;
      window.requestAnimationFrame = (cb) => {
        const id = ++next;
        const tick = (t) => {
          if (t !== last && t - last < gap) { pending.set(id, raf(tick)); return; }
          last = t; pending.delete(id); cb(t);
        };
        pending.set(id, raf(tick));
        return id;
      };
      window.cancelAnimationFrame = (id) => { const h = pending.get(id); if (h !== undefined) { caf(h); pending.delete(id); } };
    })();
    """

    /// Whether a picture has nothing in it: every pixel is clear (a page that has not painted yet). A page
    /// of one colour is not blank.
    static func isBlank(_ image: CGImage) -> Bool {
        let w = 16, h = 16
        var data = [UInt8](repeating: 0, count: w * h * 4)
        data.withUnsafeMutableBytes { buffer in
            guard let ctx = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        return stride(from: 3, to: data.count, by: 4).allSatisfy { data[$0] < 4 }
    }

    /// Whether two pictures of a page differ: each is drawn 32 pixels wide and compared, so the noise of
    /// scaling never counts as movement.
    static func differ(_ a: CGImage, _ b: CGImage) -> Bool {
        func pixels(_ image: CGImage) -> [UInt8] {
            let w = 32, h = 32
            var data = [UInt8](repeating: 0, count: w * h * 4)
            let space = CGColorSpace(name: CGColorSpace.sRGB)!
            data.withUnsafeMutableBytes { buffer in
                guard let ctx = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                          space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
                ctx.interpolationQuality = .medium
                ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            }
            return data
        }
        let pa = pixels(a), pb = pixels(b)
        var changed = 0
        for i in pa.indices where abs(Int(pa[i]) - Int(pb[i])) > 6 { changed += 1 }
        return changed > 8
    }
}

#if os(macOS)
/// A web view that is never the target of a click, a scroll, the keyboard or the pointer.
///
/// `hitTest` keeps clicks away, but tracking areas fire whatever `hitTest` says: a web view keeps its own
/// and sets the page's cursor (the arrow) on every move, all over the window it sits behind. So it has none,
/// and the cursor is what the controls in front of it ask for (the I-beam in a field, a resize arrow).
final class InertWebView: WKWebView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var acceptsFirstResponder: Bool { false }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
    }

    override func cursorUpdate(with event: NSEvent) {}
    override func mouseMoved(with event: NSEvent) {}
    override func mouseEntered(with event: NSEvent) {}
    override func mouseExited(with event: NSEvent) {}
}

struct HTMLBackdropView: NSViewRepresentable {
    let html: String
    /// Look at the page (again whenever this changes: a new size, light or dark) and say whether it moves.
    /// Nil: just play it.
    var look: String?
    var looked: (CGImage, Bool) -> Void = { _, _ in }

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> InertWebView { HTMLBackdropWeb.make(context.coordinator) }
    func updateNSView(_ web: InertWebView, context: Context) {
        context.coordinator.looked = looked
        context.coordinator.show(html, in: web)
        context.coordinator.look(look, in: web)
    }
    static func dismantleNSView(_ web: InertWebView, coordinator: Coordinator) { coordinator.stop(web) }
}
#else
/// A web view that is never the target of a touch.
final class InertWebView: WKWebView {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? { nil }
}

struct HTMLBackdropView: UIViewRepresentable {
    let html: String
    /// Look at the page (again whenever this changes: a new size, light or dark) and say whether it moves.
    /// Nil: just play it.
    var look: String?
    var looked: (CGImage, Bool) -> Void = { _, _ in }

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIView(context: Context) -> InertWebView { HTMLBackdropWeb.make(context.coordinator) }
    func updateUIView(_ web: InertWebView, context: Context) {
        context.coordinator.looked = looked
        context.coordinator.show(html, in: web)
        context.coordinator.look(look, in: web)
    }
    static func dismantleUIView(_ web: InertWebView, coordinator: Coordinator) { coordinator.stop(web) }
}
#endif

extension HTMLBackdropView {
    /// Loads a document once, and again only when it changes. Once it has drawn, takes two pictures of it a
    /// moment apart and reports the second and whether the page moved.
    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        private var shown: String?
        private var loaded = false
        /// What was asked to be looked at last, and what was looked at.
        private var wanted: String?
        private var lookedAt: String?
        /// What the look under way is for.
        private var lookingAt: String?
        private var looking: Task<Void, Never>?
        var looked: ((CGImage, Bool) -> Void)?

        /// How long a page gets to draw, and how far apart the two pictures are.
        static let settle: Duration = .milliseconds(600)
        static let apart: Duration = .milliseconds(700)

        func show(_ html: String, in web: WKWebView) {
            guard html != shown else { return }
            shown = html
            loaded = false
            lookedAt = nil
            lookingAt = nil
            looking?.cancel()
            web.loadHTMLString(html, baseURL: HTMLBackdropWeb.base)
        }

        /// Looks at the page for `key` once it has loaded, unless that was looked at already.
        func look(_ key: String?, in web: WKWebView) {
            wanted = key
            guard let key, loaded, key != lookedAt, key != lookingAt else { return }
            startLooking(web, for: key)
        }

        func stop(_ web: WKWebView) {
            looking?.cancel()
            web.stopLoading()
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            loaded = true
            if let wanted { startLooking(webView, for: wanted) }
        }

        /// Two pictures a moment apart. A newer request (the window still being resized) cancels this one,
        /// so a resize is looked at once, when it stops. A look that finds nothing painted (no picture, or a
        /// picture with nothing in it) is never kept: it is tried again, a few times.
        private func startLooking(_ webView: WKWebView, for key: String) {
            looking?.cancel()
            lookingAt = key
            looking = Task { [weak self, weak webView] in
                // A look that could not finish may be asked for again.
                defer { if !Task.isCancelled, self?.lookingAt == key { self?.lookingAt = nil } }
                for attempt in 1...Self.attempts {
                    try? await Task.sleep(for: Self.settle)
                    guard let webView, !Task.isCancelled, let first = await Self.picture(of: webView), !Task.isCancelled else { return }
                    // A page with CSS animations or transitions moves even when two pictures happen to match.
                    let animations = (try? await webView.evaluateJavaScript("document.getAnimations().length")) as? Int ?? 0
                    try? await Task.sleep(for: Self.apart)
                    guard let second = await Self.picture(of: webView), !Task.isCancelled else { return }
                    if HTMLBackdropWeb.isBlank(first) || HTMLBackdropWeb.isBlank(second) {
                        Self.log.notice("look \(attempt)/\(Self.attempts): blank, the page has not painted")
                        continue
                    }
                    let moving = animations > 0 || HTMLBackdropWeb.differ(first, second)
                    Self.log.notice("look: \(moving ? "moving" : "still") (\(animations) animations)")
                    self?.lookedAt = key
                    self?.lookingAt = nil
                    self?.looked?(second, moving)
                    return
                }
                Self.log.error("look: blank after \(Self.attempts) tries; the page plays, nothing is kept")
            }
        }

        private static let log = Logger(subsystem: "app.imp.Imp", category: "backdrop")
        /// How often a blank look is tried again.
        private static let attempts = 4

        private static func picture(of web: WKWebView) async -> CGImage? {
            guard web.bounds.width > 0, web.bounds.height > 0, let image = try? await web.takeSnapshot(configuration: nil) else { return nil }
            #if os(macOS)
            return image.cgImage(forProposedRect: nil, context: nil, hints: nil)
            #else
            return image.cgImage
            #endif
        }

        /// Only the document itself (and frames inside it) may load. A link, a form or a script that tries
        /// to go somewhere else goes nowhere.
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
            let isDocument = action.targetFrame?.isMainFrame == true && action.request.url?.absoluteString == HTMLBackdropWeb.base.absoluteString
            let isFrame = action.targetFrame.map { !$0.isMainFrame } ?? false
            return (isDocument || isFrame) && action.navigationType == .other ? .allow : .cancel
        }

        /// No new windows.
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? { nil }
    }
}
