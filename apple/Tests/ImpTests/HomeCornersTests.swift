import SwiftUI
import Testing
@testable import Imp

/// The canvas's buttons take the three corners the window's own buttons leave free.
@Suite struct HomeCornersTests {
    @Test func onAMacSettingsIsTopRightNewImpBottomRightAndDevicesBottomLeft() {
        let mac = HomeCorners.platform
        #expect(mac.windowControls == .topLeft)
        #expect(mac.settings == .topRight && mac.newImp == .bottomRight && mac.devices == .bottomLeft)
    }

    @Test func withTheWindowButtonsTopRightEverythingMirrors() {
        let windows = HomeCorners(windowControls: .topRight)
        #expect(windows.settings == .topLeft && windows.newImp == .bottomLeft && windows.devices == .bottomRight)
    }

    @Test func noTwoThingsShareACorner() {
        for controls in HomeCorners.Corner.allCases {
            let c = HomeCorners(windowControls: controls)
            #expect(Set([c.windowControls, c.settings, c.newImp, c.devices].map { "\($0)" }).count == 4)
        }
    }

    @Test func cornersStayPutWhateverTheLanguagesDirection() {
        #expect(HomeCorners.Corner.topRight.alignment(.leftToRight) == .topTrailing)
        #expect(HomeCorners.Corner.topRight.alignment(.rightToLeft) == .topLeading)
        #expect(HomeCorners.Corner.bottomLeft.alignment(.leftToRight) == .bottomLeading)
        #expect(HomeCorners.Corner.bottomLeft.outerEdge(.rightToLeft) == .trailing)
    }
}
