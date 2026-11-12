import AppKit
import ImpDesign
import ImpKit
import SwiftUI

// MARK: - Pickers

/// Every mood as a little face to pick from.
struct MoodPicker: View {
    @Binding var mood: String?
    let hue: Double
    @Environment(\.impTint) private var tint

    var body: some View {
        EvenGrid(minWidth: Sizing.glyph, spacing: Spacing.tight) {
            tile(nil)
            ForEach(AnimationBeat.moods, id: \.self) { tile($0) }
        }
    }

    private func tile(_ name: String?) -> some View {
        let picked = mood == name
        let m = name.flatMap(Mood.init(rawValue:))
        return Button { mood = name } label: {
            ZStack {
                if let m {
                    ImpPortrait(face: { var f = Face.settled(m); f.hue = hue; return f }(), shadow: false).padding(Spacing.tight)
                } else {
                    Image(systemName: "circle.dashed").font(.icon(.large, weight: .medium)).foregroundStyle(Tone.muted)
                }
            }
            .frame(maxWidth: .infinity).frame(height: Sizing.glyph)
            .background(RoundedRectangle(cornerRadius: Radius.small, style: .continuous).fill(picked ? AnyShapeStyle(tint.opacity(Opacity.tintFillStrong)) : AnyShapeStyle(Tone.card)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(m?.title ?? String(localized: "Keep: whatever it feels anyway"))
        .accessibilityLabel(m?.title ?? String(localized: "Keep its mood"))
        .accessibilityAddTraits(picked ? .isSelected : [])
    }
}

/// The moves a beat can play across its length, how many times, and which way.
struct MovePicker: View {
    @Binding var beat: AnimationBeat
    let replay: () -> Void
    @Environment(\.impTint) private var tint

    static func symbol(_ m: String) -> String {
        switch m {
        case "spin": "rotate.3d"
        case "flip": "figure.gymnastics"
        case "roll": "arrow.clockwise"
        case "bounce": "arrow.up.and.down"
        case "shake": "arrow.left.and.right"
        case "sway": "metronome.fill"
        case "wobble": "waveform.path"
        case "float": "cloud.fill"
        case "nod": "checkmark"
        case "headshake": "xmark"
        default: "circle"
        }
    }

    static func title(_ m: String) -> String {
        switch m {
        case "spin": String(localized: "Spin round its own axis")
        case "flip": String(localized: "Somersault")
        case "roll": String(localized: "Cartwheel")
        case "bounce": String(localized: "Bounce")
        case "shake": String(localized: "Shake")
        case "sway": String(localized: "Sway")
        case "wobble": String(localized: "Wobble like jelly")
        case "float": String(localized: "Float up")
        case "nod": String(localized: "Nod")
        case "headshake": String(localized: "Shake its head")
        default: m
        }
    }

    /// What one "time" is for this move.
    static func unit(_ m: String, _ n: Int) -> String {
        switch m {
        case "spin", "flip", "roll": String(localized: "\(n) turns")
        case "bounce": String(localized: "\(n) bounces")
        case "nod": String(localized: "\(n) nods")
        default: String(localized: "\(n) times")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.snug) {
            HStack(spacing: Spacing.tight) {
                chip(nil)
                ForEach(AnimationBeat.moves, id: \.self) { chip($0) }
            }
            if let m = beat.move {
                HStack(spacing: Spacing.small) {
                    Text(verbatim: Self.title(m)).font(Typeface.small.weight(.medium)).foregroundStyle(Tone.text).lineLimit(1)
                    Spacer(minLength: Spacing.tight)
                    ImpStepper(value: Binding(get: { beat.repeats }, set: { beat.times = $0; replay() }), in: AnimationBeat.timesRange) {
                        Text(verbatim: Self.unit(m, beat.repeats)).font(Typeface.small.monospacedDigit()).foregroundStyle(Tone.muted)
                    }
                    .help("How many times it goes")
                    Toggle(isOn: Binding(get: { beat.reverse == true }, set: { beat.reverse = $0 ? true : nil; replay() })) {
                        Image(systemName: "arrow.left.arrow.right")
                    }
                    .toggleStyle(.impButton)
                    .help("The other way round")
                }
            }
        }
    }

    private func chip(_ m: String?) -> some View {
        let picked = beat.move == m
        return Button {
            beat.move = m
            beat.times = nil
            beat.reverse = nil
            // A move needs time to read: a spin in a flash looks like a glitch.
            if m != nil, beat.duration < 0.6 { beat.duration = 0.8 }
            replay()
        } label: {
            Image(systemName: m.map(Self.symbol) ?? "nosign")
                .font(.icon(.small))
                .foregroundStyle(picked ? AnyShapeStyle(OnTint(tint)) : AnyShapeStyle(Tone.text))
                .frame(maxWidth: .infinity).frame(height: Sizing.glyph)
                .background(RoundedRectangle(cornerRadius: Radius.small, style: .continuous).fill(picked ? AnyShapeStyle(TintFill(tint)) : AnyShapeStyle(Tone.card)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(m.map { Text(verbatim: Self.title($0)) } ?? Text("No move: it holds still"))
        .accessibilityLabel(m.map { Text(verbatim: Self.title($0)) } ?? Text("No move"))
        .accessibilityAddTraits(picked ? .isSelected : [])
    }
}

/// The symbols a beat can pop above its head.
struct GlyphPicker: View {
    @Binding var glyph: String?
    @Environment(\.impTint) private var tint

    static func symbol(_ g: String) -> String {
        switch g {
        case "notes": "music.note"
        case "question": "questionmark"
        case "exclaim": "exclamationmark"
        case "idea": "lightbulb.fill"
        case "sweat": "drop.fill"
        case "heart": "heart.fill"
        case "sparkles": "sparkles"
        default: "circle"
        }
    }

    var body: some View {
        HStack(spacing: Spacing.tight) {
            chip(nil)
            ForEach(AnimationBeat.glyphs, id: \.self) { chip($0) }
        }
    }

    private func chip(_ g: String?) -> some View {
        let picked = glyph == g
        return Button { glyph = g } label: {
            Image(systemName: g.map(Self.symbol) ?? "nosign")
                .font(.icon(.small))
                .foregroundStyle(picked ? AnyShapeStyle(OnTint(tint)) : AnyShapeStyle(Tone.text))
                .frame(maxWidth: .infinity).frame(height: Sizing.glyph)
                .background(RoundedRectangle(cornerRadius: Radius.small, style: .continuous).fill(picked ? AnyShapeStyle(TintFill(tint)) : AnyShapeStyle(Tone.card)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(g.map { Text(verbatim: $0) } ?? Text("No symbol"))
        .accessibilityLabel(g.map { Text(verbatim: $0) } ?? Text("No symbol"))
        .accessibilityAddTraits(picked ? .isSelected : [])
    }
}

/// The icon for the list, from a grid.
struct IconPicker: View {
    @Binding var symbol: String
    let extra: String?
    @Environment(\.impTint) private var tint

    var body: some View {
        EvenGrid(minWidth: Sizing.glyph, spacing: Spacing.tight) {
            ForEach((extra.map { [$0] } ?? []) + MadeAnimation.symbols.filter { $0 != extra }, id: \.self) { s in
                Button { symbol = s } label: {
                    Image(systemName: s).font(.icon(.medium, weight: .semibold))
                        .foregroundStyle(symbol == s ? AnyShapeStyle(OnTint(tint)) : AnyShapeStyle(Tone.text))
                        .frame(maxWidth: .infinity).frame(height: Sizing.glyph)
                        .background(RoundedRectangle(cornerRadius: Radius.small, style: .continuous)
                            .fill(symbol == s ? AnyShapeStyle(TintFill(tint)) : AnyShapeStyle(Tone.card)))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(Text(verbatim: s))
                .accessibilityLabel(Text(verbatim: s))
                .accessibilityAddTraits(symbol == s ? .isSelected : [])
            }
        }
    }
}
