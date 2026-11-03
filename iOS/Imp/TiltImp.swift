import CoreMotion
import ImpKit
import SwiftUI

/// The Imp on the first screen, alive in your hand: tip the phone and it leans and slides that
/// way and looks downhill, a sudden tilt startles it, a shake makes it dizzy, a tap makes it hop,
/// and it watches your finger. The editor's preview is the same view, so it moves the same way.
struct TiltImp: View {
    /// Who to draw. The first screen shows the greeter.
    var imp: LinkImp = .greeter
    /// Whether a finger can touch it (it looks, and a tap makes it hop). Off when the Imp sits
    /// inside a scrolling form and only follows the phone.
    var interactive = true
    @State private var tilt = TiltWatcher()
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var touch: CGPoint?
    @State private var performance: Performance?
    @State private var flash: (mood: Mood, until: Date)?

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            TimelineView(Energy.shared.schedule(lively: true, paused: scenePhase != .active, fastest: 1 / 60)) { timeline in
                let date = timeline.date
                let state = tilt.state(at: date)
                let center = CGPoint(x: size.width / 2 + state.slide, y: size.height / 2)
                // A finger wins; otherwise it looks the way the phone tips (downhill).
                let gaze = touch.map { Gaze.toward($0, from: center) } ?? state.look
                ImpFigure(imp: imp, mood: mood(at: date, state: state), performance: performance,
                          lean: state.lean, gaze: gaze, attentive: touch != nil, date: date)
                    .offset(x: state.slide)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { touch = $0.location }
                .onEnded { value in
                    touch = nil
                    if hypot(value.translation.width, value.translation.height) < 8 { hop() }
                }, isEnabled: interactive)
        }
        .onAppear {
            tilt.onShake = { flash = (.dizzy, Date().addingTimeInterval(2.6)) }
            tilt.onJolt = { if flash == nil || flash!.until < Date() { flash = (.surprised, Date().addingTimeInterval(0.9)) } }
            updateMotion()
        }
        .onDisappear { tilt.stop() }
        .onChange(of: scenePhase) { updateMotion() }
        .onChange(of: reduceMotion) { updateMotion() }
        .accessibilityElement()
        .accessibilityLabel("Imp")
        .accessibilityHint(interactive ? "Tilt your phone or tap it." : "")
        .accessibilityAddTraits(interactive ? .isButton : [])
        .accessibilityAction { if interactive { hop() } }
    }

    /// Follows the phone while the screen is showing and Reduce Motion is off.
    private func updateMotion() {
        if scenePhase == .active && !reduceMotion { tilt.start() } else { tilt.stop() }
    }

    private func mood(at date: Date, state: TiltWatcher.State) -> Mood {
        if let flash, flash.until > date { return flash.mood }
        if touch != nil { return .curious }
        return abs(state.lean) > 9 ? .excited : .idle
    }

    private func hop() {
        performance = Performance(key: "hop-\(UUID())", steps: [AnticStep(duration: Motion.hopLength, mood: .happy, hop: true),
                                                              AnticStep(duration: 0.8, mood: .content)])
        UIImpactFeedbackGenerator(style: .soft).impactOccurred()
    }
}

/// The phone's motion, read once for every screen that wants it: one `CMMotionManager`, started
/// when the first watcher attaches and stopped when the last one lets go (so the first screen and
/// an editor opened over it share it).
@MainActor
final class TiltSource {
    static let shared = TiltSource()

    private(set) var gravity = (x: 0.0, y: -1.0, z: 0.0)
    /// How the phone is usually held (slowly follows the hand), so "level" is however you hold it.
    private(set) var rest: (y: Double, z: Double)?
    private let manager = CMMotionManager()
    private var listeners: [ObjectIdentifier: (_ acceleration: (x: Double, y: Double, z: Double), _ time: TimeInterval) -> Void] = [:]

    /// Starts the motion updates if nobody has. `onSample` gets the user acceleration (g) and the time of each sample.
    func attach(_ owner: AnyObject, onSample: @escaping (_ acceleration: (x: Double, y: Double, z: Double), _ time: TimeInterval) -> Void) {
        listeners[ObjectIdentifier(owner)] = onSample
        guard manager.isDeviceMotionAvailable, !manager.isDeviceMotionActive else { return }
        manager.deviceMotionUpdateInterval = 1 / 60
        manager.startDeviceMotionUpdates(to: .main) { [weak self] data, _ in
            guard let data else { return }
            let g = data.gravity, a = data.userAcceleration, t = data.timestamp
            MainActor.assumeIsolated {
                guard let self else { return }
                self.gravity = (g.x, g.y, g.z)
                if let r = self.rest {
                    // Follows the way you hold it over a few seconds.
                    self.rest = (r.y + (g.y - r.y) * 0.008, r.z + (g.z - r.z) * 0.008)
                } else {
                    self.rest = (g.y, g.z)
                }
                for listener in Array(self.listeners.values) { listener((a.x, a.y, a.z), t) }
            }
        }
    }

    func detach(_ owner: AnyObject) {
        listeners[ObjectIdentifier(owner)] = nil
        if listeners.isEmpty { manager.stopDeviceMotionUpdates() }
    }
}

/// Turns how the phone is held (from the shared `TiltSource`) into how the Imp leans, slides and
/// looks. Smoothed with springs so the Imp moves like it has weight. Read once a frame.
@MainActor
final class TiltWatcher {
    struct State {
        /// Degrees, toward the low side.
        var lean = 0.0
        /// Points sideways, toward the low side.
        var slide: CGFloat = 0
        /// Head turn (−1…1, y down).
        var look = CGPoint.zero
    }

    var onShake: (() -> Void)?
    var onJolt: (() -> Void)?

    /// Held upright and still, which is what the Imp sees when it isn't following the phone.
    private var gravity: (x: Double, y: Double, z: Double) { running ? TiltSource.shared.gravity : (0, -1, 0) }
    private var rest: (y: Double, z: Double)? { running ? TiltSource.shared.rest : nil }
    private var running = false
    private var jolts = JoltDetector(threshold: 1.6)
    private var current = State()
    private var velocity = (lean: 0.0, slide: 0.0, x: 0.0, y: 0.0)
    private var last: Date?

    func start() {
        running = true
        TiltSource.shared.attach(self) { [weak self] a, t in
            guard let self else { return }
            switch jolts.feed(x: a.x, at: t) {
            case .shaken?: onShake?()
            case .thrown?: onJolt?()
            case nil: if abs(a.y) > 1.6 || abs(a.z) > 1.6 { onJolt?() }
            }
        }
    }

    func stop() {
        running = false
        TiltSource.shared.detach(self)
    }

    /// Where the Imp is this frame: springs pulled toward what the tilt asks for.
    func state(at date: Date) -> State {
        let dt = min(max(last.map { date.timeIntervalSince($0) } ?? 0, 0), 1 / 20)
        last = date
        let side = max(-1, min(1, gravity.x * 1.6))                 // tipped right: positive
        let pitch = max(-1, min(1, ((gravity.z - (rest?.z ?? gravity.z)) - (gravity.y - (rest?.y ?? gravity.y))) * 2.2))
        let target = (lean: side * 16, slide: side * 34, x: side * 0.9, y: pitch * 0.8)
        func spring(_ value: Double, _ v: inout Double, to goal: Double, stiffness: Double = 60, damping: Double = 9) -> Double {
            v += ((goal - value) * stiffness - v * damping) * dt
            return value + v * dt
        }
        current.lean = spring(current.lean, &velocity.lean, to: target.lean)
        current.slide = CGFloat(spring(Double(current.slide), &velocity.slide, to: target.slide, stiffness: 40, damping: 7))
        current.look = CGPoint(x: spring(current.look.x, &velocity.x, to: target.x, stiffness: 90, damping: 14),
                               y: spring(current.look.y, &velocity.y, to: target.y, stiffness: 90, damping: 14))
        return current
    }
}
