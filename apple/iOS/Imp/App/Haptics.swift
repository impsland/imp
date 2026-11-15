import SwiftUI
import UIKit

/// Every tap the phone gives in the hand goes through here, so one switch (Settings › App › Haptics) turns them all
/// off. What earns a tap: a pick (a size step, a colour, a character), an Imp leaving for another device or landing
/// here, a result (a Brain that works, an answer) and touching an Imp. Nothing taps while you only look.
@MainActor
enum Haptics {
    /// Whether haptics are on (`AppStorage` key). On until switched off.
    static let enabledKey = "haptics"

    static var isOn: Bool { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }

    /// A light tap for something done: sent, picked up, landed.
    static func tap(_ style: UIImpactFeedbackGenerator.FeedbackStyle = .light, intensity: CGFloat = 1) {
        guard isOn else { return }
        UIImpactFeedbackGenerator(style: style).impactOccurred(intensity: intensity)
    }

    /// A tick for a pick that changed: a step of a slider, a swatch, a door.
    static func selection() {
        guard isOn else { return }
        UISelectionFeedbackGenerator().selectionChanged()
    }

    /// How something came out.
    static func notify(_ type: UINotificationFeedbackGenerator.FeedbackType) {
        guard isOn else { return }
        UINotificationFeedbackGenerator().notificationOccurred(type)
    }
}

/// `UIImpactFeedbackGenerator`, silent while haptics are off. For places that prepare a generator ahead (games).
@MainActor
final class HapticImpact {
    private let generator: UIImpactFeedbackGenerator
    init(style: UIImpactFeedbackGenerator.FeedbackStyle) { generator = UIImpactFeedbackGenerator(style: style) }
    func prepare() { if Haptics.isOn { generator.prepare() } }
    func impactOccurred(intensity: CGFloat = 1) { if Haptics.isOn { generator.impactOccurred(intensity: intensity) } }
}

/// `UINotificationFeedbackGenerator`, silent while haptics are off.
@MainActor
final class HapticNotice {
    private let generator = UINotificationFeedbackGenerator()
    func prepare() { if Haptics.isOn { generator.prepare() } }
    func notificationOccurred(_ type: UINotificationFeedbackGenerator.FeedbackType) { if Haptics.isOn { generator.notificationOccurred(type) } }
}

/// `UISelectionFeedbackGenerator`, silent while haptics are off.
@MainActor
final class HapticSelection {
    private let generator = UISelectionFeedbackGenerator()
    func prepare() { if Haptics.isOn { generator.prepare() } }
    func selectionChanged() { if Haptics.isOn { generator.selectionChanged() } }
}

extension View {
    /// A tick each time `value` changes, while haptics are on: for discrete picks (a slider's steps, swatches).
    func selectionHaptic<V: Equatable>(_ value: V) -> some View {
        sensoryFeedback(trigger: value) { _, _ in Haptics.isOn ? .selection : nil }
    }
}
