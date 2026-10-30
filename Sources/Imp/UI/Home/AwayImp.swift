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
                let w = side * 0.56, h = side * 0.92
                ZStack {
                    // The phone's glow, in the Imp's colour.
                    Ellipse().fill(Color.imp(hue).opacity(connected ? 0.35 : 0.15))
                        .frame(width: w * 1.5, height: h * 0.5).blur(radius: 18).offset(y: h * 0.3)
                    RoundedRectangle(cornerRadius: w * 0.2, style: .continuous)
                        .fill(LinearGradient(colors: [Color(white: 0.16), Color(white: 0.07)], startPoint: .top, endPoint: .bottom))
                        .overlay(RoundedRectangle(cornerRadius: w * 0.2, style: .continuous).strokeBorder(Color.white.opacity(0.22), lineWidth: 1.5))
                    // Its screen, with the Imp peeking up out of it.
                    let screen = RoundedRectangle(cornerRadius: w * 0.15, style: .continuous)
                    screen
                        .fill(LinearGradient(colors: [Dungeon.wallTop, Dungeon.wallBottom], startPoint: .top, endPoint: .bottom))
                        .overlay(alignment: .bottom) {
                            ImpPortrait(face: face, shadow: false)
                                .frame(width: w * 1.05, height: w * 1.05)
                                .offset(y: w * 0.12 + CGFloat(sin(t * 1.8)) * 2)
                        }
                        .clipShape(screen)
                        .padding(w * 0.06)
                    Capsule().fill(Color.black).frame(width: w * 0.3, height: w * 0.07).offset(y: -h / 2 + w * 0.12)
                }
                .frame(width: w, height: h)
                .rotationEffect(.degrees(sin(t * 0.9) * 3))
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
