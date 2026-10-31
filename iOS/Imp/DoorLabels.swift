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
                    Text("Nobody here")
                        .font(.system(.footnote, design: .rounded, weight: .medium))
                        .foregroundStyle(Dungeon.cream.opacity(0.5))
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(.black.opacity(0.2), in: Capsule())
                        .frame(maxHeight: .infinity)
                }
                ForEach(doors) { door in
                    band(door, side: near.side, lit: engine.litDoor == door.id)
                        .frame(height: (door.bottom - door.top) * height)
                        .offset(y: door.top * height)
                }
            }
            .frame(width: engine.size.width, height: height, alignment: near.side == .left ? .leading : .trailing)
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
            .fill(lit ? Dungeon.flame : Dungeon.ember.opacity(0.4))
            .frame(width: lit ? 5 : 3)
            .padding(.vertical, 6)
        let label = HStack(spacing: 5) {
            Image(systemName: door.isBack ? "arrow.uturn.backward" : door.device.kind == .mac ? "macbook" : "iphone")
                .font(.system(size: 11, weight: .semibold))
            Text(door.isBack ? String(localized: "Back to \(door.device.name)") : door.device.name)
                .font(.system(.footnote, design: .rounded, weight: .semibold))
                .lineLimit(1)
        }
        .foregroundStyle(lit ? Dungeon.deep : Dungeon.cream)
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(lit ? Dungeon.flame : Color.black.opacity(0.35), in: Capsule())
        .frame(maxWidth: 150, alignment: side == .left ? .leading : .trailing)
        .scaleEffect(lit && !engine.reduceMotion ? 1.06 : 1, anchor: side == .left ? .leading : .trailing)
        return HStack(spacing: 6) {
            if side == .left { strip; label } else { label; strip }
        }
    }
}
