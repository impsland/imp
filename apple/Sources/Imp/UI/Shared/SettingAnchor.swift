import ImpDesign
import ImpKit
import SwiftUI

extension EnvironmentValues {
    /// The setting that something (a chat, a link) has just opened, while it is lit. Nil otherwise.
    @Entry var highlightedSetting: SettingID?
}

extension View {
    /// Marks the row or card of one setting: a page can scroll to it, and it is lit for a moment when
    /// something opened exactly this setting.
    func settingAnchor(_ id: SettingID) -> some View { modifier(SettingAnchor(id: id)) }

    /// On a scroll view's content: scrolls to the lit setting, also when the page has only just appeared.
    func scrollsToHighlightedSetting(_ proxy: ScrollViewProxy) -> some View { modifier(ScrollToSetting(proxy: proxy)) }
}

private struct SettingAnchor: ViewModifier {
    let id: SettingID
    @Environment(\.highlightedSetting) private var highlighted
    @Environment(\.impTint) private var tint

    func body(content: Content) -> some View {
        let lit = highlighted == id
        content
            .id(id)
            .background {
                RoundedRectangle(cornerRadius: Radius.medium, style: .continuous)
                    .fill(tint.opacity(lit ? Opacity.tintFill : 0))
                    .padding(-Spacing.tight)
                    .allowsHitTesting(false)
            }
            .impAnimation(ImpDesign.Motion.fade, value: lit)
    }
}

private struct ScrollToSetting: ViewModifier {
    let proxy: ScrollViewProxy
    @Environment(\.highlightedSetting) private var highlighted
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.task(id: highlighted) {
            guard let highlighted else { return }
            // The page may only just have been built: let it lay out first.
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            withImpAnimation(ImpDesign.Motion.settle, reduceMotion: reduceMotion) { proxy.scrollTo(highlighted, anchor: .center) }
        }
    }
}
