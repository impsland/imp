import AppKit
import SwiftUI
import Testing
@testable import Imp

/// The settings grid lays out at any width SwiftUI asks about, including "as wide as you like".
@MainActor @Suite struct EvenGridTests {
    private func grid() -> some View {
        EvenGrid(minWidth: 120) {
            ForEach(0..<5, id: \.self) { i in Text("Choice \(i)").frame(maxWidth: .infinity) }
        }
    }

    @Test func anEndlessWidthGivesItsNaturalSize() {
        let host = NSHostingController(rootView: grid())
        let size = host.sizeThatFits(in: CGSize(width: CGFloat.infinity, height: CGFloat.infinity))
        #expect(size.width.isFinite && size.width > 0)
        #expect(size.height.isFinite && size.height > 0)
    }

    @Test func aNarrowWidthStacksTheChoices() {
        let host = NSHostingController(rootView: grid())
        let narrow = host.sizeThatFits(in: CGSize(width: 130, height: CGFloat.infinity))
        let wide = host.sizeThatFits(in: CGSize(width: 700, height: CGFloat.infinity))
        #expect(narrow.height > wide.height)
    }
}
