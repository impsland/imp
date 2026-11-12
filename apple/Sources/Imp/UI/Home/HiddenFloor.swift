import AppKit
import ImpDesign
import ImpKit
import SwiftUI

/// The floor of the window, where hidden Imps live. Now and then one peeks out from the bottom edge,
/// shyly, and goes back. A click on it brings it back. The floor is also one focusable element that
/// names how many are hidden and has an action for each, so a peek is never the only way back.
struct HiddenFloor: View {
    @Bindable var model: AppModel
    @Bindable var router: HomeRouter
    let size: CGSize
    /// The Imp that is peeking, and whether it has come all the way out.
    @State private var peeking: UUID?
    @State private var out = false
    @FocusState private var focused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let plan = PeekPlan(minSeconds: Double(Behavior.peekIntervalMinSeconds), maxSeconds: Double(Behavior.peekIntervalMaxSeconds),
                                       showSeconds: Behavior.peekShowSeconds, quietSeconds: Double(Behavior.peekQuietSeconds))
    /// How much of an Imp shows when it peeks: the head and the horns.
    private static let shown: CGFloat = 0.55
    /// The strip along the bottom that is the focusable Hidden Imps element.
    /// How long to wait before looking again when a peek is not welcome now, and for the Imp to be out of sight again.
    private static let retrySeconds = 2.0
    private static let hideSeconds = 0.5
    private static let floorHeight = Sizing.hit

    private var actions: HomeActions { HomeActions(model: model, router: router) }

    var body: some View {
        let hidden = model.hiddenIDs
        ZStack(alignment: .bottomLeading) {
            if let id = peeking, let imp = model.profile(id) { peeker(imp) }
            floor(hidden)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        // Only while it can be seen and someone is hiding: a window that is closed, covered or on a settings page does no work.
        .task(id: router.isAwake && router.screen == .home && model.hiddenCount > 0) {
            guard router.isAwake, router.screen == .home, model.hiddenCount > 0 else { return }
            await peekForever()
        }
    }

    private func peeker(_ imp: ImpProfile) -> some View {
        let side = Panels.baseSize * imp.scale
        let visible = side * Self.shown
        let x = CanvasLayout.point(of: router.places[imp.id] ?? CGPoint(x: 0.5, y: 0.5), in: size, figure: side).x
        return StageImp(hue: imp.hue, performance: nil, traits: imp.traits, clock: BodyClock(imp.id))
            .frame(width: side, height: side)
            // The head and horns come up from the floor. With Reduce Motion it fades in where it will stand.
            .offset(y: reduceMotion || out ? 0 : visible)
            .opacity(reduceMotion && !out ? 0 : 1)
            .frame(width: side, height: visible, alignment: .top)
            .clipped()
            .contentShape(Rectangle())
            .onTapGesture { actions.bringBack(imp.id) }
            .offset(x: x - side / 2)
            .accessibilityHidden(true)
    }

    /// The one element screen readers and the keyboard find: how many are hidden, and a way back for each.
    private func floor(_ hidden: [UUID]) -> some View {
        Color.clear
            .frame(maxWidth: .infinity)
            .frame(height: Self.floorHeight)
            .overlay {
                if focused && !hidden.isEmpty {
                    Text(words("home.hidden.title", hidden.count))
                        .font(Typeface.label)
                        .foregroundStyle(Tone.paper)
                        .padding(.horizontal, Spacing.medium)
                        .padding(.vertical, Spacing.tight)
                        .background(Capsule().fill(Tone.scrim))
                        .focusRing(Capsule(), shown: true)
                        .padding(.bottom, Spacing.small)
                }
            }
            .allowsHitTesting(false)
            // With no one hidden there is nothing to reach: the floor is not a stop for the keyboard.
            .focusable(!hidden.isEmpty)
            .focused($focused)
            .focusEffectDisabled()
            .onKeyPress(.return) {
                guard let id = peeking ?? hidden.first else { return .ignored }
                actions.bringBack(id)
                return .handled
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(hidden.isEmpty ? String(localized: "home.hidden.empty") : words("home.hidden.title", hidden.count)))
            .accessibilityHint(Text("home.hidden.hint"))
            .accessibilityActions {
                ForEach(hidden, id: \.self) { id in
                    Button { actions.bringBack(id) } label: { Text(words("home.hidden.bring_back", model.profile(id)?.name ?? "")) }
                }
            }
    }

    // MARK: Peeking

    /// Waits a while, then lets one hidden Imp peek, one at a time, for as long as the floor is on screen.
    private func peekForever() async {
        var last: UUID?
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(Self.plan.wait(unit: .random(in: 0...1))))
            // Not now: the window is hidden or the user is typing. Look again soon.
            while !Task.isCancelled, !Self.plan.mayPeek(windowVisible: router.isAwake && router.screen == .home,
                                                         secondsSinceTyping: Self.secondsSinceTyping, peeking: peeking != nil,
                                                         hidden: model.hiddenCount) {
                try? await Task.sleep(for: .seconds(Self.retrySeconds))
            }
            guard !Task.isCancelled, let id = Self.plan.pick(from: model.hiddenIDs, after: last), let imp = model.profile(id) else { continue }
            last = id
            peeking = id
            out = false
            withImpAnimation(ImpDesign.Motion.peek, reduceMotion: reduceMotion) { out = true }
            AccessibilityNotification.Announcement(words("home.hidden.peek", imp.name)).post()
            try? await Task.sleep(for: .seconds(Self.plan.showSeconds))
            withImpAnimation(ImpDesign.Motion.peek, reduceMotion: reduceMotion) { out = false }
            try? await Task.sleep(for: .seconds(Self.hideSeconds))
            peeking = nil
        }
    }

    private static var secondsSinceTyping: Double {
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .keyDown)
    }
}
