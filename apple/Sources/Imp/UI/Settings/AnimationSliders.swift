import ImpDesign
import ImpKit
import SwiftUI

/// A slider and its value, for a tight row. Double-click puts it back to 0.
struct CompactSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    var format: (Double) -> String

    var body: some View {
        HStack(spacing: Spacing.snug) {
            Slider(value: $value, in: range).impSlider()
            Text(verbatim: format(value)).font(Typeface.small.weight(.medium).monospacedDigit())
                .frame(width: Sizing.hit * 1.5, alignment: .trailing)
        }
        .onTapGesture(count: 2) { value = min(max(0, range.lowerBound), range.upperBound) }
    }
}

extension Mood {
    /// Its name, for people.
    var title: String {
        switch self {
        case .idle: String(localized: "Calm")
        case .listening: String(localized: "Listening")
        case .thinking: String(localized: "Thinking")
        case .happy: String(localized: "Happy")
        case .love: String(localized: "In love")
        case .sad: String(localized: "Sad")
        case .error: String(localized: "Wincing")
        case .sleepy: String(localized: "Sleepy")
        case .annoyed: String(localized: "Annoyed")
        case .surprised: String(localized: "Surprised")
        case .dizzy: String(localized: "Dizzy")
        case .mean: String(localized: "Unimpressed")
        case .working: String(localized: "Busy")
        case .content: String(localized: "Content")
        case .giggly: String(localized: "Giggly")
        case .scared: String(localized: "Scared")
        case .curious: String(localized: "Curious")
        case .shy: String(localized: "Shy")
        case .excited: String(localized: "Excited")
        case .bored: String(localized: "Bored")
        }
    }
}
