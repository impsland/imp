import ImpKit
import SwiftUI

/// An Imp that's out on an iPhone, as it shows on its pedestal: a little phone with the Imp
/// peeking out of its screen, glowing in its colour. So the window explains why it isn't on the
/// desktop (and a click brings it back).
struct AwayImp: View {
    let hue: Double
    /// The phone it's on, if known.
    var phone: String?
    /// The phone is around: the Imp is awake on it (else it dozes).
    var connected: Bool
    var still = false
    @Environment(\.stageAwake) private var awake

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: still || !awake)) { timeline in
            let t = still ? 0 : timeline.date.timeIntervalSinceReferenceDate
            GeometryReader { geo in
                let side = min(geo.size.width, geo.size.height)
                // A real iPhone's shape (about 1 : 2.05), as tall as the Imp's own frame.
                let w = side * 0.55, h = w * 2.05
                let body = RoundedRectangle(cornerRadius: w * 0.24, style: .continuous)
                let screen = RoundedRectangle(cornerRadius: w * 0.19, style: .continuous)
                ZStack {
                    // The frame: brushed metal, lit from above.
                    body.fill(LinearGradient(colors: [Color(white: 0.36), Color(white: 0.16), Color(white: 0.24)],
                                             startPoint: .topLeading, endPoint: .bottomTrailing))
                        .overlay(body.strokeBorder(Color.white.opacity(0.28), lineWidth: 1))
                        .shadow(color: .black.opacity(0.45), radius: 8, y: 5)
                    // Its screen, with the Imp peeking up out of it.
                    screen
                        .fill(LinearGradient(colors: [Dungeon.wallTop, Dungeon.wallBottom], startPoint: .top, endPoint: .bottom))
                        .overlay(alignment: .bottom) {
                            ImpPortrait(face: face, shadow: false)
                                .frame(width: w * 1.15, height: w * 1.15)
                                .offset(y: w * 0.08 + CGFloat(sin(t * 1.8)) * 2)
                        }
                        // A soft glare across the glass.
                        .overlay(LinearGradient(colors: [.white.opacity(0.13), .clear, .clear], startPoint: .topLeading, endPoint: .bottomTrailing))
                        .clipShape(screen)
                        .padding(w * 0.055)
                    // The Dynamic Island and the home indicator.
                    Capsule().fill(Color.black).frame(width: w * 0.3, height: w * 0.085).offset(y: -h / 2 + w * 0.13)
                    Capsule().fill(Color.white.opacity(0.35)).frame(width: w * 0.32, height: w * 0.025).offset(y: h / 2 - w * 0.09)
                }
                .frame(width: w, height: h)
                // Side buttons: volume on the left, power on the right.
                .background(alignment: .leading) {
                    VStack(spacing: w * 0.07) {
                        Capsule().frame(width: w * 0.05, height: w * 0.2)
                        Capsule().frame(width: w * 0.05, height: w * 0.2)
                    }
                    .foregroundStyle(Color(white: 0.3))
                    .offset(x: -w * 0.03, y: -h * 0.2)
                }
                .background(alignment: .trailing) {
                    Capsule().fill(Color(white: 0.3)).frame(width: w * 0.05, height: w * 0.3).offset(x: w * 0.03, y: -h * 0.16)
                }
                // The phone's glow, in the Imp's colour.
                .background {
                    Ellipse().fill(Color.imp(hue).opacity(connected ? 0.4 : 0.15))
                        .frame(width: w * 1.7, height: h * 0.45).blur(radius: 18).offset(y: h * 0.32)
                }
                .rotationEffect(.degrees(sin(t * 0.9) * 3), anchor: .bottom)
                .offset(y: CGFloat(sin(t * 1.3)) * 3)
                .position(x: geo.size.width / 2, y: geo.size.height - h / 2)
            }
        }
        .help(phone.map { String(localized: "On \($0). Click to call it back to your desktop.") }
              ?? String(localized: "On your iPhone. Click to call it back to your desktop."))
    }

    private var face: Face {
        var f = impFace(hue: hue, mood: connected ? .happy : .sleepy)
        f.lookY = 0.2
        return f
    }
}
