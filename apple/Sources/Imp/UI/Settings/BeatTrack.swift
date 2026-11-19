import AppKit
import ImpDesign
import ImpKit
import SwiftUI

// MARK: - Timeline

/// The beats in a row, as long as they last, over a ruler in seconds. Click a beat to pick it, drag
/// it to move it, drag its right edge to change its length. Click the ruler to play from there.
struct BeatTrack: View {
    @Binding var beats: [AnimationBeat]
    @Binding var selected: Int
    let hue: Double
    let zoom: CGFloat
    let playing: Performance?
    let tempo: Double
    let copied: Bool
    let onPlay: (Double) -> Void
    let onAdd: () -> Void
    let onDuplicate: () -> Void
    let onSplit: () -> Void
    let onRemove: () -> Void
    let onCopy: () -> Void
    let onPaste: () -> Void

    /// A beat being dragged to a new place.
    struct Move: Equatable { var index: Int; var dx: CGFloat; var target: Int }
    /// A beat's edge being dragged.
    struct Resize: Equatable { var index: Int; var start: Double }
    @State private var moving: Move?
    @State private var resizing: Resize?
    /// How wide the track is, so a short animation fills it.
    @State private var room: CGFloat = 600
    @Environment(\.impTint) private var tint
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.stageAwake) private var awake

    static let gap = TrackLayout.gap
    static let minTile: CGFloat = 30
    // Timeline drawing geometry: the track is laid out in points per second, so these stay plain numbers.
    static let tileHeight: CGFloat = 58
    static let rulerHeight: CGFloat = 16
    /// Points per second: the whole animation fits the width at 1×, within reason.
    private var pps: CGFloat {
        let total = max(0.1, beats.reduce(0) { $0 + $1.duration })
        let fit = (room - 44 - Self.gap * CGFloat(beats.count)) / total
        return min(max(fit, 36), 220) * zoom
    }

    private var widths: [CGFloat] { beats.map { max(Self.minTile, $0.duration * pps) } }

    var body: some View {
        let ws = widths
        let xs = TrackLayout(durations: beats.map(\.duration), widths: ws).starts
        let end = (xs.last ?? 0) + (ws.last ?? 0)
        ScrollViewReader { scroller in
            ScrollView(.horizontal) {
                VStack(alignment: .leading, spacing: Spacing.tight) {
                    ruler(ws: ws, xs: xs, width: end)
                    ZStack(alignment: .topLeading) {
                        Color.clear.frame(width: end + Self.gap + 34, height: Self.tileHeight)
                        ForEach(beats.indices, id: \.self) { i in tile(i, ws: ws, xs: xs) }
                        let addAt = -(end + Self.gap)
                        addTile.alignmentGuide(.leading) { _ in addAt }
                        playhead(ws: ws, xs: xs)
                    }
                    .coordinateSpace(.named("track"))
                }
                .padding(.vertical, Spacing.hairline)
                .padding(.trailing, Spacing.tight)
            }
            .scrollIndicators(.automatic)
            .onChange(of: selected) { _, i in withImpAnimation(ImpDesign.Motion.smooth, reduceMotion: reduceMotion) { scroller.scrollTo(i) } }
        }
        .frame(height: Self.rulerHeight + Self.tileHeight + Spacing.medium)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { room = $0 }
    }

    // MARK: Ruler

    /// The track's x for a time in the animation (beats shorter than a tile still get a whole tile).
    private func x(at t: Double, ws: [CGFloat], xs: [CGFloat]) -> CGFloat {
        TrackLayout(durations: beats.map(\.duration), widths: ws).x(at: t)
    }

    /// The time at a point on the track.
    private func time(at x: CGFloat, ws: [CGFloat], xs: [CGFloat]) -> Double {
        TrackLayout(durations: beats.map(\.duration), widths: ws).time(at: x)
    }

    private func ruler(ws: [CGFloat], xs: [CGFloat], width: CGFloat) -> some View {
        let total = beats.reduce(0) { $0 + $1.duration }
        let step = pps < 50 ? 0.5 : pps > 140 ? 0.1 : 0.25
        return Canvas { ctx, size in
            var t = 0.0
            while t <= total + 0.0001 {
                let px = x(at: t, ws: ws, xs: xs)
                let whole = abs(t.rounded() - t) < 0.001
                let h: CGFloat = whole ? Spacing.small : Spacing.tight
                ctx.fill(Path(CGRect(x: px, y: size.height - h, width: Stroke.hairline, height: h)), with: .color(whole ? Tone.muted : Tone.faint))
                if whole {
                    ctx.draw(Text(verbatim: "\(Int(t.rounded())) s").font(Typeface.small.weight(.medium)).foregroundStyle(Tone.muted),
                             at: CGPoint(x: px + Spacing.tight, y: Stroke.hairline), anchor: .topLeading)
                }
                t += step
            }
        }
        .frame(width: width + 34, height: Self.rulerHeight)
        .contentShape(Rectangle())
        .onTapGesture { p in onPlay(time(at: p.x, ws: ws, xs: xs)) }
        .help("Click to play from there")
        .accessibilityElement()
        .accessibilityLabel("Ruler")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { onPlay(0) }
    }

    @ViewBuilder private func playhead(ws: [CGFloat], xs: [CGFloat]) -> some View {
        if let playing {
            TimelineView(.animation(minimumInterval: Energy.shared.interval(fps: 30), paused: !awake)) { tl in
                let t = tl.date.timeIntervalSince(playing.started) * tempo
                Capsule().fill(tint).frame(width: Stroke.focus, height: Self.tileHeight + Spacing.snug)
                    .offset(x: x(at: t, ws: ws, xs: xs) - Stroke.hairline, y: -Spacing.tight)
            }
            .allowsHitTesting(false)
        }
    }

    // MARK: Beats

    /// Where beat `i` sits: while another is dragged, the others make room where it would land.
    private func place(_ i: Int, ws: [CGFloat], xs: [CGFloat]) -> CGFloat {
        guard let m = moving else { return xs[i] }
        if i == m.index { return xs[i] + m.dx }
        var order = Array(beats.indices)
        order.remove(at: m.index)
        order.insert(m.index, at: m.target)
        var x: CGFloat = 0
        for j in order {
            if j == i { return x }
            x += ws[j] + Self.gap
        }
        return xs[i]
    }

    private func tile(_ i: Int, ws: [CGFloat], xs: [CGFloat]) -> some View {
        let dragged = moving?.index == i
        let x = place(i, ws: ws, xs: xs)
        return BeatTile(beat: beats[i], index: i, picked: i == selected, hue: hue, width: ws[i],
                        resizing: resizing?.index == i)
            .overlay(alignment: .trailing) { edge(i) }
            .scaleEffect(dragged ? 1.04 : 1)
            .shadow(color: dragged ? Elevation.cardColor : .clear, radius: Spacing.snug, y: Spacing.hairline)
            .zIndex(dragged ? 2 : 0)
            .alignmentGuide(.leading) { _ in -x }
            .impAnimation(ImpDesign.Motion.expand, value: dragged ? nil : moving?.target)
            .id(i)
            .onTapGesture { withImpAnimation(ImpDesign.Motion.press, reduceMotion: reduceMotion) { selected = i } }
            .gesture(DragGesture(minimumDistance: 4, coordinateSpace: .named("track"))
                .onChanged { g in
                    if moving == nil { selected = i }
                    let center = xs[i] + ws[i] / 2 + g.translation.width
                    let target = beats.indices.filter { $0 != i && xs[$0] + ws[$0] / 2 < center }.count
                    moving = Move(index: i, dx: g.translation.width, target: target)
                }
                .onEnded { _ in
                    guard let m = moving else { return }
                    moving = nil
                    guard m.target != m.index else { return }
                    let b = beats.remove(at: m.index)
                    beats.insert(b, at: m.target)
                    selected = m.target
                })
            .contextMenu {
                Section {
                    Button("Duplicate") { selected = i; onDuplicate() }
                    Button("Split in Two") { selected = i; onSplit() }
                    Button("Add a Beat After") { selected = i; onAdd() }
                }
                Section {
                    Button("Copy Pose") { selected = i; onCopy() }
                    Button("Paste Pose") { selected = i; onPaste() }.disabled(!copied)
                }
                Button("common.remove", role: .destructive) { selected = i; onRemove() }.disabled(beats.count <= 1)
            }
    }

    /// The right edge of a beat: drag it to change how long the beat lasts.
    private func edge(_ i: Int) -> some View {
        EdgeHandle(active: resizing?.index == i || i == selected)
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .named("track"))
                .onChanged { g in
                    guard beats.indices.contains(i) else { return }
                    if resizing == nil { resizing = Resize(index: i, start: beats[i].duration); selected = i }
                    let fine = NSEvent.modifierFlags.contains(.option)
                    let step = fine ? 0.01 : 0.05
                    let raw = (resizing?.start ?? beats[i].duration) + Double(g.translation.width / pps)
                    let d = min(max((raw / step).rounded() * step, AnimationBeat.durationRange.lowerBound), AnimationBeat.durationRange.upperBound)
                    if abs(beats[i].duration - d) > 0.0001 { beats[i].duration = AnimationBeat.round(d) }
                }
                .onEnded { _ in resizing = nil })
    }

    private var addTile: some View {
        Button(action: onAdd) {
            Image(systemName: "plus").font(.icon(.large, weight: .semibold)).foregroundStyle(Tone.muted)
                .frame(width: Self.minTile, height: Self.tileHeight)
                .background(RoundedRectangle(cornerRadius: Radius.tile, style: .continuous).fill(Tone.card))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(beats.count >= MadeAnimation.maxBeats)
        .help("Add a beat after this one")
    }
}

/// The grip on a beat's right edge.
struct EdgeHandle: View {
    let active: Bool
    @State private var hover = false
    @Environment(\.impTint) private var tint

    var body: some View {
        Rectangle().fill(Color.clear)
            .frame(width: Spacing.cozy)
            .overlay {
                Capsule().fill(hover ? Tone.text : (active ? tint : Tone.line))
                    .frame(width: Spacing.tight, height: Spacing.wide)
                    .opacity(hover || active ? 1 : Opacity.dimmed)
            }
            .contentShape(Rectangle())
            .onHover { hover = $0 }
            .cursor(.resizeLeftRight)
            .help("Drag to make the beat longer or shorter (⌥ for finer steps)")
            .accessibilityHidden(true)
    }
}

/// One beat on the timeline: its face, its move, symbol and hop if it has them, and how long it holds.
struct BeatTile: View {
    let beat: AnimationBeat
    let index: Int
    let picked: Bool
    let hue: Double
    let width: CGFloat
    var resizing = false
    @Environment(\.impTint) private var tint

    var body: some View {
        VStack(spacing: Spacing.hairline) {
            HStack(spacing: Spacing.hairline) {
                Text(verbatim: "\(index + 1)").font(Typeface.small.weight(.bold))
                    .foregroundStyle(Tone.muted)
                Spacer(minLength: 0)
                if width >= 44 {
                    if let m = beat.move { Image(systemName: MovePicker.symbol(m)).font(.icon(.tiny, weight: .bold)) }
                    if beat.hop { Image(systemName: "arrow.up").font(.icon(.tiny, weight: .black)) }
                    if let g = beat.glyph { Image(systemName: GlyphPicker.symbol(g)).font(.icon(.tiny, weight: .bold)) }
                }
            }
            .foregroundStyle(Tone.text)
            .padding(.horizontal, Spacing.snug).padding(.top, Spacing.tight)
            .frame(height: Spacing.roomy)
            ImpPortrait(face: face, shadow: false).frame(width: min(Sizing.glyph, width - Spacing.snug), height: Sizing.glyph)
            Text(verbatim: width >= 40 ? String(format: "%.2g s", beat.duration) : String(format: "%.1f", beat.duration))
                .font(Typeface.small.weight(.semibold).monospacedDigit())
                .foregroundStyle(picked || resizing ? Tone.text : Tone.muted)
                .lineLimit(1)
        }
        .frame(width: width, height: BeatTrack.tileHeight)
        .background(RoundedRectangle(cornerRadius: Radius.tile, style: .continuous).fill(picked ? AnyShapeStyle(tint.opacity(Opacity.tintFillStrong)) : AnyShapeStyle(Tone.card)))
        .contentShape(Rectangle())
        .accessibilityElement()
        .accessibilityLabel(Text("Beat \(index + 1)"))
        .accessibilityValue(Text(verbatim: [beat.mood.flatMap(Mood.init(rawValue:))?.title, beat.move.map(MovePicker.title),
                                            String(format: "%.2f s", beat.duration)].compactMap { $0 }.joined(separator: ", ")))
        .accessibilityAddTraits(picked ? [.isButton, .isSelected] : .isButton)
    }

    private var face: Face {
        var f = Face.settled(beat.mood.flatMap(Mood.init(rawValue:)) ?? .idle, lookX: beat.lookX ?? 0, lookY: beat.lookY ?? 0)
        f.hue = hue
        f.tilt += beat.tilt
        f.headH *= 1 + beat.stretch
        f.headW *= 1 - beat.stretch * 0.6
        return f
    }
}
