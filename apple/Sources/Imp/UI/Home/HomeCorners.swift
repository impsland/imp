import SwiftUI

/// Which corner of the home window each canvas button takes. The window's own buttons (close, minimise,
/// zoom) hold one top corner, so the canvas's buttons spread over the other three, around them:
/// Settings in the other top corner, New Imp below it, and Devices below the window's buttons.
///
/// On macOS the window's buttons are top left: Settings is top right, New Imp bottom right and Devices
/// bottom left. A platform with them top right (Windows) mirrors that: Settings top left, New Imp bottom
/// left and Devices bottom right. Corners are physical, not leading and trailing: the window's buttons stay
/// where the system puts them whatever the language's direction (tested in `ImpTests`).
struct HomeCorners: Equatable {
    enum Corner: Equatable, CaseIterable {
        case topLeft, topRight, bottomLeft, bottomRight

        var isTop: Bool { self == .topLeft || self == .topRight }
        var isLeft: Bool { self == .topLeft || self == .bottomLeft }

        /// The corner on the other side, at the same height.
        var across: Corner {
            switch self {
            case .topLeft: .topRight
            case .topRight: .topLeft
            case .bottomLeft: .bottomRight
            case .bottomRight: .bottomLeft
            }
        }

        /// The corner on the same side, at the other end.
        var below: Corner {
            switch self {
            case .topLeft: .bottomLeft
            case .topRight: .bottomRight
            case .bottomLeft: .topLeft
            case .bottomRight: .topRight
            }
        }

        /// Where the corner is for SwiftUI, which counts leading and trailing in the language's direction.
        func alignment(_ direction: LayoutDirection) -> Alignment {
            let leading = isLeft == (direction == .leftToRight)
            switch (isTop, leading) {
            case (true, true): return .topLeading
            case (true, false): return .topTrailing
            case (false, true): return .bottomLeading
            case (false, false): return .bottomTrailing
            }
        }

        /// The edge of the window the corner's buttons start from, for SwiftUI.
        func outerEdge(_ direction: LayoutDirection) -> Edge.Set {
            isLeft == (direction == .leftToRight) ? .leading : .trailing
        }
    }

    /// The window's own buttons.
    let windowControls: Corner
    let settings: Corner
    let newImp: Corner
    let devices: Corner

    init(windowControls: Corner) {
        self.windowControls = windowControls
        // Settings is the top corner of the side away from the window's buttons, New Imp the bottom one of that
        // side, and Devices whatever corner is left. (On the desktop the window's buttons are always on top.)
        let away = windowControls.across
        let settings = away.isTop ? away : away.below
        let newImp = settings.below
        let taken = [windowControls, settings, newImp]
        self.settings = settings
        self.newImp = newImp
        devices = Corner.allCases.first { !taken.contains($0) } ?? newImp.across
    }

    /// Where the window's buttons are on this platform.
    static var platform: HomeCorners {
        #if os(Windows)
        HomeCorners(windowControls: .topRight)
        #else
        HomeCorners(windowControls: .topLeft)
        #endif
    }
}
