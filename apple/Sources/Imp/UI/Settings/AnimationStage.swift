import AppKit
import ImpDesign
import ImpKit
import SwiftUI

/// The stage: the Imp acting it out, and the place to turn its face. Drag anywhere on it and the
/// face turns there (a dashed line shows where it looks); double-click to have it look at you.
struct LookStage: View {
    let hue: Double
    let traits: ImpTraits
    let performance: Performance?
    /// The beat being edited (nil while the whole animation plays).
    let beat: AnimationBeat?
    let onLook: (Double, Double) -> Void
    @State private var hovering = false
    @Environment(\.impTint) private var tint

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            // Where its face is: the look is aimed from there.
            let center = CGPoint(x: size.width / 2, y: size.height / 2 + 22)
            let reach = CGSize(width: size.width / 2 - 18, height: size.height / 2 - 18)
            ZStack {
                StageImp(hue: hue, performance: performance, traits: traits)
                    .frame(width: Sizing.column / 4, height: Sizing.column / 4)
                    .position(x: size.width / 2, y: size.height / 2 + 10)
                    .allowsHitTesting(false)
                if let beat, beat.hasLook || hovering {
                    guide(size: size, center: center, reach: reach, beat: beat)
                }
                if beat != nil, hovering, beat?.hasLook == false {
                    Text("Drag to turn its face").font(Typeface.small.weight(.medium)).foregroundStyle(Tone.paper)
                        .padding(.horizontal, Spacing.small).padding(.vertical, Spacing.tight)
                        .background(Capsule().fill(Tone.scrim))
                        .position(x: size.width / 2, y: Spacing.roomy)
                }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                guard beat != nil else { return }
                let x = (g.location.x - center.x) / reach.width, y = (g.location.y - center.y) / reach.height
                onLook(AnimationBeat.round(max(-1, min(1, Double(x)))), AnimationBeat.round(max(-1, min(1, Double(y)))))
            })
            .simultaneousGesture(TapGesture(count: 2).onEnded { if beat != nil { onLook(0, 0.1) } })
            .onHover { inside in
                hovering = inside
                if inside { NSCursor.crosshair.push() } else { NSCursor.pop() }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Preview. Where it looks")
        .accessibilityValue(beat.map { $0.hasLook ? Text(verbatim: String(format: "%.1f, %.1f", $0.lookX ?? 0, $0.lookY ?? 0)) : Text("Follows the cursor") } ?? Text(verbatim: ""))
        .accessibilityAdjustableAction { dir in
            guard let beat else { return }
            onLook(beat.lookX ?? 0, max(-1, min(1, (beat.lookY ?? 0) + (dir == .increment ? -0.1 : 0.1))))
        }
    }

    /// A faint crosshair, where you are (just below the middle), and a dashed line to where it looks.
    private func guide(size: CGSize, center: CGPoint, reach: CGSize, beat: AnimationBeat) -> some View {
        let target = CGPoint(x: center.x + CGFloat(beat.lookX ?? 0) * reach.width, y: center.y + CGFloat(beat.lookY ?? 0) * reach.height)
        let you = CGPoint(x: center.x, y: center.y + 0.1 * reach.height)
        return ZStack {
            Path { p in
                p.move(to: CGPoint(x: center.x, y: 8)); p.addLine(to: CGPoint(x: center.x, y: size.height - 8))
                p.move(to: CGPoint(x: 8, y: center.y)); p.addLine(to: CGPoint(x: size.width - 8, y: center.y))
            }
            .stroke(Tone.card, style: StrokeStyle(lineWidth: Stroke.hairline, dash: [Spacing.tight, Spacing.tight]))
            Circle().strokeBorder(Tone.muted, lineWidth: Stroke.hairline).frame(width: Spacing.cozy, height: Spacing.cozy).position(you)
            if beat.hasLook {
                Path { p in p.move(to: center); p.addLine(to: target) }
                    .stroke(tint.opacity(Opacity.dimmed), style: StrokeStyle(lineWidth: Stroke.focus, lineCap: .round, dash: [Spacing.tight, Spacing.tight]))
                Circle().fill(tint).frame(width: Spacing.roomy, height: Spacing.roomy)
                    .overlay(Circle().strokeBorder(Tone.paper, lineWidth: Stroke.focus))
                    .shadow(color: Tone.scrim, radius: Spacing.hairline)
                    .position(target)
            }
        }
        .allowsHitTesting(false)
    }
}
