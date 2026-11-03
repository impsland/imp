import AppKit
import SwiftUI
import Testing
import ImpKit
@testable import Imp

/// The New Animation sheet has to fit the room it gets, so its form doesn't need a scrollbar.
@MainActor @Suite struct SheetFitTests {
    /// What the sheet wants when nothing limits it.
    private func idealHeight(of draft: (AppModel) -> AnimationDraft) -> CGFloat {
        let model = AppModel(persist: false)
        model.prefs = ImpPreferences()
        let host = NSHostingView(rootView: AnimationEditor(model: model, draft: draft(model)).environment(\.sheetRoom, 4000))
        let window = NSWindow(contentRect: CGRect(x: -3000, y: -3000, width: 780, height: 2000),
                              styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        window.contentView = host
        window.orderFrontRegardless()
        RunLoop.main.run(until: Date().addingTimeInterval(1.0))
        let h = host.fittingSize.height
        window.orderOut(nil)
        return h
    }

    /// The room a sheet gets in the home window at a content height (as `SheetRoom.available` works it out).
    private func room(contentHeight: CGFloat) -> CGFloat {
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 780, height: contentHeight),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: true)
        return window.contentLayoutRect.height - SheetRoom.margin
    }

    @Test func newAnimationFitsTheDefaultWindow() {
        let ideal = idealHeight { .new(owner: nil, model: $0) }
        let got = room(contentHeight: HomeWindow.defaultSize.height)
        #expect(ideal <= got)
    }

    /// At the smallest window the sheet scrolls on purpose (header and buttons stay put). It must still
    /// never be asked to squeeze its form below the least the sheet allows.
    @Test func theSmallestWindowStillLeavesRoomToScroll() {
        let room = room(contentHeight: HomeWindow.minimumSize.height)
        #expect(room >= SheetRoom.minimumForm + 200)
    }
}
