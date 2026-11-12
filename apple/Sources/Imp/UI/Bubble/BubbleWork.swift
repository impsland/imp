import ImpKit
import SwiftUI
import ImpDesign

/// What Imp is working on: what it's about, a bouncing-dots caption, and live tool steps.
struct WorkingView: View {
    let bubble: Bubble
    let layout: BubbleLayout
    var measuring = false

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.small) {
            if let exchange = bubble.exchange {
                ExchangeHeader(exchange: exchange)
            } else if !bubble.title.isEmpty {
                Text(bubble.title)
                    .font(Typeface.caption)
                    .foregroundStyle(Tone.muted)
                    .lineLimit(2)
            }
            HStack(spacing: Spacing.small) {
                ThinkingDots(animated: !measuring)
                Text(bubble.text)
                    .font(Typeface.body)
                    .foregroundStyle(Tone.muted)
                    .contentTransition(.opacity)
                    .impAnimation(ImpDesign.Motion.scene, value: bubble.text)
                    .lineLimit(1)
            }
            if !bubble.steps.isEmpty { StepList(steps: bubble.steps, layout: layout, animated: !measuring) }
        }
    }
}

struct ThinkingDots: View {
    @Environment(\.impTint) private var tint
    var animated = true

    var body: some View {
        TimelineView(.animation(minimumInterval: Energy.shared.interval(fps: 30), paused: !animated)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: Spacing.tight) {
                ForEach(0..<3, id: \.self) { i in
                    let k = max(0, sin(t * 6 - Double(i) * 0.7))
                    Circle()
                        .fill(tint)
                        .frame(width: BubbleMetrics.pip, height: BubbleMetrics.pip)
                        .offset(y: -3 * k)
                        .opacity(0.45 + 0.55 * k)
                }
            }
            .frame(height: BubbleMetrics.pipRow)
        }
    }
}

/// Tool calls and other work, one compact row each, with a spinner, ✓ or ✕. Click a tool call
/// to see what was asked and what came back.
struct StepList: View {
    @Environment(\.impTint) private var tint
    let steps: [Bubble.Step]
    let layout: BubbleLayout
    var animated = true

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.snug) {
            ForEach(steps) { step in
                let open = layout.openSteps.contains(step.id)
                VStack(alignment: .leading, spacing: Spacing.snug) {
                    if step.tool == nil {
                        row(step, open: false)
                    } else {
                        Button { toggle(step) } label: { row(step, open: open) }
                            .buttonStyle(.plain)
                            .help(open ? "Hide the details" : "Show what was asked and what came back")
                    }
                    if open { StepDetail(step: step) }
                }
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .impAnimation(ImpDesign.Motion.smooth, value: steps)
    }

    private func row(_ step: Bubble.Step, open: Bool) -> some View {
        HStack(spacing: Spacing.small) {
            Image(systemName: step.icon)
                .font(Typeface.small.weight(.semibold))
                .foregroundStyle(LegibleTint(on: .raised))
                .frame(width: BubbleMetrics.step, height: BubbleMetrics.step)
                .background(Circle().fill(tint.opacity(Opacity.tintFill)))
            Text(step.title)
                .font(Typeface.body)
                .foregroundStyle(step.state == .failed ? Tone.muted : Tone.text)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: Spacing.tight)
            if step.tool != nil {
                Image(systemName: "chevron.right")
                    .font(Typeface.small.weight(.semibold))
                    .foregroundStyle(Tone.faint)
                    .rotationEffect(.degrees(open ? 90 : 0))
            }
            switch step.state {
            case .running:
                if animated { ProgressView().controlSize(.mini) }
            case .done:
                Image(systemName: "checkmark").font(.icon(.small, weight: .bold)).foregroundStyle(Tone.good)
            case .failed:
                Image(systemName: "xmark").font(.icon(.small, weight: .bold)).foregroundStyle(Tone.danger)
            }
        }
        .contentShape(Rectangle())
    }

    /// Opens or closes a step's details, then has the panel re-measured to fit.
    private func toggle(_ step: Bubble.Step) {
        if layout.openSteps.remove(step.id) == nil { layout.openSteps.insert(step.id) }
        layout.onToggle?()
    }
}

/// A tool call in full: the request and the response, each selectable and copyable. Long ones
/// scroll in a box of fixed height (so the bubble's measured size stays right).
struct StepDetail: View {
    let step: Bubble.Step
    private static let boxHeight: CGFloat = 130

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.snug) {
            section("Request", step.request)
            if let response = step.response {
                section("Response", response)
            } else {
                Text("Waiting for the response…").font(Typeface.small).foregroundStyle(Tone.muted)
            }
        }
        .padding(.leading, BubbleMetrics.step + Spacing.small)
    }

    private func section(_ label: LocalizedStringKey, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: Spacing.tight) {
            HStack {
                Text(label).font(Typeface.small.weight(.semibold)).foregroundStyle(Tone.muted)
                Spacer()
                CopyButton(size: 18) { Pasteboard.write(text: text) }
            }
            let content = Text(text.isEmpty ? " " : text)
                .font(Typeface.mono)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Spacing.snug)
            Group {
                if Self.isLong(text) { ReadingScroll(height: Self.boxHeight) { content } } else { content }
            }
            .background(RoundedRectangle(cornerRadius: Radius.small, style: .continuous).fill(Tone.well))
        }
    }

    /// More than fits the box comfortably (about nine lines).
    private static func isLong(_ text: String) -> Bool {
        text.count > 600 || text.reduce(0) { $1 == "\n" ? $0 + 1 : $0 } > 8
    }
}
