import ImpKit
import SwiftUI

/// What Imp is working on: what it's about, a bouncing-dots caption, and live tool steps.
struct WorkingView: View {
    let bubble: Bubble
    let layout: BubbleLayout
    var measuring = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let exchange = bubble.exchange {
                ExchangeHeader(exchange: exchange)
            } else if !bubble.title.isEmpty {
                Text(bubble.title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            HStack(spacing: 8) {
                ThinkingDots(animated: !measuring)
                Text(bubble.text)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .contentTransition(.opacity)
                    .animation(.easeInOut(duration: 0.3), value: bubble.text)
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
        TimelineView(.animation(minimumInterval: 1 / 30, paused: !animated)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 3) {
                ForEach(0..<3, id: \.self) { i in
                    let k = max(0, sin(t * 6 - Double(i) * 0.7))
                    Circle()
                        .fill(tint)
                        .frame(width: 5, height: 5)
                        .offset(y: -3 * k)
                        .opacity(0.45 + 0.55 * k)
                }
            }
            .frame(height: 12)
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
        VStack(alignment: .leading, spacing: 5) {
            ForEach(steps) { step in
                let open = layout.openSteps.contains(step.id)
                VStack(alignment: .leading, spacing: 6) {
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
        .animation(.snappy(duration: 0.25), value: steps)
    }

    private func row(_ step: Bubble.Step, open: Bool) -> some View {
        HStack(spacing: 7) {
            Image(systemName: step.icon)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 18, height: 18)
                .background(Circle().fill(tint.opacity(0.12)))
            Text(step.title)
                .font(.system(size: 12))
                .foregroundStyle(step.state == .failed ? .secondary : .primary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            if step.tool != nil {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(open ? 90 : 0))
            }
            switch step.state {
            case .running:
                if animated { ProgressView().controlSize(.mini) }
            case .done:
                Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.green)
            case .failed:
                Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.orange)
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
        VStack(alignment: .leading, spacing: 6) {
            section("Request", step.request)
            if let response = step.response {
                section("Response", response)
            } else {
                Text("Waiting for the response…").font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .padding(.leading, 25)
    }

    private func section(_ label: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(label).font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                Spacer()
                CopyButton(size: 18) { Pasteboard.write(text: text) }
            }
            let content = Text(text.isEmpty ? " " : text)
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
            Group {
                if Self.isLong(text) { ReadingScroll(height: Self.boxHeight) { content } } else { content }
            }
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.06)))
        }
    }

    /// More than fits the box comfortably (about nine lines).
    private static func isLong(_ text: String) -> Bool {
        text.count > 600 || text.reduce(0) { $1 == "\n" ? $0 + 1 : $0 } > 8
    }
}
