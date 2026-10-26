import ImpKit
import SwiftUI

/// The window's content: the stage, an Imp's settings, or the settings every Imp shares.
struct HomeView: View {
    @Bindable var model: AppModel
    @Bindable var router: HomeRouter

    var body: some View {
        ZStack {
            DungeonBackdrop(quiet: router.screen != .home)
            Group {
                switch router.screen {
                case .home:
                    ImpStage(model: model, router: router)
                        .transition(.move(edge: .leading).combined(with: .opacity))
                case .imp(let id):
                    if model.profile(id) != nil {
                        ImpSettingsView(model: model, router: router, id: id)
                            .id(id)
                            .transition(.move(edge: .trailing).combined(with: .opacity))
                    } else {
                        Color.clear.onAppear { router.screen = .home }
                    }
                case .general:
                    GeneralSettingsView(model: model, router: router)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
        }
        .environment(\.colorScheme, .dark)
        .tint(Color.imp)
        .frame(minWidth: 660, maxWidth: .infinity, minHeight: 540, maxHeight: .infinity)
        .ignoresSafeArea()
        .background {
            // ⌘, opens the shared settings. ⌘[ goes back.
            Button("") { withAnimation(.snappy(duration: 0.28)) { router.screen = .general } }
                .keyboardShortcut(",", modifiers: .command).opacity(0)
            Button("") { router.goHome() }
                .keyboardShortcut("[", modifiers: .command).opacity(0)
        }
    }
}
