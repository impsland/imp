import AppKit
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
    private func look(_ html: String) async throws -> (CGImage, Bool)? {
        let coordinator = HTMLBackdropView.Coordinator()
        let web = HTMLBackdropWeb.make(coordinator)
        let window = NSWindow(contentRect: CGRect(x: -4000, y: -4000, width: 160, height: 100), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.contentView = web
        window.orderBack(nil)
        defer { window.orderOut(nil) }
        var answer: (CGImage, Bool)?
        coordinator.looked = { answer = ($0, $1) }
        coordinator.show(html, in: web)
        coordinator.look("160x100", in: web)
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

    /// The cap runs on a stand-in for the screen's 60 frames a second, so it is checked without a window.
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
