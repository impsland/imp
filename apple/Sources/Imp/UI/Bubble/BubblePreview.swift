import ImpDesign
import ImpKit
import SwiftUI

/// A small bubble over a light, a dark and a busy background, so the Settings card shows what the
/// chosen look does without leaving Settings. The real bubble also blurs what is behind it; here the
/// swatches are plain, so only the fill and its amount show.
struct BubblePreview: View {
    let appearance: BubbleAppearance

    var body: some View {
        ZStack {
            HStack(spacing: 0) {
                Tone.paper
                Tone.ink
                busy
            }
            HStack(spacing: Spacing.small) {
                ForEach(0..<3, id: \.self) { _ in sample }
            }
            .padding(.horizontal, Spacing.small)
        }
        .frame(height: Sizing.hit * 2)
        .clipShape(RoundedRectangle(cornerRadius: Radius.medium, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("settings.bubble.preview.label"))
    }

    private var busy: some View {
        HStack(spacing: 0) {
            ForEach([0.02, 0.35, 0.62, 0.85], id: \.self) { Color.imp($0) }
        }
            .overlay(Image(systemName: "photo.fill").font(.icon(.huge)).foregroundStyle(Tone.paper.opacity(Opacity.tintFillStrong)))
    }

    private var sample: some View {
        Text(verbatim: "Aa")
            .font(Typeface.body)
            .foregroundStyle(Tone.text)
            .frame(maxWidth: .infinity, minHeight: Sizing.hit)
            .background(BubbleSurface(cornerRadius: Radius.medium, blursWindowContent: true))
            .environment(\.bubbleAppearance, appearance)
    }
}
