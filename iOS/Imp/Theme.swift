import ImpDesign
import ImpKit
import SwiftUI
import UIKit

// The phone's look is ImpDesign's: the same cosy, warm dungeon as the Mac's home window. What stays
// here needs the phone's own services (its energy budget, the keyboard).

/// The wall with a few embers floating up, like the Mac's stage.
struct DungeonBackdrop: View {
    var quiet = false
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            DungeonWall(floor: 0.32, floorStart: 0.65)
            if !quiet && !reduceMotion {
                TimelineView(Energy.shared.schedule(lively: false, paused: scenePhase != .active, fastest: 1 / 20)) { timeline in
                    Canvas { ctx, size in Self.embers(&ctx, size: size, t: timeline.date.timeIntervalSinceReferenceDate) }
                }
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    /// Embers drifting up; one in a while is a heart.
    static func embers(_ ctx: inout GraphicsContext, size: CGSize, t: Double) {
        for i in 0..<9 {
            let period = 11.0 + Double(i % 4) * 2.5
            let phase = (t / period + noise(i, 11)).truncatingRemainder(dividingBy: 1)
            let x = size.width * (0.08 + 0.84 * noise(i, 3)) + sin(t * 0.7 + Double(i)) * 14
            let y = size.height * (1.05 - phase * 1.15)
            let fade = sin(phase * .pi)
            let r = 1.6 + 2.2 * noise(i, 7)
            SoftLight.glow(&ctx, at: CGPoint(x: x, y: y), radius: r * 5, color: Dungeon.ember, opacity: 0.22 * fade)
            ctx.fill(Path(ellipseIn: CGRect(x: x - r / 2, y: y - r / 2, width: r, height: r)), with: .color(Dungeon.flame.opacity(0.7 * fade)))
        }
    }

    /// A stable pseudo-random 0…1 from two integers.
    static func noise(_ a: Int, _ b: Int) -> Double {
        var h = UInt64(truncatingIfNeeded: a) &* 0x9E37_79B9_7F4A_7C15 ^ UInt64(truncatingIfNeeded: b) &* 0xC2B2_AE3D_27D4_EB4F
        h ^= h >> 29; h = h &* 0xBF58_476D_1CE4_E5B9; h ^= h >> 32
        return Double(h % 10_000) / 10_000
    }
}

extension View {
    /// On a scrolling screen with a text field: dragging the content or tapping an empty part of it
    /// puts the keyboard away. Buttons, fields and menus inside take their own taps first.
    func dismissesKeyboard() -> some View {
        scrollDismissesKeyboard(.interactively)
            .onTapGesture {
                UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
            }
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
