import AppKit
import ImpKit
import SwiftUI
import ImpDesign

/// The menu bar panel: a row of buttons (Imps, Hide, Settings, Quit) and, under them, each Imp as a pebble: one click
/// hides or shows an Imp that is out, or opens one that is at home. Everything else lives in the app's window and in
/// each Imp's own right-click menu. Each command closes the panel first, then runs within the click, so a window
/// opened here is brought forward as the user's own request (see `HomeWindow.bringToFront`).
struct StatusPanel: View {
    let model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let anyoneOut = !model.imps.isEmpty
        let shown = !model.anyHiding
        VStack(spacing: Spacing.snug) {
            QuickBar(buttons: [
                QuickBar.Item(icon: "house.fill", title: "menu.bar.imps", help: words("menu.bar.imps_help")) {
                    run { HomeWindow.shared.reveal(model) }
                },
                QuickBar.Item(icon: shown ? "eye.slash.fill" : "eye.fill", title: shown ? "menu.bar.hide" : "menu.bar.show",
                              help: anyoneOut ? words(shown ? "menu.bar.hide_help" : "menu.bar.show_help") : words("menu.bar.none_out_help"),
                              enabled: anyoneOut) {
                    run { model.setHidden(!model.anyHiding) }
                },
                QuickBar.Item(icon: "gearshape.fill", title: "menu.bar.settings", help: words("menu.bar.settings_help")) {
                    run { HomeWindow.shared.showGeneral(model) }
                },
                QuickBar.Item(icon: "power", title: "menu.bar.quit", help: words("menu.bar.quit_help")) {
                    run { NSApp.terminate(nil) }
                },
            ])
            ForEach(model.prefs.imps) { profile in
                ImpPebble(profile: profile, state: state(of: profile)) {
                    run { choose(profile) }
                }
            }
        }
        .padding(Spacing.medium)
        .frame(width: Sizing.menuWidth)
        .environment(\.tintInk, model.prefs.controlInk.tintInk)
        .containerBackground(Tone.raised, for: .window)
    }

    private func state(of profile: ImpProfile) -> ImpPebble.State {
        guard let imp = model.imps.first(where: { $0.id == profile.id }) else { return .init(word: "menu.bar.state.home", symbol: ImpStateSymbol.home) }
        if model.isHidden || model.hiddenImps.contains(profile.id) { return .init(word: "menu.bar.state.hidden", symbol: ImpStateSymbol.hidden) }
        return imp.isReady ? .init(word: "menu.bar.state.out", symbol: ImpStateSymbol.out) : .init(word: "imp.state.asleep", symbol: ImpStateSymbol.asleep)
    }

    /// An Imp that is out is hidden or shown again. One at home opens in the app's window.
    private func choose(_ profile: ImpProfile) {
        guard model.imps.contains(where: { $0.id == profile.id }) else {
            HomeWindow.shared.show(model, imp: profile.id)
            return
        }
        let hidden = model.isHidden || model.hiddenImps.contains(profile.id)
        if model.isHidden { model.setHidden(false) } else { model.setHidden(profile.id, !hidden) }
    }

    private func run(_ action: () -> Void) {
        dismiss()
        action()
    }
}

/// One Imp in the panel: its face, its name and what it is doing, as a pebble.
struct ImpPebble: View {
    /// What it is doing, as a picture with its word for help and the screen reader.
    struct State {
        var word: LocalizedStringKey
        var symbol: String
    }

    let profile: ImpProfile
    let state: State
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Spacing.cozy) {
                ImpPortrait(face: MenuHeader.portrait(ready: true, hue: profile.hue), shadow: false)
                    .frame(width: Sizing.sheetIcon, height: Sizing.sheetIcon)
                Text(profile.name).font(Typeface.label).foregroundStyle(Tone.text).lineLimit(1)
                Spacer(minLength: Spacing.small)
                StateMark(state.word, symbol: state.symbol)
            }
            .padding(Spacing.snug)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(PebbleButtonStyle())
    }
}
