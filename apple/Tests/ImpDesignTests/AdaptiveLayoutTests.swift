import AppKit
@testable import ImpDesign
import SwiftUI
import Testing

/// A crowded row turns labelled controls into icons. It never wraps a label onto a second line or
/// squeezes it (docs/design/index.md, "Help, choices and space").
@MainActor
@Suite struct AdaptiveLayoutTests {
    private func size(_ view: some View, width: CGFloat) -> CGSize {
        NSHostingController(rootView: view.impControls()).sizeThatFits(in: CGSize(width: width, height: 1000))
    }

    @Test func aPillButtonKeepsItsLabelOnOneLine() {
        let button = Button {} label: { Text(verbatim: "Choose a picture for the background") }
        let roomy = size(button, width: 1000)
        let tight = size(button, width: 60)
        #expect(tight.height == roomy.height, "the label wrapped: \(tight) vs \(roomy)")
        #expect(tight.width == roomy.width, "the label was squeezed: \(tight) vs \(roomy)")
    }

    @Test func aFitLabelBecomesAnIconWhenTheRowIsNarrow() {
        let button = Button {} label: { FitLabel(verbatim: "Check the connection", systemImage: "checkmark.circle") }
        let roomy = size(button, width: 1000)
        let narrow = size(button, width: Sizing.hit * 2)
        #expect(narrow.width <= Sizing.hit * 2, "the icon form does not fit: \(narrow)")
        #expect(narrow.width < roomy.width)
        #expect(narrow.height <= roomy.height, "the narrow form grew taller: \(narrow) vs \(roomy)")
    }

    @Test func aSegmentedChoiceFallsBackToIcons() {
        enum Kind: CaseIterable { case theme, colour, picture, tile }
        let titles: [Kind: String] = [.theme: "Theme", .colour: "Colour", .picture: "Picture", .tile: "Tile"]
        let symbols: [Kind: String] = [.theme: "square.grid.3x3.fill", .colour: "paintpalette", .picture: "photo", .tile: "square.grid.2x2"]
        let control = ImpSegmented("Background", selection: .constant(Kind.theme), options: Kind.allCases,
                                   title: { titles[$0] ?? "" }, symbol: { symbols[$0] ?? "" })
        let roomy = size(control, width: 1000)
        let narrow = size(control, width: roomy.width - 1)
        #expect(narrow.width < roomy.width, "no icon form: \(narrow) vs \(roomy)")
        #expect(narrow.height == roomy.height)
    }

    private enum Act: CaseIterable { case settings, voice, nothing }

    private func actions(placement: ControlPlacement = .automatic, fills: Bool? = nil) -> some View {
        let titles: [Act: String] = [.settings: "Open its settings", .voice: "Talk by voice", .nothing: "Do nothing"]
        let symbols: [Act: String] = [.settings: "slider.horizontal.3", .voice: "mic", .nothing: "nosign"]
        return ImpSegmented("Click", selection: .constant(Act.voice), options: Act.allCases,
                            title: { titles[$0] ?? "" }, symbol: { symbols[$0] ?? "" }, fills: fills)
            .environment(\.controlPlacement, placement)
    }

    @Test func aSegmentedBarFillsTheWidthItIsOffered() {
        let words = size(actions(), width: 1000)
        #expect(words.width == 1000, "the bar did not fill: \(words)")
        // Beside its title it is only as wide as its words.
        let beside = size(actions(placement: .beside), width: 1000)
        #expect(beside.width < 1000, "a bar beside its title stretched: \(beside)")
        // `fills: false` overrides the placement.
        #expect(size(actions(fills: false), width: 1000).width < 1000)
    }

    @Test func aSegmentedBarNeverReportsLessThanItsSegmentsNeed() {
        // From roomy to tiny, in steps: the words form, then icons, then the menu. Whatever it picks,
        // it never reports a width above what it was offered unless even the menu cannot fit, and a
        // bar never reports less than the words need while showing words.
        let roomy = size(actions(placement: .beside), width: 2000)
        var widths: [CGFloat] = []
        for offered in stride(from: roomy.width + 40, through: Sizing.hit * 4, by: -10) {
            let got = size(actions(), width: offered)
            widths.append(got.width)
            #expect(got.width <= offered + 0.5, "overflow at \(offered): \(got)")
            #expect(got.height >= Sizing.hit - 1, "a segment was squeezed at \(offered): \(got)")
        }
        // It did fall back: at the narrowest there is a smaller form than the words.
        #expect(size(actions(placement: .beside), width: roomy.width - 1).width < roomy.width)
        #expect(widths.last! < roomy.width)
    }

    @Test func aSegmentedBarHasEqualColumns() {
        // Three segments of different widths: every column is as wide as the widest, and the bar never
        // reports less than that, however little it is offered (so a parent falls back to icons).
        let row = SegmentRow(spacing: 2, fills: false) {
            Color.clear.frame(width: 30, height: 10)
            Color.clear.frame(width: 80, height: 10)
            Color.clear.frame(width: 50, height: 10)
        }
        #expect(abs(size(row, width: 1000).width - (80 * 3 + 2 * 2)) < 1)
        #expect(abs(size(row, width: 100).width - (80 * 3 + 2 * 2)) < 1, "reported less than its columns need")
        let filling = SegmentRow(spacing: 2, fills: true) {
            Color.clear.frame(width: 30, height: 10)
            Color.clear.frame(width: 80, height: 10)
            Color.clear.frame(width: 50, height: 10)
        }
        #expect(abs(size(filling, width: 600).width - (600)) < 1)
        #expect(abs(size(filling, width: 100).width - (80 * 3 + 2 * 2)) < 1)
    }
}
