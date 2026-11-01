import AppKit
import ImpKit
import SwiftUI

/// What the doors on a side of the desktop look like: one band per device, top to bottom.
struct DoorSign: Identifiable, Equatable {
    var id: UUID
    var name: String
    var kind: LinkKind
    /// The heights it covers, from `top` to `bottom` (0 is the top of the screen).
    var top: Double
    var bottom: Double
    /// The door a visiting Imp goes back through.
    var isBack: Bool
}

/// What the overlay shows. Only changes when the side, the bands or the band under the pointer do.
@MainActor @Observable
final class DoorBoard {
    var side: LinkSide
    var signs: [DoorSign]
    /// The device the pointer is in front of.
    var lit: UUID?
    var shown: Bool

    init(side: LinkSide = .left, signs: [DoorSign] = [], lit: UUID? = nil, shown: Bool = false) {
        self.side = side; self.signs = signs; self.lit = lit; self.shown = shown
    }
}

/// The doors along the edge of a display, while an Imp is carried towards it: a label per device at
/// the heights that lead to it, the one under the pointer lit. A side that leads nowhere says so, faintly.
struct DoorSignsView: View {
    let board: DoorBoard
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let side = board.side
        GeometryReader { geo in
            ZStack(alignment: side == .left ? .topLeading : .topTrailing) {
                if board.signs.isEmpty {
                    Text("Nobody here")
                        .font(.system(.footnote, design: .rounded, weight: .medium))
                        .foregroundStyle(Dungeon.cream.opacity(0.6))
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(.black.opacity(0.3), in: Capsule())
                        .frame(maxHeight: .infinity)
                }
                ForEach(board.signs) { sign in
                    band(sign, side: side, lit: board.lit == sign.id)
                        .frame(height: (sign.bottom - sign.top) * geo.size.height)
                        .offset(y: sign.top * geo.size.height)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: side == .left ? .topLeading : .topTrailing)
        }
        .padding(.horizontal, 6)
        .opacity(board.shown ? 1 : 0)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: board.shown)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: board.lit)
        .allowsHitTesting(false)
        // The "Send to" items of the Imp's menu offer the same choices.
        .accessibilityHidden(true)
    }

    /// One device's band: a thin strip down the edge and its name beside it.
    private func band(_ sign: DoorSign, side: LinkSide, lit: Bool) -> some View {
        let strip = Capsule()
            .fill(lit ? Dungeon.flame : Dungeon.ember.opacity(0.4))
            .frame(width: lit ? 5 : 3)
            .padding(.vertical, 6)
        let label = HStack(spacing: 5) {
            Image(systemName: sign.isBack ? "arrow.uturn.backward" : sign.kind == .mac ? "laptopcomputer" : "iphone")
                .font(.system(size: 11, weight: .semibold))
            Text(sign.isBack ? String(localized: "Back to \(sign.name)") : sign.name)
                .font(.system(.footnote, design: .rounded, weight: .semibold))
                .lineLimit(1)
        }
        .foregroundStyle(lit ? Dungeon.deep : Dungeon.cream)
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(lit ? Dungeon.flame : Color.black.opacity(0.4), in: Capsule())
        .frame(maxWidth: 190, alignment: side == .left ? .leading : .trailing)
        .scaleEffect(lit && !reduceMotion ? 1.06 : 1, anchor: side == .left ? .leading : .trailing)
        return HStack(spacing: 6) {
            if side == .left { strip; label } else { label; strip }
        }
    }
}

/// Shows the doors while the Imp is carried near an outer side of the desktop (see `Toss`). One
/// click-through panel, made when first needed, moved to the side and display the pointer is at.
/// It asks the link the same questions a throw does, so the labels say where a throw at that height goes.
@MainActor
final class DoorSigns {
    private let model: ImpModel
    private let board = DoorBoard()
    private var panel: FloatingPanel?
    private var fading: Task<Void, Never>?

    /// How close to a side the pointer must come for its doors to show, and how far it may drift
    /// back before they go (so they don't flicker at the boundary).
    private static let near: CGFloat = 200, leave: CGFloat = 240
    private static let width: CGFloat = 240

    init(model: ImpModel) { self.model = model }

    /// The Imp is carried with the pointer at `cursor`. Only a change of side, display, doors or lit door does any work.
    func carried(to cursor: CGPoint) {
        let app = model.app
        // As for a throw: edges are just edges until a device is linked.
        guard app.link.isLinked || model.visit != nil, !app.isAway(model.id),
              let approach = Toss.desktopApproach(cursor: cursor, within: board.shown ? Self.leave : Self.near,
                                                  screens: NSScreen.screens.map(\.frame)) else { return hide() }
        let side = approach.side
        let signs = app.link.bands(of: model.id, side: side).compactMap { band -> DoorSign? in
            guard let peer = app.link.peers.first(where: { $0.id == band.device }) else { return nil }
            return DoorSign(id: peer.id, name: peer.name, kind: peer.kind, top: band.top, bottom: band.bottom,
                            isBack: model.visit.map { $0.side == side && $0.from == peer.id } ?? false)
        }
        var lit: UUID?
        if case .to(let device) = app.link.door(of: model.id, side: side, height: approach.height) { lit = device }
        let screen = approach.screen
        let frame = CGRect(x: side == .left ? screen.minX : screen.maxX - Self.width, y: screen.minY,
                           width: Self.width, height: screen.height)
        let panel = self.panel ?? makePanel()
        if panel.frame != frame { panel.setFrame(frame, display: false) }
        if board.side != side { board.side = side }
        if board.signs != signs { board.signs = signs }
        if board.lit != lit { board.lit = lit }
        fading?.cancel()
        fading = nil
        if !panel.isVisible { panel.orderFrontRegardless() }
        if !board.shown { board.shown = true }
    }

    /// Fades the doors out and puts the panel away once they have.
    func hide() {
        guard board.shown, fading == nil else { return }
        board.shown = false
        let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        fading = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(reduce ? 0 : 220))
            guard let self, !Task.isCancelled else { return }
            self.panel?.orderOut(nil)
            self.fading = nil
        }
    }

    private func makePanel() -> FloatingPanel {
        let panel = FloatingPanel(size: CGSize(width: Self.width, height: 100))
        // Just under the carried Imp.
        panel.level = NSWindow.Level(rawValue: FloatingPanel.impLevel.rawValue - 1)
        panel.ignoresMouseEvents = true
        let host = NSHostingView(rootView: DoorSignsView(board: board))
        host.sizingOptions = []
        panel.contentView = host
        self.panel = panel
        return panel
    }
}
