import SwiftUI

extension EnvironmentValues {
    /// False while the home window can't be seen: its animations pause.
    @Entry var stageAwake = true
    /// A moment to hold every Imp at, for stills (design renders and snapshots). Nil: they live.
    @Entry var stageStill: Date?
}
