import ImpDesign
import ImpKit
import SwiftUI

/// Which Imps this iPhone's person hid. Kept for this person, on this phone.
@MainActor @Observable
final class PhoneHidden {
    private static let key = "hiddenImps"
    private(set) var set: HiddenImps

    init(defaults: UserDefaults = .standard) {
        set = defaults.data(forKey: Self.key).flatMap { try? JSONDecoder().decode(HiddenImps.self, from: $0) } ?? HiddenImps()
    }

    func hide(_ id: UUID) { change { $0.hide(id) } }
    func bringBack(_ id: UUID) { change { $0.bringBack(id) } }
    func bringBackAll() { change { $0.bringBackAll() } }
    func forget(except roster: [UUID]) { change { $0.forget(except: roster) } }

    private func change(_ edit: (inout HiddenImps) -> Void) {
        var next = set
        edit(&next)
        guard next != set else { return }
        set = next
        if let data = try? JSONEncoder().encode(next) { UserDefaults.standard.set(data, forKey: Self.key) }
    }
}

/// The floor of the phone's room, where hidden Imps live. Now and then one peeks out from the bottom
/// edge and goes back, and a tap on it brings it back. The floor is also one element for VoiceOver
/// that names how many are hidden and has an action for each, so a peek is never the only way back.
struct PhoneHiddenFloor: View {
    let imps: [LinkImp]
    /// Whether the stage is in view and nothing covers it.
    let watching: Bool
    var bringBack: (UUID) -> Void
    @State private var peeking: UUID?
    @State private var out = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.decorated) private var decorated

    private static let plan = PeekPlan(minSeconds: Double(Behavior.peekIntervalMinSeconds), maxSeconds: Double(Behavior.peekIntervalMaxSeconds),
                                       showSeconds: Behavior.peekShowSeconds, quietSeconds: 0)
    private static let side: CGFloat = 96
    private static let shown: CGFloat = 0.55

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .bottomLeading) {
                if let imp = imps.first(where: { $0.id == peeking }) { peeker(imp, in: geo.size) }
                Color.clear
                    .frame(height: Sizing.hiddenStrip)
                    .frame(maxWidth: .infinity)
                    .allowsHitTesting(false)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Text(imps.isEmpty ? String(localized: "home.hidden.empty") : words("home.hidden.title", imps.count)))
                    .accessibilityHint(Text("home.hidden.hint"))
                    .accessibilityActions {
                        ForEach(imps) { imp in
                            Button { bringBack(imp.id) } label: { Text(words("home.hidden.bring_back", imp.name)) }
                        }
                    }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        }
        // The peeking loop only exists while there is something to see: it ends when the stage is covered or
        // in the background, the phone saves power, or nobody is hidden, and starts again when that changes.
        .task(id: watching && decorated && !imps.isEmpty) {
            if watching && decorated && !imps.isEmpty { await peekForever() }
        }
    }

    private func peeker(_ imp: LinkImp, in size: CGSize) -> some View {
        let side = Self.side * imp.scale
        let visible = side * Self.shown
        let slot = Double((imps.firstIndex { $0.id == imp.id } ?? 0) + 1) / Double(imps.count + 1)
        return ImpFigure(imp: imp, mood: .curious, date: Date())
            .frame(width: side, height: side)
            .offset(y: reduceMotion || out ? 0 : visible)
            .opacity(reduceMotion && !out ? 0 : 1)
            .frame(width: side, height: visible, alignment: .top)
            .clipped()
            .contentShape(Rectangle())
            .onTapGesture { bringBack(imp.id) }
            .offset(x: size.width * slot - side / 2)
            .accessibilityHidden(true)
    }

    private func peekForever() async {
        var last: UUID?
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(Self.plan.wait(unit: .random(in: 0...1))))
            while !Task.isCancelled, !Self.plan.mayPeek(windowVisible: watching, secondsSinceTyping: 0, peeking: peeking != nil, hidden: imps.count) {
                try? await Task.sleep(for: .seconds(2))
            }
            guard !Task.isCancelled, let id = Self.plan.pick(from: imps.map(\.id), after: last), let imp = imps.first(where: { $0.id == id }) else { continue }
            last = id
            peeking = id
            out = false
            withAnimation(ImpDesign.Motion.peek.reducedAware(reduceMotion)) { out = true }
            AccessibilityNotification.Announcement(words("home.hidden.peek", imp.name)).post()
            try? await Task.sleep(for: .seconds(Self.plan.showSeconds))
            withAnimation(ImpDesign.Motion.peek.reducedAware(reduceMotion)) { out = false }
            try? await Task.sleep(for: .seconds(0.5))
            peeking = nil
        }
    }
}
