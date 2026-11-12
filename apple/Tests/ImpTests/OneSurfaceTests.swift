import AppKit
import ImpDesign
import ImpKit
import SwiftUI
import Testing
@testable import Imp

/// The app is one surface: a sheet, a settings screen and the window around them are the same flat
/// colour, in light and dark, whatever the canvas shows behind the settings.
@MainActor @Suite struct OneSurfaceTests {
    private static let appearances: [NSAppearance.Name] = [.aqua, .darkAqua]

    /// The colour of the pixel at (`x`, `y`) of `view` drawn offscreen in `appearance`, as 8-bit sRGB.
    private func pixel(_ view: some View, size: CGSize, appearance: NSAppearance.Name, at point: (x: Int, y: Int)) -> [Int] {
        let host = NSHostingView(rootView: view)
        host.appearance = NSAppearance(named: appearance)
        host.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: CGRect(x: -3000, y: -3000, width: size.width, height: size.height),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = host.appearance
        window.contentView = host
        // Drawn for the pixel read, never seen: fully transparent, and it stays out of the way of the mouse.
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        window.orderFrontRegardless()
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        defer { window.orderOut(nil) }
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return [] }
        host.cacheDisplay(in: host.bounds, to: rep)
        return Self.components(rep.colorAt(x: point.x, y: point.y))
    }

    private static func components(_ color: NSColor?) -> [Int] {
        guard let c = color?.usingColorSpace(.sRGB) else { return [] }
        return [c.redComponent, c.greenComponent, c.blueComponent].map { Int(($0 * 255).rounded()) }
    }

    /// `Tone.surface` for `appearance`, drawn through the same offscreen path as the screens, so the display's colour management applies to both.
    private func surface(_ appearance: NSAppearance.Name) -> [Int] {
        pixel(Tone.surface, size: CGSize(width: 40, height: 40), appearance: appearance, at: (x: 2, y: 2))
    }

    private func close(_ a: [Int], _ b: [Int]) -> Bool {
        a.count == 3 && a.count == b.count && zip(a, b).allSatisfy { abs($0 - $1) <= 2 }
    }

    @Test func aSheetIsTheSurface() {
        for appearance in Self.appearances {
            let sheet = SheetScaffold(icon: "person.fill", title: "Sheet", content: { Text(verbatim: "Body") }, footer: { Text(verbatim: "Foot") })
                .environment(\.sheetRoom, 600)
            let got = pixel(sheet, size: CGSize(width: Sizing.sheetWidth, height: 360), appearance: appearance, at: (x: 2, y: 2))
            #expect(close(got, surface(appearance)), "\(appearance.rawValue): sheet \(got) vs surface \(surface(appearance))")
        }
    }

    @Test func settingsAreTheSurfaceWhateverTheCanvasShows() {
        for appearance in Self.appearances {
            let model = AppModel(persist: false)
            var background = model.prefs.background
            background.kind = .colour
            background.colour.red = 1; background.colour.green = 0; background.colour.blue = 0
            model.prefs.background = background
            let router = HomeRouter()
            router.screen = .general
            let size = CGSize(width: 780, height: 640)
            let view = HomeView(model: model, router: router)
            // The top left corner (under the title bar) and the empty margin beside the column.
            for point in [(x: 2, y: 2), (x: 6, y: 600)] {
                let got = pixel(view, size: size, appearance: appearance, at: point)
                #expect(close(got, surface(appearance)), "\(appearance.rawValue) at \(point): \(got) vs \(surface(appearance))")
            }
        }
    }

    /// No file paints a modal in a colour of its own: sheets use `Tone.surface` and nothing reaches for a system background or a material.
    @Test func noSourceUsesAnotherBackground() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Imp/UI")
        let files = try #require(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
        var bad: [String] = []
        for case let url as URL in files where url.pathExtension == "swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            for (n, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let code = line.split(separator: "//", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
                if code.contains(".presentationBackground("), !code.contains("Tone.surface"), !code.contains("Tone.raised") { bad.append("\(url.lastPathComponent):\(n + 1) presentationBackground") }
                for banned in ["windowBackgroundColor", "controlBackgroundColor", ".regularMaterial", ".thinMaterial", ".ultraThinMaterial", ".thickMaterial", ".ultraThickMaterial", "(.bar)", " .bar)"]
                where code.contains(banned) { bad.append("\(url.lastPathComponent):\(n + 1) \(banned)") }
            }
        }
        #expect(bad.isEmpty, "\(bad)")
    }
}
