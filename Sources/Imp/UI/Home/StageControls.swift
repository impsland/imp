import AppKit
import ImpKit
import SwiftUI

/// A colour to pick: a ring when it's the one, a little heart once you've found its favourite.
struct Swatch: View {
    let fill: AnyShapeStyle
    let picked: Bool
    let loved: Bool
    @State private var hover = false

    var body: some View {
        Circle().fill(fill).frame(width: 22, height: 22)
            .scaleEffect(hover && !picked ? 1.12 : 1)
            .padding(3.5)
            .overlay(Circle().strokeBorder(Dungeon.cream.opacity(picked ? 0.95 : 0), lineWidth: 2))
            .overlay(alignment: .topTrailing) {
                if loved {
                    Image(systemName: "heart.fill")
                        .font(.system(size: 8, weight: .black))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.5), radius: 1.5)
                        .offset(x: 1, y: -1)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .animation(.snappy(duration: 0.2), value: picked)
            .animation(.spring(response: 0.35, dampingFraction: 0.55), value: loved)
            .animation(.easeOut(duration: 0.12), value: hover)
            .contentShape(Circle())
            .onHover { hover = $0 }
    }
}

/// A round, glassy icon button face (the gear, the arrows).
struct RoundGlyph: View {
    let systemName: String
    var size: CGFloat
    var bold = false
    @State private var hover = false

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: size * 0.42, weight: bold ? .bold : .semibold))
            .foregroundStyle(hover ? Dungeon.cream : Dungeon.cream.opacity(bold ? 0.9 : 0.6))
            .frame(width: size, height: size)
            .background(Circle().fill(Color.white.opacity(hover ? 0.12 : 0.055)))
            .overlay(Circle().strokeBorder(Color.white.opacity(hover ? 0.18 : 0.09)))
            .scaleEffect(hover ? 1.06 : 1)
            .animation(.easeOut(duration: 0.15), value: hover)
            .contentShape(Circle())
            .onHover { hover = $0 }
    }
}

/// The name on top: click it to rename.
struct NameField: View {
    @Binding var name: String
    @Binding var editing: Bool
    let others: [String]
    @State private var draft = ""
    @State private var hover = false
    @FocusState private var focused: Bool

    var body: some View {
        Group {
            if editing {
                TextField("Name", text: $draft)
                    .textFieldStyle(.plain)
                    .multilineTextAlignment(.center)
                    .focused($focused)
                    .onSubmit(commit)
                    .onExitCommand { editing = false }
                    .onChange(of: focused) { _, f in if !f { commit() } }
                    .onAppear { draft = name; focused = true }
                    .frame(maxWidth: 320)
            } else {
                // The pencil hangs off the name's trailing edge, so the name alone is centred.
                Text(name.isEmpty ? "Unnamed" : name).lineLimit(1)
                    .overlay(alignment: .trailing) {
                        Image(systemName: "pencil").font(.system(size: 14, weight: .bold))
                            .opacity(hover ? 0.6 : 0)
                            .alignmentGuide(.trailing) { $0[.leading] - 8 }
                            .accessibilityHidden(true)
                    }
                .contentShape(Rectangle())
                .onHover { hover = $0 }
                .onTapGesture { editing = true }
                .help("Click to rename")
            }
        }
        .font(.system(size: 30, weight: .heavy, design: .rounded))
        .foregroundStyle(Dungeon.cream)
    }

    private func commit() {
        guard editing else { return }
        let t = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty && !others.contains(where: { $0.caseInsensitiveCompare(t) == .orderedSame }) { name = t }
        editing = false
    }
}

/// A rainbow track to pick any hue.
struct HueSlider: View {
    @Binding var hue: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(LinearGradient(colors: (0...12).map { Color.imp(Double($0) / 12) }, startPoint: .leading, endPoint: .trailing))
                    .frame(height: 14)
                Circle().fill(Color.imp(hue)).frame(width: 22, height: 22)
                    .overlay(Circle().strokeBorder(.white, lineWidth: 2.5))
                    .shadow(radius: 2)
                    .offset(x: hue * (geo.size.width - 22))
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                hue = min(max((v.location.x - 11) / (geo.size.width - 22), 0), 1)
            })
        }
        .frame(height: 26)
        .accessibilityElement()
        .accessibilityLabel("Colour")
        .accessibilityValue("\(Int(hue * 360)) degrees")
        .accessibilityAdjustableAction { d in
            hue = min(max(hue + (d == .increment ? 0.02 : -0.02), 0), 1)
        }
    }
}

/// The big round button at the bottom of the stage.
struct BigButtonStyle: ButtonStyle {
    var hue: Double
    var filled = true
    @State private var hover = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: .bold, design: .rounded))
            .foregroundStyle(filled ? .white : Dungeon.cream)
            .padding(.horizontal, 24).padding(.vertical, 11)
            .background(Capsule().fill(filled ? AnyShapeStyle(Color.imp(hue).gradient) : AnyShapeStyle(Dungeon.card)))
            .overlay(Capsule().strokeBorder(filled ? Color.white.opacity(0.25) : Color.imp(hue).opacity(0.7), lineWidth: filled ? 0.5 : 1.5))
            .shadow(color: filled ? Color.imp(hue).opacity(hover ? 0.6 : 0.4) : .clear, radius: hover ? 14 : 9, y: 3)
            .scaleEffect(configuration.isPressed ? 0.96 : hover ? 1.03 : 1)
            .animation(.snappy(duration: 0.15), value: configuration.isPressed)
            .animation(.easeOut(duration: 0.15), value: hover)
            .onHover { hover = $0 }
            .contentShape(Capsule())
    }
}

