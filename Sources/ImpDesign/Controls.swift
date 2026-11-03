import SwiftUI

private struct ImpControls: ViewModifier {
    var tint: Color?
    @Environment(\.impTint) private var inherited

    func body(content: Content) -> some View {
        let color = tint ?? inherited
        content
            .environment(\.impTint, color)
            .tint(color)
            .buttonStyle(.secondary)
            .toggleStyle(.impSwitch)
    }
}

extension View {
    /// Dresses the standard controls in this screen in the app's look: buttons become
    /// `.secondary` pills, toggles become the Imp switch, and sliders, links and progress follow
    /// the Imp's colour. Pass `tint` to colour the screen after an Imp, otherwise it keeps the
    /// colour set above it. Individual controls still choose their own `.buttonStyle(...)`,
    /// and text fields and sliders opt in with `.impField()` and `.impSlider()`.
    public func impControls(tint: Color? = nil) -> some View {
        modifier(ImpControls(tint: tint))
    }
}
