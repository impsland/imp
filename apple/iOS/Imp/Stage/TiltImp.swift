import CoreMotion
import ImpDesign
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
    /// Dozes when left alone (an Imp with no Brain yet). A finger, a tilt or a shake still stirs it.
    var asleep = false
    @State private var tilt = TiltWatcher()
    @State private var pacer = StagePacer()
    /// How fast the Imp is drawn right now (the pacer says, `FramePolicy` turns it into frames).
    @State private var activity = FramePolicy.Activity.lively
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.covered) private var covered
    @State private var onScreen = false
    @State private var touch: CGPoint?
    @State private var performance: Performance?
    @State private var flash: (mood: Mood, until: Date)?

    /// What the phone allows while this Imp is shown.
    private var conditions: FramePolicy.Conditions {
        Energy.shared.conditions(active: scenePhase == .active, visible: onScreen && !covered, reduceMotion: reduceMotion)
    }

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            PacedTimeline(activity: activity) { date in
                let state = tilt.state(at: date)
                let center = CGPoint(x: size.width / 2 + state.slide, y: size.height / 2)
                // A finger wins. Otherwise it looks the way the phone tips (downhill).
                let gaze = touch.map { Gaze.toward($0, from: center) } ?? state.look
                let mood = mood(at: date, state: state)
                let _ = frame(mood: mood, state: state, date: date)
                ImpFigure(imp: imp, mood: mood, performance: performance,
                          lean: state.lean, gaze: gaze, attentive: touch != nil, date: date, breathes: mood != .sleepy)
                    .offset(x: state.slide)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { touch = $0.location; pacer.wake() }
                .onEnded { value in
                    touch = nil
                    if hypot(value.translation.width, value.translation.height) < 8 { hop() }
                }, isEnabled: interactive)
        }
        .onAppear {
            onScreen = true
            pacer.onChange = { activity = $0 }
            tilt.onShake = { flash = (.dizzy, Date().addingTimeInterval(2.6)); pacer.wake() }
            tilt.onMove = { pacer.wake() }
            tilt.onJolt = {
                if flash == nil || flash!.until < Date() { flash = (.surprised, Date().addingTimeInterval(0.9)) }
                pacer.wake()
            }
            updateMotion()
        }
        .onDisappear {
            onScreen = false
            tilt.stop()
        }
        // A new colour or character springs in over a moment (`Puppet`): it needs frames to get there.
        .onChange(of: imp) { pacer.wake() }
        .onChange(of: conditions) {
            updateMotion()
            if conditions.running { pacer.wake() }
        }
        .accessibilityElement()
        .accessibilityLabel("Imp")
        .accessibilityHint(interactive ? "Tilt your phone or tap it." : "")
        .accessibilityAddTraits(interactive ? .isButton : [])
        .accessibilityAction { if interactive { hop() } }
    }

    /// Follows the phone while the screen is showing, Reduce Motion is off, and the phone is not warm,
    /// at the sensor rate the policy gives.
    private func updateMotion() {
        if let interval = FramePolicy.motionInterval(conditions, decorative: true) { tilt.start(interval: interval) } else { tilt.stop() }
    }

    /// Tells the pacer what this frame found, so the next frames come as fast as they need to and no faster.
    private func frame(mood: Mood, state: TiltWatcher.State, date: Date) {
        pacer.note(mood: mood, of: imp.id, awake: mood != .sleepy, at: date)
        let acting = performance.map { date.timeIntervalSince($0.started) < $0.duration } ?? false
        pacer.settle(moving: !tilt.isSettled || acting || touch != nil || (flash.map { $0.until > date } ?? false),
                     empty: false, at: date)
    }

    private func mood(at date: Date, state: TiltWatcher.State) -> Mood {
        if let flash, flash.until > date { return flash.mood }
        if touch != nil { return .curious }
        if abs(state.lean) > 9 { return .excited }
        // Asleep, it dozes again once a hop is over.
        let hopping = performance.map { date.timeIntervalSince($0.started) < $0.duration } ?? false
        return asleep && !hopping ? .sleepy : .idle
    }

    private func hop() {
        performance = Performance(key: "hop-\(UUID())", steps: [AnticStep(duration: Motion.hopLength, mood: .happy, hop: true),
                                                              AnticStep(duration: 0.8, mood: .content)])
        pacer.wake()
        Haptics.tap(.soft)
    }
}

/// The phone's motion, read once for every screen that wants it: one `CMMotionManager`, started
/// when the first watcher attaches and stopped when the last one lets go (so the first screen and
/// an editor opened over it share it). It samples at the fastest rate any watcher asked for, and
/// the policy never asks for more than 30 Hz (`FramePolicy.motionInterval`).
@MainActor
final class TiltSource {
    static let shared = TiltSource()

    private(set) var gravity = (x: 0.0, y: -1.0, z: 0.0)
    /// The latest turn in the screen's plane (rad/s, + counterclockwise as you look at the screen), set before
    /// each sample goes to the listeners.
    private(set) var spin = 0.0
    /// How the phone is usually held (slowly follows the hand), so "level" is however you hold it.
    private(set) var rest: (y: Double, z: Double)?
    private let manager = CMMotionManager()
    private var listeners: [ObjectIdentifier: (_ acceleration: (x: Double, y: Double, z: Double), _ time: TimeInterval) -> Void] = [:]
    private var intervals: [ObjectIdentifier: TimeInterval] = [:]

    /// Starts the motion updates if nobody has, at `interval` seconds (or faster, if another watcher
    /// needs it). `onSample` gets the user acceleration (g) and the time of each sample.
    func attach(_ owner: AnyObject, interval: TimeInterval, onSample: @escaping (_ acceleration: (x: Double, y: Double, z: Double), _ time: TimeInterval) -> Void) {
        listeners[ObjectIdentifier(owner)] = onSample
        intervals[ObjectIdentifier(owner)] = interval
        manager.deviceMotionUpdateInterval = intervals.values.min() ?? interval
        guard manager.isDeviceMotionAvailable, !manager.isDeviceMotionActive else { return }
        manager.startDeviceMotionUpdates(to: .main) { [weak self] data, _ in
            guard let data else { return }
            let g = data.gravity, a = data.userAcceleration, t = data.timestamp, r = data.rotationRate
            MainActor.assumeIsolated {
                guard let self else { return }
                self.gravity = (g.x, g.y, g.z)
                self.spin = r.z
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
        intervals[ObjectIdentifier(owner)] = nil
        if listeners.isEmpty { manager.stopDeviceMotionUpdates() } else { manager.deviceMotionUpdateInterval = intervals.values.min() ?? manager.deviceMotionUpdateInterval }
    }
}

/// How the sideways pull of a tilt springs in and back (the same on the first screen and in the room).
enum TiltSpring {
    static let slideStiffness = 40.0
    static let slideDamping = 7.0
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
    /// The phone tipped far enough to be seen: the picture must be drawn smoothly now, not at the
    /// next slow frame.
    var onMove: (() -> Void)?
    private var seenSide = 0.0
    private var seenPitch = 0.0

    /// Held upright and still, which is what the Imp sees when it isn't following the phone.
    private var gravity: (x: Double, y: Double, z: Double) { running ? TiltSource.shared.gravity : (0, -1, 0) }
    private var rest: (y: Double, z: Double)? { running ? TiltSource.shared.rest : nil }
    private var running = false
    private var jolts = JoltDetector(threshold: 1.6)
    private var current = State()
    private var velocity = (lean: 0.0, slide: 0.0, x: 0.0, y: 0.0)
    private var last: Date?
    /// The Imp has come to rest: nothing is being pulled or still swinging. Updated by `state(at:)`.
    private(set) var isSettled = true

    func start(interval: TimeInterval) {
        running = true
        TiltSource.shared.attach(self, interval: interval) { [weak self] a, t in
            guard let self else { return }
            let (side, pitch) = aim
            if abs(side - seenSide) > Self.visible || abs(pitch - seenPitch) > Self.visible {
                (seenSide, seenPitch) = (side, pitch)
                onMove?()
            }
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

    /// How far the phone must tip (as the Imp's lean or look, -1...1) before the change shows.
    private static let visible = 0.02

    /// What the tilt asks of the Imp: tipped sideways, and tipped forwards or back (-1...1 each).
    private var aim: (side: Double, pitch: Double) {
        (max(-1, min(1, gravity.x * 1.6)),                             // tipped right: positive
         max(-1, min(1, ((gravity.z - (rest?.z ?? gravity.z)) - (gravity.y - (rest?.y ?? gravity.y))) * 2.2)))
    }

    /// Where the Imp is this frame: springs pulled toward what the tilt asks for, stepped by the real
    /// time since the last frame, so it moves the same at any frame rate and the sensor's own rate
    /// never shows.
    func state(at date: Date) -> State {
        let dt = last.map { date.timeIntervalSince($0) } ?? 0
        last = date
        let (side, pitch) = aim
        let target = (lean: side * Double(Behavior.tiltLean), slide: side * Double(Behavior.tiltSlide), x: side * 0.9, y: pitch * 0.8)
        func spring(_ value: Double, _ v: inout Double, to goal: Double, stiffness: Double = 60, damping: Double = 9) -> Double {
            var value = value
            SpringStep.advance(&value, velocity: &v, to: goal, stiffness: stiffness, damping: damping, dt: dt)
            return value
        }
        current.lean = spring(current.lean, &velocity.lean, to: target.lean)
        current.slide = CGFloat(spring(Double(current.slide), &velocity.slide, to: target.slide,
                                       stiffness: TiltSpring.slideStiffness, damping: TiltSpring.slideDamping))
        current.look = CGPoint(x: spring(current.look.x, &velocity.x, to: target.x, stiffness: 90, damping: 14),
                               y: spring(current.look.y, &velocity.y, to: target.y, stiffness: 90, damping: 14))
        // Resting means close to the goal and nearly stopped, which is when frames can slow down.
        let still = velocity.lean.magnitude + velocity.slide.magnitude + velocity.x.magnitude + velocity.y.magnitude < 2
        let there = abs(current.lean - target.lean) < 0.6 && abs(Double(current.slide) - target.slide) < 1
            && abs(current.look.x - target.x) < 0.03 && abs(current.look.y - target.y) < 0.03
        isSettled = still && there
        return current
    }
}
