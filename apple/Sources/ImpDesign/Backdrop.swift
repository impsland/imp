import SwiftUI

/// The one surface every screen, sheet and panel sits on: a single flat colour, with no texture,
/// gradient or motion. Whatever is shown on it is grouped with soft fills, never with lines.
public struct Backdrop: View {
    public init() {}

    public var body: some View {
        Tone.surface
            .ignoresSafeArea()
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}
