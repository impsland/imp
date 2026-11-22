import ImpDesign
import ImpKit
import SwiftUI

extension EnvironmentValues {
    /// The pictures of the first run show their last frame and stay still, for the design scenes and the snapshots.
    @Entry var onboardingSettled = false
}

/// What every picture of the first run is as tall as.
enum OnboardingPicture {
    static var height: CGFloat { Sizing.heroImp * 1.5 }
}

/// Step 1 (the Imp is drawn by `figure`): the Imp on one side, a brain on the other. The key leaves the brain and
/// rides a line that draws itself to the Imp once it is connected. The service's host is small under the brain.
struct KeyPicture<Figure: View>: View {
    let host: String
    let connected: Bool
    let hue: Double
    let figure: (Mood) -> Figure
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.onboardingSettled) private var settled
    private var reduceMotion: Bool { systemReduceMotion || settled }
    @State private var keyShown = false

    var body: some View {
        HStack(spacing: 0) {
            figure(connected ? .happy : .thinking).frame(width: Sizing.heroImp * 0.7, height: Sizing.heroImp * 0.7)
            Line(progress: connected ? 1 : 0)
                .stroke(Color.imp(hue), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .frame(height: 2).padding(.horizontal, Spacing.cozy)
                .overlay(alignment: connected ? .leading : .trailing) {
                    Image(systemName: "key.fill").font(.icon(.large)).foregroundStyle(LegibleTint(Color.imp(hue)))
                        .scaleEffect(keyShown || reduceMotion ? 1 : 0.3).opacity(keyShown || reduceMotion ? 1 : 0)
                }
                .impAnimation(.easeInOut(duration: 0.7), value: connected)
            VStack(spacing: Spacing.small) {
                Image(systemName: "brain.head.profile").font(.icon(.large)).foregroundStyle(Tone.text)
                    .frame(width: Sizing.heroImp * 0.7, height: Sizing.heroImp * 0.7)
                    .background(Tone.raised, in: RoundedRectangle(cornerRadius: Radius.medium))
                if !host.isEmpty { Text(verbatim: host).font(Typeface.small).foregroundStyle(Tone.muted).lineLimit(1) }
            }
        }
        .frame(width: 300)
        .task {
            guard !reduceMotion else { return }
            withImpAnimation(.spring(duration: 0.5, bounce: 0.4), reduceMotion: reduceMotion) { keyShown = true }
        }
    }
}

/// A line that grows from its right end toward its left.
private struct Line: Shape {
    var progress: Double
    var animatableData: Double { get { progress } set { progress = newValue } }
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.maxX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.maxX - rect.width * progress, y: rect.midY))
        return path
    }
}

/// An Imp on its way along an arc, `t` from 0 (at the start) to 1 (at the end), with a short trail of fading dots behind it.
private struct Flight<Figure: View>: View, @preconcurrency Animatable {
    var t: Double
    let from: CGPoint
    let to: CGPoint
    let figure: Figure

    var animatableData: Double { get { t } set { t = newValue } }

    private func point(_ t: Double) -> CGPoint {
        CGPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t - sin(t * .pi) * Sizing.heroImp * 0.45)
    }

    var body: some View {
        ZStack {
            ForEach(1..<5, id: \.self) { k in
                let behind = t - Double(k) * 0.07
                if t < 1, behind > 0 {
                    Circle().fill(Tone.muted).frame(width: Spacing.cozy, height: Spacing.cozy)
                        .opacity(0.6 - Double(k) * 0.12)
                        .position(point(behind))
                }
            }
            figure.frame(width: 44, height: 44).position(point(t))
        }
    }
}

/// Step 2 (the Imp is drawn by `figure`): with a quick swipe toward the screen's edge the Imp is flung off one
/// device and lands on the outline of another. On the Mac the Mac window sends it to a phone, on the iPhone
/// the phone sends it to a Mac.
struct MovePicture<Figure: View>: View {
    let fromPhone: Bool
    let figure: (Mood) -> Figure
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.onboardingSettled) private var settled
    private var reduceMotion: Bool { systemReduceMotion || settled }
    @State private var flight = 0.0

    private let size = CGSize(width: 300, height: Sizing.heroImp * 1.2)
    private let screen = CGSize(width: 132, height: 88)
    private let phone = CGSize(width: 50, height: 92)

    private var source: CGSize { fromPhone ? phone : screen }
    private var target: CGSize { fromPhone ? screen : phone }
    private var start: CGPoint { CGPoint(x: source.width / 2, y: size.height / 2) }
    private var end: CGPoint { CGPoint(x: size.width - target.width / 2, y: size.height / 2) }
    private var landed: Bool { flight >= 1 }

    var body: some View {
        ZStack {
            outline(source).position(x: source.width / 2, y: size.height / 2)
            outline(target, lit: landed || reduceMotion).position(x: size.width - target.width / 2, y: size.height / 2)
            Flight(t: reduceMotion ? 1 : flight, from: start, to: end, figure: figure(landed || reduceMotion ? .happy : .excited))
        }
        .frame(width: size.width, height: size.height)
        .task {
            guard !reduceMotion else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(0.8))
                withImpAnimation(.easeIn(duration: 0.8), reduceMotion: reduceMotion) { flight = 1 }
                try? await Task.sleep(for: .seconds(2.4))
                withImpAnimation(.easeInOut(duration: 0.6), reduceMotion: reduceMotion) { flight = 0 }
                try? await Task.sleep(for: .seconds(0.8))
            }
        }
    }

    private func outline(_ size: CGSize, lit: Bool = false) -> some View {
        RoundedRectangle(cornerRadius: Radius.small).stroke(lit ? Tone.accent : Tone.muted, lineWidth: 2)
            .frame(width: size.width, height: size.height)
    }
}

private let setupMoods: [Mood] = [.happy, .love, .sad, .surprised, .excited]

/// Step 3 (the Imp is drawn by `figure`): the Imp with a speech bubble above it, the prompt typed into the bubble,
/// then five emotions appear one by one.
struct SetupPicture<Figure: View>: View {
    let prompt: String
    let figure: (Mood) -> Figure
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.onboardingSettled) private var settled
    private var reduceMotion: Bool { systemReduceMotion || settled }
    @State private var shown = 0
    @State private var typed = 0

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .topLeading) {
                Text(verbatim: prompt).hidden()
                Text(verbatim: String(prompt.prefix(reduceMotion ? prompt.count : typed)))
            }
            .font(Typeface.small).foregroundStyle(Tone.text)
            .padding(Spacing.cozy)
            .frame(width: 300, alignment: .leading)
            .background(Tone.raised, in: RoundedRectangle(cornerRadius: Radius.medium))
            Triangle().fill(Tone.raised).frame(width: Spacing.roomy, height: Spacing.cozy)
            HStack(spacing: Spacing.small) {
                figure(.happy).frame(width: 44, height: 44)
                HStack(spacing: Spacing.small) {
                    ForEach(Array(setupMoods.enumerated()), id: \.offset) { index, mood in
                        figure(mood).frame(width: 32, height: 32)
                            .background(Tone.raised, in: RoundedRectangle(cornerRadius: Radius.small))
                            .scaleEffect(index < shown || reduceMotion ? 1 : 0.4).opacity(index < shown || reduceMotion ? 1 : 0)
                    }
                }
            }
        }
        .task {
            guard !reduceMotion else { shown = setupMoods.count; return }
            for n in 1...max(prompt.count, 1) {
                typed = n
                try? await Task.sleep(for: .milliseconds(25))
            }
            for n in 1...setupMoods.count {
                withImpAnimation(.spring(duration: 0.4, bounce: 0.4), reduceMotion: reduceMotion) { shown = n }
                try? await Task.sleep(for: .milliseconds(350))
            }
        }
    }
}

/// The tail of a speech bubble, pointing down.
private struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}
