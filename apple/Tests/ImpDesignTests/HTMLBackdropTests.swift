import AppKit
import SwiftUI
import JavaScriptCore
import Testing
import WebKit
@testable import ImpDesign

/// The backdrop's web view draws the page an Imp wrote, and nothing it does can take it elsewhere.
@MainActor
@Suite("HTML backdrop", .serialized)
struct HTMLBackdropTests {
    /// Loads `html` in the backdrop's own web view, in a window off screen, and waits until it has drawn.
    private func render(_ html: String) async throws -> (InertWebView, NSImage) {
        let coordinator = HTMLBackdropView.Coordinator()
        let web = HTMLBackdropWeb.make(coordinator)
        let window = NSWindow(contentRect: CGRect(x: -4000, y: -4000, width: 200, height: 120), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.contentView = web
        window.orderBack(nil)
        coordinator.show(html, in: web)
        for _ in 0..<100 where web.isLoading { try await Task.sleep(for: .milliseconds(100)) }
        try await Task.sleep(for: .milliseconds(300))
        let image = try await web.takeSnapshot(configuration: nil)
        window.orderOut(nil)
        return (web, image)
    }

    private func centre(_ image: NSImage) -> (red: Double, green: Double, blue: Double)? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let colour = NSBitmapImageRep(cgImage: cg).colorAt(x: cg.width / 2, y: cg.height / 2)?.usingColorSpace(.sRGB) else { return nil }
        return (colour.redComponent, colour.greenComponent, colour.blueComponent)
    }

    @Test("It draws the page")
    func drawsThePage() async throws {
        let (_, image) = try await render("<html><body style='margin:0;height:100vh;background:#ff0000'></body></html>")
        let c = try #require(centre(image))
        #expect(c.red > 0.9 && c.green < 0.3 && c.blue < 0.3, "\(c)")  // red, in whatever space the window draws in
    }

    @Test("A script that navigates away goes nowhere")
    func staysOnItsPage() async throws {
        let (web, _) = try await render("<html><body style='background:#00ff00'><script>location.href='https://example.com/'</script></body></html>")
        try await Task.sleep(for: .milliseconds(500))
        #expect(web.url?.absoluteString == HTMLBackdropWeb.base.absoluteString)
    }

    @Test("It is never the target of a click")
    func isInert() async throws {
        let (web, _) = try await render(RoomBackgroundSample.plain)
        #expect(web.hitTest(CGPoint(x: 10, y: 10)) == nil)
        #expect(!web.acceptsFirstResponder)
    }
}

extension HTMLBackdropTests {
    /// Loads `html`, asks for a look and waits for the answer: the picture and whether the page moves.
    private func look(_ html: String, size: CGSize = CGSize(width: 160, height: 100), onScreen: Bool = true) async throws -> (CGImage, Bool)? {
        let coordinator = HTMLBackdropView.Coordinator()
        let web = HTMLBackdropWeb.make(coordinator)
        let window = NSWindow(contentRect: CGRect(x: -4000, y: -4000, width: size.width, height: size.height), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.contentView = web
        if onScreen { window.orderBack(nil) }
        defer { window.orderOut(nil) }
        var answer: (CGImage, Bool)?
        coordinator.looked = { answer = ($0, $1) }
        coordinator.show(html, in: web)
        coordinator.look("\(Int(size.width))x\(Int(size.height))", in: web)
        for _ in 0..<60 where answer == nil { try await Task.sleep(for: .milliseconds(100)) }
        return answer
    }

    @Test("A still page is kept as a picture")
    func stillPage() async throws {
        let answer = try #require(try await look("<html><body style='margin:0;background:#3060c0'></body></html>"))
        #expect(answer.1 == false)
    }

    @Test("A moving page is played")
    func movingPage() async throws {
        let page = "<html><style>@keyframes s{to{transform:translateX(120px)}} div{width:30px;height:30px;background:red;animation:s 1s infinite alternate}</style><body><div></div></body></html>"
        let answer = try #require(try await look(page))
        #expect(answer.1 == true)
    }

    /// The page an Imp stored with `imp_set_background` (a night sky with CSS animations), through the
    /// same look the app takes: it must come back painted, not blank, and moving.
    @Test("A stored night sky looks painted and moving")
    func nightSky() async throws {
        let url = try #require(Bundle.module.url(forResource: "night-sky", withExtension: "html", subdirectory: "Fixtures"))
        let answer = try #require(try await look(String(contentsOf: url, encoding: .utf8), size: CGSize(width: 800, height: 500)), "no look came back")
        #expect(answer.1 == true, "CSS animations move")
        let rep = NSBitmapImageRep(cgImage: answer.0)
        func luma(_ x: Double, _ y: Double) -> Double {
            let c = rep.colorAt(x: Int(x * Double(rep.pixelsWide)), y: Int(y * Double(rep.pixelsHigh)))?.usingColorSpace(.sRGB)
            return c.map { 0.3 * $0.redComponent + 0.6 * $0.greenComponent + 0.1 * $0.blueComponent } ?? 0
        }
        // The page means its moon top-right, but `.moon` has no `position`, so it sits top-left, 78 px wide: either way it is
        // the brightest thing drawn, and the sky around it is navy, not the window's dark surface.
        #expect(luma(0.04, 0.08) > 0.5, "moon \(luma(0.04, 0.08))")
        #expect(luma(0.5, 0.3) > 0.03, "sky \(luma(0.5, 0.3))")
    }

    /// The whole view, as the window hosts it: the picture it settles on is drawn by SwiftUI (so it can be
    /// read back), with the window's dark surface under it.
    @Test("The backdrop view settles on the page, not on what is under it", arguments: [true, false])
    func viewSettles(live: Bool) async throws {
        let url = try #require(Bundle.module.url(forResource: "night-sky", withExtension: "html", subdirectory: "Fixtures"))
        let html = try String(contentsOf: url, encoding: .utf8)
        let size = CGSize(width: 800, height: 500)
        let host = NSHostingView(rootView: ZStack { Color.black; HTMLBackdrop(html: html, plain: "plain", live: live) }.frame(width: size.width, height: size.height))
        let window = NSWindow(contentRect: CGRect(origin: CGPoint(x: 40, y: 40), size: size), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.contentView = host
        window.orderBack(nil)
        host.layoutSubtreeIfNeeded()
        defer { window.orderOut(nil) }
        func sky() -> Double {
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return 0 }
            host.cacheDisplay(in: host.bounds, to: rep)
            let c = rep.colorAt(x: Int(0.5 * Double(rep.pixelsWide)), y: Int(0.3 * Double(rep.pixelsHigh)))?.usingColorSpace(.sRGB)
            return c.map { $0.redComponent + $0.greenComponent + $0.blueComponent } ?? 0
        }
        // The look takes about 1.3 s; after it a page that may not move is the picture alone, with no web view.
        try await Task.sleep(for: .seconds(3.5))
        let seen = sky()
        #expect(seen > 0.2, "the sky shows (live: \(live)): \(seen)")
    }

    @Test("A picture with nothing in it is blank; one colour is not")
    func blank() throws {
        func image(_ alpha: CGFloat) throws -> CGImage {
            let ctx = try #require(CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            ctx.setFillColor(CGColor(red: 0.1, green: 0.1, blue: 0.2, alpha: alpha))
            ctx.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
            return try #require(ctx.makeImage())
        }
        #expect(HTMLBackdropWeb.isBlank(try image(0)))
        #expect(!HTMLBackdropWeb.isBlank(try image(1)))
    }

    /// The cap runs on a stand-in for the screen's 60 frames a second, so it is checked without a window.
    @Test("The backdrop never sets the cursor: its web view tracks no part of the window")
    func tracksNoPointer() async throws {
        let (web, _) = try await render("<body style='background:#123'><a href='#' style='cursor:pointer;display:block;height:100vh'>x</a></body>")
        web.updateTrackingAreas()
        #expect(web.trackingAreas.isEmpty)
    }

    @Test("Frames for scripts are held to 30 a second")
    func frameCap() throws {
        let js = try #require(JSContext())
        js.evaluateScript("""
        var window = this; var queue = [];
        window.requestAnimationFrame = function (cb) { queue.push(cb); return queue.length; };
        window.cancelAnimationFrame = function () {};
        function screenFrames(n) { for (var i = 1; i <= n; i++) { var run = queue; queue = []; run.forEach(function (cb) { cb(i * 1000 / 60); }); } }
        """)
        js.evaluateScript(HTMLBackdropWeb.frameCap)
        let n = js.evaluateScript("""
        var n = 0; function f() { n++; requestAnimationFrame(f); } requestAnimationFrame(f);
        var m = 0; function g() { m++; requestAnimationFrame(g); } requestAnimationFrame(g);
        screenFrames(60); [n, m]
        """).toArray() as? [Int] ?? []
        #expect(n.count == 2 && (29...31).contains(n[0]), "\(n)")
        // Two loops in the same page run in the same frames.
        #expect(n.count == 2 && n[0] == n[1])
    }
}

private enum RoomBackgroundSample {
    static let plain = "<html><body></body></html>"
}
