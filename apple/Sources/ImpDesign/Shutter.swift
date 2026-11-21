import SwiftUI

/// The camera's shutter: a white disc in a white ring, drawn over the picture it takes. It is a
/// drawing of a camera button, so it keeps its outline and its fixed colours on any picture.
public struct ShutterButton: View {
    let action: () -> Void

    public init(action: @escaping () -> Void) {
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            ZStack {
                Circle().strokeBorder(Tone.paper, lineWidth: Spacing.tight)
                Circle().fill(Tone.paper).padding(Spacing.snug + Spacing.hairline)
            }
            .frame(width: Sizing.shutter, height: Sizing.shutter)
            .padding(Spacing.tight)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Take the photo"))
    }
}
