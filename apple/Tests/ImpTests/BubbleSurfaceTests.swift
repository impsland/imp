import AppKit
import ImpDesign
import SwiftUI
import Testing
@testable import Imp

/// The desktop bubble is one fill in one rounded shape: no second background, no outline of another
/// colour, and nothing square in its corners (the panel is transparent, so a corner shows the desktop).
@MainActor @Suite struct BubbleSurfaceTests {
    private typealias RGB = [Double]

    private static func rgb(_ color: NSColor?, in space: NSColorSpace) -> RGB {
        guard let c = color?.usingColorSpace(space) else { return [] }
        return [c.redComponent, c.greenComponent, c.blueComponent]
    }

    private static func close(_ a: RGB, _ b: RGB, _ tolerance: Double = 0.02) -> Bool {
        a.count == 3 && a.count == b.count && zip(a, b).allSatisfy { abs($0 - $1) <= tolerance }
    }

    /// `Tone.raised` as the bubble draws it in `dark` or light, in `space`.
    private static func raised(dark: Bool, in space: NSColorSpace) -> RGB {
        var out: RGB = []
        NSAppearance(named: dark ? .darkAqua : .aqua)?.performAsCurrentDrawingAppearance { out = rgb(NSColor(Tone.raised), in: space) }
        return out
    }

    @Test(arguments: BubbleScene.allCases, [true, false])
    func oneFillAndCleanCorners(scene: BubbleScene, dark: Bool) throws {
        let rep = try #require(scene.image(dark: dark))
        let space = rep.colorSpace
        let w = rep.pixelsWide, h = rep.pixelsHigh
        func at(_ x: Int, _ y: Int) -> RGB { Self.rgb(rep.colorAt(x: x, y: y), in: space) }

        // The corners of the panel are the shadow's room: only the backdrop reaches them. (The window
        // tints its colour a little in the light appearance, so the reference is its own corner pixel.)
        let backdrop = at(0, 0)
        #expect(backdrop[1] > backdrop[0] + 0.1 && backdrop[1] > backdrop[2] + 0.1, "\(scene.rawValue) dark=\(dark): the corner is not the green backdrop: \(backdrop)")
        for (x, y) in [(0, 0), (w - 1, 0), (0, h - 1), (w - 1, h - 1)] {
            #expect(Self.close(at(x, y), backdrop), "\(scene.rawValue) dark=\(dark): corner (\(x), \(y)) is \(at(x, y)), not the backdrop \(backdrop)")
        }

        // The fill is `Tone.raised` (the colour management of the offscreen window shifts it a little).
        let scale = Double(w) / Double(rep.size.width)
        let margin = Int((Double(BubbleView.margin) * scale).rounded())
        let row = h / 2
        let fill = at(margin + Int(6 * scale), row)
        #expect(Self.close(fill, Self.raised(dark: dark, in: space), 0.05), "\(scene.rawValue) dark=\(dark): the card is \(fill), not Tone.raised")

        // The card's own corner pixel is rounded away: it must not be the fill (a square corner would be).
        // (The chat has its floating buttons on its top corners.)
        if scene != .chat {
            #expect(!Self.close(at(margin + 1, margin + 1), fill), "\(scene.rawValue) dark=\(dark): the card's top left corner is square")
        }

        // A scan through the left edge: backdrop and shadow blend, then the fill, and no other colour band.
        var start: Int?
        var before: [(x: Int, p: RGB)] = []
        for x in 0..<(margin + Int(12 * scale)) {
            let p = at(x, row)
            if Self.close(p, fill, 0.01) { start = x; break }
            before.append((x, p))
        }
        // Before the fill: the backdrop darkened by the shadow, never a lighter or differently tinted band.
        // (The last pixel is the anti-aliased edge, a blend of the shadow and the fill.)
        for (x, p) in before.dropLast() {
            #expect(p[0] <= backdrop[0] + 0.02 && p[1] <= backdrop[1] + 0.02 && p[2] <= backdrop[2] + 0.02,
                    "\(scene.rawValue) dark=\(dark): a band of another colour at x=\(x): \(p)")
            #expect(p[1] >= p[0] && p[1] >= p[2], "\(scene.rawValue) dark=\(dark): off-hue pixel at x=\(x): \(p)")
        }
        let first = try #require(start, "\(scene.rawValue) dark=\(dark): no fill found at the left edge")
        #expect(abs(first - margin) <= Int(2 * scale), "\(scene.rawValue) dark=\(dark): the fill starts at \(first), the card edge is at \(margin)")
        for x in first..<(first + Int(10 * scale)) {
            #expect(Self.close(at(x, row), fill, 0.01), "\(scene.rawValue) dark=\(dark): a second colour inside the edge at x=\(x): \(at(x, row))")
        }
    }

    @Test func theBubbleHasNoMaterialOutlineOrDivider() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Imp/UI/Bubble")
        let files = try #require(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
        var bad: [String] = []
        for case let url as URL in files where url.pathExtension == "swift" {
            let source = try String(contentsOf: url, encoding: .utf8)
            for word in ["NSVisualEffectView", "strokeBorder(", "Divider()"] where source.contains(word) && !(word == "NSVisualEffectView" && url.lastPathComponent == "BubbleBlur.swift") {
                bad.append("\(url.lastPathComponent): \(word)")
            }
        }
        #expect(bad.isEmpty, "\(bad)")
    }
}
