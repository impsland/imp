/// The sections of one Imp's settings, in the order the rail lists them. The page of an Imp has the
/// same layout as the app's Settings: the rail on the leading side, the chosen section beside it.
public enum ImpSetting: String, CaseIterable, Identifiable, Sendable {
    case brain, personality, look, animations, triggers, tools, computer

    public var id: String { rawValue }

    /// The setting a page name from a tool or a link means: its own name, or "looks" for the look.
    public init?(page: String) {
        let name = page.trimmingCharacters(in: .whitespaces).lowercased()
        guard let setting = ImpSetting(rawValue: name == "looks" ? "look" : name) else { return nil }
        self = setting
    }

    /// The section's picture, in the rail and on the phone's list.
    public var symbol: String {
        switch self {
        case .brain: "lightbulb.fill"
        case .look: "paintpalette.fill"
        case .personality: "theatermasks.fill"
        case .animations: "figure.dance"
        case .triggers: "bolt.fill"
        case .tools: "wrench.and.screwdriver.fill"
        case .computer: "desktopcomputer"
        }
    }
}
