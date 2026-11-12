/// Which level of one Imp's settings is showing, and what Back does there. Two levels only: the
/// stage (the markers or the plain list) and one panel. Anything a panel pushes (a server, a trigger,
/// an animation, adding a service) is a sheet with its own Close, so it is not a level here.
public struct ImpSettingsNavigation: Equatable, Sendable {
    /// The open panel, or nil on the stage.
    public private(set) var panel: ImpSetting?
    /// The marker that opened the panel last: focus goes back to it when the panel closes.
    public private(set) var returnFocus: ImpSetting?

    public init(panel: ImpSetting? = nil) {
        self.panel = panel
        self.returnFocus = panel
    }

    /// What Back did.
    public enum Outcome: Equatable, Sendable {
        /// The panel closed: the stage is back and focus goes to this marker.
        case closedPanel(focus: ImpSetting)
        /// Nothing was open: leave the settings for the home screen.
        case leave
    }

    /// A marker was activated: it opens its panel, or closes it when it is the open one.
    public mutating func toggle(_ setting: ImpSetting) {
        if panel == setting { panel = nil } else { open(setting) }
    }

    /// Opens a panel (also when another is open: a switch, not a stack).
    public mutating func open(_ setting: ImpSetting) {
        panel = setting
        returnFocus = setting
    }

    /// Back from a panel returns to the stage and never leaves the settings. Back from the stage leaves.
    public mutating func back() -> Outcome {
        guard let current = panel else { return .leave }
        panel = nil
        returnFocus = current
        return .closedPanel(focus: current)
    }

    /// Whether Back leaves the settings (true on the stage only).
    public var backLeaves: Bool { panel == nil }
}
