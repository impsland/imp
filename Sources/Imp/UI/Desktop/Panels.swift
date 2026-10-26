import AppKit
import ImpKit
import SwiftUI

@MainActor
final class Panels {
    let model: ImpModel
    let impPanel: FloatingPanel
    let bubblePanel: FloatingPanel
    private let impHost: ImpHostingView
    private let bubbleHost: NSHostingView<BubbleView>
    /// Reused for measuring the bubble's natural size (building a fresh hosting view on every
    /// change, e.g. each dictation partial, was wasteful).
    private let measurer: NSHostingView<BubbleView>
    private let layout = BubbleLayout()
    private var bubbleVisible = false
    /// Builds the right-click menu for this Panels' Imp.
    var menuProvider: ((ImpModel) -> NSMenu)?

    static let baseSize: CGFloat = 112
    static let sizes: [(String, Double)] = [("Small", 0.75), ("Medium", 1.0), ("Large", 1.35)]

    init(model: ImpModel) {
        self.model = model
        let side = Self.baseSize * model.profile.scale
        impPanel = FloatingPanel(size: CGSize(width: side, height: side))
        bubblePanel = FloatingPanel(size: CGSize(width: 340, height: 100))
        bubblePanel.allowsKey = true
        // Bubble floats just above Imp (positioned manually, so Imp can slide independently).
        bubblePanel.level = NSWindow.Level(rawValue: FloatingPanel.impLevel.rawValue + 1)
        impHost = ImpHostingView(rootView: ImpView(model: model))
        impHost.clock = model.clock
        bubbleHost = NSHostingView(rootView: BubbleView(model: model, layout: layout))
        measurer = NSHostingView(rootView: BubbleView(model: model, layout: layout, measuring: true))
        // Panels are sized by hand: don't let SwiftUI re-derive sizes and constraints every frame
        // (that full layout pass was most of Imp's idle CPU).
        impHost.sizingOptions = []
        bubbleHost.sizingOptions = []
        impPanel.contentView = impHost
        bubblePanel.contentView = bubbleHost

        impHost.onClick = { [weak self] alternate, time in self?.clicked(alternate: alternate, at: time) }
        impHost.onHandling = { [weak self] handling in self?.handled(handling) }
        impHost.menuProvider = { [weak self] in
            guard let self else { return NSMenu() }
            return self.menuProvider?(self.model) ?? NSMenu()
        }
        impHost.onMouseMoved = { [weak model] in model?.app.reactions.mouseMoved() }
        // Drag a picture onto Imp: a text box opens with it attached, for you to say what to do.
        impHost.registerForDraggedTypes(Pasteboard.pictureTypes)
        impHost.onPictureHover = { [weak model] over in model?.pictureHover(over) }
        impHost.onDropPicture = { [weak model] pb in
            guard let model, let picture = Pasteboard.picture(dropped: pb) else { return false }
            model.receive(picture)
            return true
        }

        model.onBubbleChange = { [weak self] in self?.layoutBubble() }
        layout.onToggle = { [weak self] in self?.layoutBubble() }
        layout.onDrag = { [weak self] ended in self?.dragBubble(ended: ended) }
        layout.onResize = { [weak self] edges, ended in self?.resizeBubble(edges, ended: ended) }
        model.onScaleChange = { [weak self] in self?.applyScale() }
        model.onRestingChange = { [weak self] resting in self?.impHost.setBreathing(resting) }
        NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification, object: bubblePanel, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.bubbleMoved() }
        }
        NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification, object: impPanel, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.impMoved() }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.placeImp() }
        }
        placeImp()
    }

    var isImpVisible: Bool { impPanel.isVisible }

    // MARK: Clicks
    //
    // A click talks, a double-click opens settings, four quick clicks are a poke: one thing per
    // burst. See `ClickBurst` for why clicks wait for the burst to end.

    private var clicks = ClickBurst(interval: ClickBurst.gap(system: NSEvent.doubleClickInterval))
    private var settling: Task<Void, Never>?
    /// ⌥ was held on the burst's first click (⌥-click swaps talking and typing).
    private var alternateBurst = false

    private func clicked(alternate: Bool, at time: TimeInterval) {
        let interval = ClickBurst.gap(system: NSEvent.doubleClickInterval)   // the user may change it in System Settings
        if clicks.interval != interval { clicks = ClickBurst(interval: interval) }
        if clicks.click(at: time) == .flurry { model.flurry() }
        if clicks.count == 1 { alternateBurst = alternate }
        settling?.cancel()
        settling = Task { [weak self] in
            try? await Task.sleep(for: .seconds(interval))
            guard let self, !Task.isCancelled else { return }
            switch self.clicks.settle(at: ProcessInfo.processInfo.systemUptime) {
            case .single: self.model.click(alternate: self.alternateBurst)
            case .double: self.model.doubleClicked()
            case .flurry, nil: break
            }
        }
    }

    // MARK: Pressing and carrying

    /// Brings the Imp back upright once a carry stops moving (drags send no events while still).
    private var steady: Task<Void, Never>?

    private func handled(_ handling: ImpHostingView.Handling) {
        let reactions = model.app.reactions
        switch handling {
        case .pressed:
            reactions.pressed(model)
        case .held:
            reactions.handle(.hold, by: model, held: true)
        case .unheld:
            reactions.release(.hold, by: model)
        case .lifted:
            reactions.handle(.pickUp, by: model, held: true)
        case .carried(let speed):
            // It dangles from the cursor: the body lags behind, so it leans the way it's going.
            model.carryLean = max(-14, min(14, Double(speed) * 0.012))
            steady?.cancel()
            steady = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(120))
                if !Task.isCancelled { self?.model.carryLean = 0 }
            }
        case .shaken:
            reactions.handle(.shake, by: model)
        case .dropped(let distance):
            steady?.cancel()
            model.carryLean = 0
            reactions.release(.pickUp, by: model)
            restOrigin = nil                // the user placed Imp, so don't slide it back
            savePosition()
            // A new spot: say hello to anyone there, else land and look around.
            if distance > 40 && model.app.stage.arrived(model) { return }
            reactions.handle(.drop, by: model)
        }
    }

    func show() {
        impPanel.orderFrontRegardless()
        layoutBubble()
    }

    func hide() {
        bubblePanel.orderOut(nil)
        impPanel.orderOut(nil)
    }

    /// For good: this Imp left the troupe.
    func close() {
        hide()
        NotificationCenter.default.removeObserver(self)
        model.onBubbleChange = nil
        model.onScaleChange = nil
        model.onRestingChange = nil
    }

    /// Glides Imp to `origin` (e.g. back into the app's window), bubble put away first.
    func fly(to origin: CGPoint, then done: @escaping @MainActor () -> Void) {
        model.dismissBubble()
        restOrigin = nil
        impTarget = origin
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.42
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.3, 0.9, 0.35, 1.05)
            impPanel.animator().setFrameOrigin(origin)
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                self?.impTarget = nil
                done()
            }
        })
    }

    func applyScale() {
        let side = Self.baseSize * model.profile.scale
        var f = impPanel.frame
        let center = CGPoint(x: f.midX, y: f.minY)
        f.size = CGSize(width: side, height: side)
        f.origin = CGPoint(x: center.x - side / 2, y: center.y)
        impPanel.setFrame(f, display: true)
        if impHost.isBreathing { impHost.setBreathing(true) }      // the breath is sized to the panel
    }

    private func placeImp() {
        let side = impPanel.frame.width
        let screen = NSScreen.main ?? NSScreen.screens.first
        let visible = screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        // Newcomers line up to the left of the troupe, along the bottom of the screen.
        let seat = CGFloat(model.app.prefs.imps.firstIndex { $0.id == model.id } ?? 0)
        let home = CGPoint(x: max(visible.minX + 8, visible.maxX - side - 28 - seat * (Self.baseSize + 16)), y: visible.minY + 20)
        var origin = model.profile.origin ?? home
        // If the saved spot is off-screen now (monitor unplugged), come back home.
        let rect = CGRect(origin: origin, size: CGSize(width: side, height: side))
        if !NSScreen.screens.contains(where: { $0.visibleFrame.intersects(rect.insetBy(dx: side / 3, dy: side / 3)) }) {
            origin = home
        }
        impPanel.setFrameOrigin(origin)
        impMoved()
    }

    private func savePosition() {
        let o = impPanel.frame.origin
        if let i = model.app.prefs.imps.firstIndex(where: { $0.id == model.id }) { model.app.prefs.imps[i].origin = o }
    }

    private func impMoved() {
        let f = impPanel.frame
        model.impFrame = f
        positionBubble()
    }

    // MARK: Bubble sizing & placement
    //
    // The bubble sits ABOVE Imp and never covers it. It's sized by measuring (a separate hosting
    // view, since the live one isn't asked for sizes). A long reply shows its first lines with
    // "Read all". Read in full, the card widens and the text scrolls within the room there is.
    // Imp politely scoots down if that's what it takes. There's always headroom for the ✕, and
    // the ✕ moves to whichever corner is on screen. Drag the bubble away and it stays put.

    /// Where Imp lives when it isn't making room for a bubble.
    private var restOrigin: CGPoint?
    private var previousApp: NSRunningApplication?
    /// Where Imp is animating to (so the bubble is placed for the final position, not mid-slide).
    private var impTarget: CGPoint?
    /// The bubble the current layout belongs to (a new one starts collapsed and attached).
    private var laidOutBubble: UUID?
    /// True while we move the bubble ourselves (so it isn't mistaken for the user dragging it).
    private var placingBubble = false
    private static let overlap: CGFloat = 10        // trail tip dips just below the horns
    /// Space kept above the card for the floating ✕.
    private static let headroom: CGFloat = 22
    /// A long reply shows this much text before "Read all" (about ten lines).
    private static let collapsedText: CGFloat = 210
    /// Read in full: at most this tall (until the user resizes it).
    private static let maxReading: CGFloat = 560
    /// Resized by hand: the text area and card can get this small (then the text scrolls).
    private static let minText: CGFloat = 36, minWidth: CGFloat = 240

    /// The highest the bubble panel's top may go and keep the ✕ on screen.
    private func panelTopLimit(_ screen: CGRect) -> CGFloat { screen.maxY + BubbleView.margin - Self.headroom }

    /// How tall the bubble panel can be when Imp's panel bottom sits at `impY`.
    private func roomAbove(impY: CGFloat, impHeight: CGFloat, screen: CGRect) -> CGFloat {
        panelTopLimit(screen) - (impY + impHeight - Self.overlap - BubbleView.margin + 4)
    }

    func layoutBubble() {
        guard let bubble = model.bubble, impPanel.isVisible else {
            hideBubble()
            return
        }
        if laidOutBubble != bubble.id {
            laidOutBubble = bubble.id
            layout.expanded = false
            layout.detached = false
            layout.customWidth = nil
            layout.customTextHeight = nil
            layout.showSteps = false
            layout.openSteps = []
            layout.chatPages = 1
        }
        let screen = (impPanel.screen ?? NSScreen.main)?.visibleFrame ?? .infinite
        var imp = impPanel.frame
        if let impTarget { imp.origin = impTarget }
        let rest = restOrigin ?? imp.origin

        // Measure: the whole bubble, and the bubble without its reply text (its "chrome").
        let natural = measure(limit: nil)
        var size = natural
        var limit: CGFloat?
        if bubble.phase == .result, !bubble.text.isEmpty {
            let chrome = measure(limit: 0).height
            let text = natural.height - chrome
            // The most text that fits: above Imp if it scoots all the way down (or, for a bubble
            // the user moved, the whole screen height).
            let most = (layout.detached ? screen.height - Self.headroom
                                        : roomAbove(impY: screen.minY, impHeight: imp.height, screen: screen)) - chrome
            if layout.expanded, let custom = layout.customTextHeight {
                // Sized by the user: exactly that (roomier than the text, or scrolling).
                limit = max(Self.minText, min(custom, most))
                size = measure(limit: limit)
            } else if text > min(layout.expanded ? Self.maxReading : Self.collapsedText, most) {
                let cap = min(layout.expanded ? Self.maxReading : Self.collapsedText, most)
                limit = max(40, cap)
                size = measure(limit: limit)
            } else if layout.expanded {
                layout.expanded = false              // it all fits now: no need for reading mode
                size = measure(limit: nil)
            }
        }
        layout.textLimit = limit

        if layout.detached {
            // The user placed it: Imp can go home, and the bubble keeps its top edge where it is.
            if let r = restOrigin { restOrigin = nil; moveImp(to: r) }
            var frame = bubblePanel.frame
            frame.origin.y = frame.maxY - size.height
            frame.size = size
            setBubbleFrame(clamped(frame, to: screen))
        } else {
            // Make room above Imp if needed.
            let needed = size.height - roomAbove(impY: rest.y, impHeight: imp.height, screen: screen)
            let target = CGPoint(x: rest.x, y: needed > 0 ? max(screen.minY, rest.y - needed) : rest.y)
            if target != imp.origin {
                if restOrigin == nil { restOrigin = imp.origin }
                moveImp(to: target)
                imp.origin = target
            } else if needed <= 0, let r = restOrigin, r == imp.origin {
                restOrigin = nil
            }
            placingBubble = true
            bubblePanel.setContentSize(size)
            placingBubble = false
            positionBubble()
        }

        if !bubbleVisible {
            bubbleVisible = true
            bubblePanel.alphaValue = 0
            bubblePanel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.18
                bubblePanel.animator().alphaValue = 1
            }
        }
        updateKeyFocus(for: bubble)
    }

    /// Follows the pointer while the user drags the card (see `BubbleCard`).
    private var dragAnchor: (mouse: CGPoint, origin: CGPoint)?

    private func dragBubble(ended: Bool) {
        guard !ended else { dragAnchor = nil; return }
        let m = NSEvent.mouseLocation
        if dragAnchor == nil { dragAnchor = (m, bubblePanel.frame.origin) }
        guard let a = dragAnchor else { return }
        bubblePanel.setFrameOrigin(CGPoint(x: a.origin.x + m.x - a.mouse.x, y: a.origin.y + m.y - a.mouse.y))
    }

    /// Resizing a long reply in reading mode by its edges or corners. The opposite sides stay put,
    /// the width re-wraps the text, the height is the text area (taller than the text leaves room,
    /// smaller scrolls). Any size within the screen.
    private var resizeAnchor: (mouse: CGPoint, frame: CGRect, width: CGFloat, text: CGFloat)?

    private func resizeBubble(_ edges: Edge.Set, ended: Bool) {
        guard !ended else { resizeAnchor = nil; return }
        let m = NSEvent.mouseLocation
        if resizeAnchor == nil { resizeAnchor = (m, bubblePanel.frame, layout.width, layout.textLimit ?? Self.collapsedText) }
        guard let a = resizeAnchor else { return }
        let screen = (bubblePanel.screen ?? NSScreen.main)?.visibleFrame ?? .infinite
        let dx = m.x - a.mouse.x, dy = m.y - a.mouse.y
        var width = a.width, text = a.text
        if edges.contains(.leading) { width -= dx }
        if edges.contains(.trailing) { width += dx }
        if edges.contains(.top) { text += dy }
        if edges.contains(.bottom) { text -= dy }
        // A resized bubble is the user's: it stays where it is, and Imp can go home.
        layout.detached = true
        if let r = restOrigin { restOrigin = nil; moveImp(to: r) }
        layout.customWidth = min(max(width, Self.minWidth), screen.width - 2 * BubbleView.margin)
        let chrome = measure(limit: 0).height
        text = min(max(text, Self.minText), screen.height - chrome - Self.headroom)
        layout.customTextHeight = text
        layout.textLimit = text
        let size = measure(limit: text)
        var frame = CGRect(origin: .zero, size: size)
        frame.origin.x = edges.contains(.leading) ? a.frame.maxX - size.width : a.frame.minX
        frame.origin.y = edges.contains(.top) ? a.frame.minY : a.frame.maxY - size.height   // keep the sides you're not dragging
        setBubbleFrame(clamped(frame, to: screen))
    }

    /// The user dragged the bubble: it's theirs to place now.
    private func bubbleMoved() {
        guard !placingBubble, bubbleVisible, !layout.detached else {
            if layout.detached { updateCloseCorner() }
            return
        }
        layout.detached = true
        if let r = restOrigin { restOrigin = nil; moveImp(to: r) }
        updateCloseCorner()
    }

    private func setBubbleFrame(_ frame: CGRect) {
        placingBubble = true
        bubblePanel.setFrame(frame, display: true)
        placingBubble = false
        updateCloseCorner()
    }

    /// Keeps the card (not its transparent margins) within the screen, with headroom for the ✕.
    private func clamped(_ frame: CGRect, to screen: CGRect) -> CGRect {
        var f = frame
        let m = BubbleView.margin
        f.origin.x = min(max(f.origin.x, screen.minX - m + 4), screen.maxX - f.width + m - 4)
        f.origin.y = min(max(f.origin.y, screen.minY - m), panelTopLimit(screen) - f.height)
        return f
    }

    /// Puts the ✕ in a corner that's on screen: outside top-right by default, top-left near the
    /// right edge, tucked inside when the card touches the top of the screen.
    private func updateCloseCorner() {
        let screen = (bubblePanel.screen ?? impPanel.screen ?? NSScreen.main)?.visibleFrame ?? .infinite
        let card = bubblePanel.frame.insetBy(dx: BubbleView.margin, dy: BubbleView.margin)
        let corner: BubbleLayout.CloseCorner =
            screen.maxY - card.maxY < 18 ? .inside : screen.maxX - card.maxX < 14 ? .outsideLeading : .outsideTrailing
        if layout.closeCorner != corner { layout.closeCorner = corner }
    }

    /// The bubble's size with its reply text limited to `limit` (nil = all of it).
    private func measure(limit: CGFloat?) -> CGSize {
        let probe = layout.copy()
        probe.textLimit = limit
        measurer.rootView = BubbleView(model: model, layout: probe, measuring: true)
        return measurer.fittingSize
    }

    /// Typing (in the bubble, or in the chat) needs keyboard focus. Give it back to the app you
    /// were in afterwards.
    private func updateKeyFocus(for bubble: Bubble) {
        if bubble.phase == .typing || bubble.phase == .chat {
            if !bubblePanel.isKeyWindow {
                let front = NSWorkspace.shared.frontmostApplication
                if front?.processIdentifier != ProcessInfo.processInfo.processIdentifier { previousApp = front }
                bubblePanel.makeKeyAndOrderFront(nil)
            }
        } else if bubblePanel.isKeyWindow, let app = previousApp {
            previousApp = nil
            app.activate()
        }
    }

    private func moveImp(to origin: CGPoint) {
        impTarget = origin
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.28
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.3, 1.25, 0.5, 1)   // a little bounce
            impPanel.animator().setFrameOrigin(origin)
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.impTarget == origin else { return }
                self.impTarget = nil
                self.impMoved()
            }
        })
    }

    private func hideBubble() {
        if bubblePanel.isKeyWindow, let app = previousApp { previousApp = nil; app.activate() }
        if let r = restOrigin {
            restOrigin = nil
            moveImp(to: r)
        }
        guard bubbleVisible else { return }
        bubbleVisible = false
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.15
            bubblePanel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.bubbleVisible else { return }
                self.bubblePanel.orderOut(nil)
            }
        })
    }

    private func positionBubble() {
        guard !layout.detached else { return }
        var imp = impPanel.frame
        if let impTarget { imp.origin = impTarget }
        let size = bubblePanel.frame.size
        let screen = (impPanel.screen ?? NSScreen.main)?.visibleFrame ?? .infinite
        var x = imp.midX - size.width / 2
        x = min(max(x, screen.minX + 4), screen.maxX - size.width - 4)
        // The trail's tip sits just above Imp's horns. Never lower (it would cover Imp). Only a
        // bubble taller than the whole screen is pushed down, and then the ✕ still stays visible.
        let y = min(imp.maxY - Self.overlap - BubbleView.margin + 4, panelTopLimit(screen) - size.height)
        placingBubble = true
        bubblePanel.setFrameOrigin(CGPoint(x: x, y: y))
        placingBubble = false
        layout.tailX = imp.midX - (x + size.width / 2)
        updateCloseCorner()
    }
}
