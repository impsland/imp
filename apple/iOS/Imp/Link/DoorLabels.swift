import ImpDesign
import ImpKit
import SwiftUI

/// While an Imp is carried towards an edge, the doors on that side: one band per device at the heights
/// that lead to it, labelled with its name. The band under the finger lights up. A side that leads
/// nowhere says so, faintly. It sits inside the stage's timeline, so it follows the finger for free.
struct DoorLabels: View {
    let engine: StageEngine

    var body: some View {
        if let carried = engine.carried {
            let near = engine.nearness(of: carried)
            // With reduced motion the labels are there or not, without fading in step by step.
            let shown = engine.reduceMotion ? (near.amount > 0 ? 1 : 0) : near.amount
            let doors = engine.doors(carried.imp.id, near.side)
            let height = engine.size.height
            ZStack(alignment: near.side == .left ? .topLeading : .topTrailing) {
                if doors.isEmpty {
                    Text("phone.stage.nobody")
                        .font(Typeface.caption)
                        .foregroundStyle(Tone.paper.opacity(0.5))
                        .padding(.horizontal, Spacing.cozy).padding(.vertical, Spacing.snug)
                        .background(Tone.scrim, in: Capsule())
                        .frame(maxHeight: .infinity)
                }
                ForEach(doors) { door in
                    band(door, side: near.side, lit: engine.litDoor == door.id)
                        .frame(height: (door.bottom - door.top) * height)
                        .offset(y: door.top * height)
                }
            }
            .frame(width: engine.size.width, height: height, alignment: near.side == .left ? .topLeading : .topTrailing)
            .opacity(shown)
            .animation(engine.reduceMotion ? nil : .easeOut(duration: 0.15), value: engine.litDoor)
            .allowsHitTesting(false)
            // The "Send to" items of the Imp's menu offer the same choices.
            .accessibilityHidden(true)
        }
    }

    /// One device's band: a thin strip down the edge and its name beside it.
    private func band(_ door: LinkHub.DoorLabel, side: LinkSide, lit: Bool) -> some View {
        let strip = Capsule()
            .fill(lit ? Tone.accent : Tone.paper.opacity(0.4))
            .frame(width: lit ? 5 : 3)
            .padding(.vertical, Spacing.snug)
        let label = HStack(spacing: Spacing.snug) {
            Image(systemName: door.isBack ? "arrow.uturn.backward" : door.device.kind == .mac ? "macbook" : "iphone")
                .font(.icon(.medium, weight: .semibold))
            Text(door.isBack ? words("phone.stage.back_to", door.device.name) : door.device.name)
                .font(Typeface.caption)
                .lineLimit(2).truncationMode(.middle)
        }
        .foregroundStyle(lit ? Tone.onAccent : Tone.paper)
        .padding(.horizontal, Spacing.cozy).padding(.vertical, Spacing.snug)
        .background(lit ? Tone.accent : Tone.scrim, in: Capsule())
        .frame(maxWidth: Sizing.doorLabel, alignment: side == .left ? .leading : .trailing)
        .scaleEffect(lit && !engine.reduceMotion ? 1.06 : 1, anchor: side == .left ? .leading : .trailing)
        return HStack(spacing: Spacing.snug) {
            if side == .left { strip; label } else { label; strip }
        }
    }
}
