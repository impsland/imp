import ImpDesign
import ImpKit
import SwiftUI
import UIKit

// The phone's look is ImpDesign's, the same as the Mac's. What stays here needs the phone's own
// services (the keyboard).

extension View {
    /// On a scrolling screen with a text field: dragging the content or tapping an empty part of it
    /// puts the keyboard away. Buttons, fields and menus inside take their own taps first.
    func dismissesKeyboard() -> some View {
        scrollDismissesKeyboard(.interactively)
            .onTapGesture {
                UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
            }
    }

    /// Where the bar of every sheet sits (Back, title, Close): the same distance from the sheet's top
    /// and sides everywhere, so Close is always under the same thumb.
    func sheetBarInsets() -> some View {
        padding(.horizontal, Spacing.medium).padding(.top, Spacing.medium)
    }

    /// On a form: the field being typed in rests `gap` above the keyboard, not right on it. While the
    /// keyboard is up, the safe area ends that much higher, and SwiftUI scrolls the focused field
    /// inside the safe area as usual.
    func keyboardGap(_ gap: CGFloat = Spacing.huge) -> some View {
        modifier(KeyboardGap(gap: gap))
    }
}

private struct KeyboardGap: ViewModifier {
    let gap: CGFloat
    @State private var keyboardUp = false

    func body(content: Content) -> some View {
        content
            .safeAreaPadding(.bottom, keyboardUp ? gap : 0)
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in keyboardUp = true }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in keyboardUp = false }
    }
}

/// A control under its small title, with the help icon after the title when there is one.
struct Titled<Content: View>: View {
    let title: LocalizedStringKey
    var tip: InfoTip?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.tight) {
            HStack(spacing: 0) {
                Text(title).font(Typeface.caption).foregroundStyle(Tone.muted)
                    .accessibilityAddTraits(.isHeader)
                // The help icon keeps its finger-sized target but not its height in the form.
                if let tip { tip.padding(.vertical, -Spacing.cozy) }
            }
            content
        }
    }
}
