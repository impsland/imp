import CoreGraphics

/// The six things one Imp's settings are made of. Each is a marker around the Imp, and a row in the
/// plain list.
public enum ImpSetting: String, CaseIterable, Identifiable, Sendable {
    case brain, personality, look, tools, triggers, moves

    public var id: String { rawValue }

    /// The setting a page name from a tool or a link means: its own name, or "looks" for the look.
    public init?(page: String) {
        let name = page.trimmingCharacters(in: .whitespaces).lowercased()
        guard let setting = ImpSetting(rawValue: name == "looks" ? "look" : name) else { return nil }
        self = setting
    }

    /// The order of the plain list, and the order a screen reader meets the settings in.
    public static let listOrder: [ImpSetting] = [.brain, .personality, .look, .tools, .triggers, .moves]

    /// Where the marker sits around the Imp.
    public enum Place: Sendable { case above, left, right, lowerLeft, lowerRight, below }

    public var place: Place {
        switch self {
        case .brain: .above
        case .look: .left
        case .personality: .right
        case .tools: .lowerLeft
        case .triggers: .lowerRight
        case .moves: .below
        }
    }

    /// The marker's picture, shared by the markers and the list.
    public var symbol: String {
        switch self {
        case .brain: "lightbulb.fill"
        case .look: "paintpalette.fill"
        case .personality: "theatermasks.fill"
        case .tools: "wrench.and.screwdriver.fill"
        case .triggers: "bolt.fill"
        case .moves: "figure.dance"
        }
    }
}

public enum ImpSettingsLayout {
    public enum Mode: Sendable { case markers, list }

    /// Markers around the Imp, or the plain list under it. The list is for a window narrower than
    /// `Behavior.narrowWindowPoints`, for accessibility text sizes and for a screen reader.
    public static func mode(width: CGFloat, largeText: Bool, screenReader: Bool) -> Mode {
        largeText || screenReader || width < CGFloat(Behavior.narrowWindowPoints) ? .list : .markers
    }

    /// How the window is shared between the stage (the Imp with its markers, or the list) and a panel.
    public enum Arrangement: Sendable, Equatable {
        /// The stage fills the window.
        case stage
        /// The panel is a column at the trailing edge and the stage keeps the rest.
        case besidePanel
        /// There is no room beside the stage: the panel takes its place.
        case panelOnly
    }

    /// The narrowest window that has room for a panel beside the markers.
    public static var sidePanelMinWidth: CGFloat { Sizing.panelWidth + ImpSettingsGeometry.minStageWidth }

    public static func panelBesideImp(width: CGFloat) -> Bool { width >= sidePanelMinWidth }

    /// A panel opens beside the markers when the window has room, and in place of the stage or the
    /// list in every other case. Closed, the stage fills the window.
    public static func arrangement(width: CGFloat, largeText: Bool, screenReader: Bool, panelOpen: Bool) -> Arrangement {
        guard panelOpen else { return .stage }
        let beside = mode(width: width, largeText: largeText, screenReader: screenReader) == .markers && panelBesideImp(width: width)
        return beside ? .besidePanel : .panelOnly
    }

    /// The width of the stage: the window less the panel column when the panel sits beside it. Under a
    /// panel that takes its place the stage keeps its width and fades out.
    public static func stageWidth(total: CGFloat, arrangement: Arrangement) -> CGFloat {
        arrangement == .besidePanel ? max(0, total - Sizing.panelWidth) : total
    }

    /// The width of the panel column (nothing while it is closed).
    public static func panelWidth(total: CGFloat, arrangement: Arrangement) -> CGFloat {
        switch arrangement {
        case .stage: 0
        case .besidePanel: Sizing.panelWidth
        case .panelOnly: total
        }
    }
}

/// Where the markers stand around the Imp. All numbers are points and come from the size tokens.
public enum ImpSettingsGeometry {
    /// A marker's cell: the round tile with its one-word title under it.
    public static var markerWidth: CGFloat { Sizing.marker * 2 }
    public static var markerHeight: CGFloat { Sizing.marker + Spacing.snug + Spacing.page }
    private static var gap: CGFloat { Spacing.small }
    private static var sideGap: CGFloat { Spacing.roomy }
    /// The smallest and biggest the Imp is drawn in the middle.
    public static var minImp: CGFloat { Sizing.marker * 2.5 }
    public static var maxImp: CGFloat { Sizing.marker * 5.5 }
    /// The Imp above the plain list.
    public static var listImp: CGFloat { Sizing.marker * 3 }

    /// The narrowest stage that holds the Imp at its smallest with a marker on each side.
    public static var minStageWidth: CGFloat { 2 * (markerWidth + sideGap) + minImp }

    /// The Imp's side in a stage of `size`: as big as the markers around it allow.
    public static func imp(in size: CGSize) -> CGFloat {
        let high = size.height - 2 * (markerHeight + gap)
        let wide = size.width - 2 * (markerWidth + sideGap)
        return min(max(min(high, wide), minImp), maxImp)
    }

    /// The centre of a marker, from the centre of the Imp whose side is `imp`. The six stand on an even
    /// hexagon: one above and one below the Imp, two on each side at half the height, so every marker
    /// is as far from its neighbours as the next.
    public static func offset(_ place: ImpSetting.Place, imp: CGFloat) -> CGSize {
        let up = imp / 2 + gap + markerHeight / 2
        let side = imp / 2 + sideGap + markerWidth / 2
        return switch place {
        case .above: CGSize(width: 0, height: -up)
        case .below: CGSize(width: 0, height: up)
        case .left: CGSize(width: -side, height: -up / 2)
        case .right: CGSize(width: side, height: -up / 2)
        case .lowerLeft: CGSize(width: -side, height: up / 2)
        case .lowerRight: CGSize(width: side, height: up / 2)
        }
    }

    /// How much of the preview's frame the Imp fills for a size setting (the smallest size is
    /// 0.75 and the biggest 1.7), so the size slider shows on the Imp in the middle.
    public static func previewScale(_ size: Double) -> Double {
        let t = (min(max(size, 0.75), 1.7) - 0.75) / (1.7 - 0.75)
        return 0.6 + 0.4 * t
    }
}
