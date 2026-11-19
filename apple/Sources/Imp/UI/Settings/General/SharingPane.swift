import ImpDesign
import ImpKit
import SwiftUI

/// Sharing: everything that can be shared in one place (triggers, animations and tools, shared or an
/// Imp's own). Importing a kit is the button in the first header. Browsing and publishing happen in an MCP
/// gallery such as the Den, which is added as a tool (Tools tab): the Imp downloads an item there and
/// `imp_add_kit` opens the review.
struct SharingPane: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.large) {
            SharingTriggers(model: model)
            SharingAnimations(model: model)
            SharingTools(model: model)
        }
    }
}

extension AppModel {
    /// The Imp whose settings open for a shared item: the window's pick, else the first Imp.
    @MainActor func settingsImp(for owner: UUID?) -> ImpProfile? {
        owner.flatMap(profile) ?? HomeWindow.shared.router.selection.flatMap(profile) ?? prefs.imps.first
    }
}
