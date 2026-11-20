import ImpDesign
import ImpKit
import SwiftUI

/// An Imp's right-click menu, the same on the desktop, in the app's window and for a visitor: the Imp in its circle
/// with its name and status, six big buttons in a 2 × 3 grid (Talk, Message, Chat, then Hide, where it is, and
/// Settings), its size and its colour, then `extra`: the rows that only sometimes apply (Stop, triggers, devices,
/// sharing, Goodbye, see `ImpMenuEnd`), as buttons too (see `MenuCard`). A visitor's settings and looks belong to
/// its home, so it has New chat where the others have Settings, and no size or colour.
struct ImpMenuCard<Extra: View>: View {
    typealias Place = ImpMenuPlace
    typealias Action = ImpMenuAction

    let ready: Bool
    let name: String
    let status: String
    let place: Place
    /// False for a visitor whose home is away: it can't be asked anything now.
    let awake: Bool
    /// Runs an action. The six buttons close the menu first. Size and colour change at once and leave it open.
    let run: (Action) -> Void
    let extra: Extra
    @State private var hue: Double
    @State private var scale: Double

    init(ready: Bool, name: String, status: String, hue: Double, scale: Double, place: Place, awake: Bool = true,
         run: @escaping (Action) -> Void, @ViewBuilder extra: () -> Extra) {
        self.ready = ready
        self.awake = awake
        self.name = name
        self.status = status
        self.place = place
        self.run = run
        self.extra = extra()
        _hue = State(initialValue: hue)
        _scale = State(initialValue: scale)
    }

    /// Talk, Message, Chat, then Hide, the place button, and Settings (a visitor's New chat). A visitor that is asleep
    /// can't be asked or started a chat with, and says why.
    var buttons: [MenuItem] {
        let asleep = place.isVisitor && !awake
        let why: String
        if case .visitor(let home) = place { why = String(localized: "\(name) is asleep: \(home) is away") } else { why = "" }
        func ask(_ item: MenuItem) -> MenuItem {
            var item = item
            if asleep { item.enabled = false; item.help = why }
            return item
        }
        let fifth: MenuItem
        switch place {
        case .desktop:
            fifth = MenuItem(id: "move", icon: "house.fill", title: String(localized: "menu.imp.send_home"),
                             help: words("menu.imp.send_home_help", name)) { run(.move) }
        case .home:
            fifth = MenuItem(id: "move", icon: "arrow.up.forward.square.fill", title: String(localized: "menu.imp.let_out"),
                             help: words("menu.imp.let_out_help", name)) { run(.move) }
        case .visitor(let home):
            fifth = MenuItem(id: "move", icon: "house.fill", title: String(localized: "menu.imp.send_home"),
                             help: String(localized: "\(name) flies back to \(home). If it is away, \(name) goes now and \(home) hears when it is back.")) { run(.move) }
        }
        let sixth = place.isVisitor
            ? ask(MenuItem(id: "new", icon: "plus.bubble.fill", title: String(localized: "New Chat")) { run(.newChat) })
            : MenuItem(id: "settings", icon: "slider.horizontal.3", title: String(localized: "menu.imp.settings"),
                       help: words("menu.imp.settings_help", name)) { run(.settings) }
        return [
            ask(MenuItem(id: "talk", icon: "bubble.left.fill", title: String(localized: "menu.imp.talk"), help: words("menu.imp.talk_help", name)) { run(.talk) }),
            ask(MenuItem(id: "message", icon: "message.fill", title: String(localized: "menu.imp.message"),
                         help: words("menu.imp.message_help", name)) { run(.message) }),
            MenuItem(id: "chat", icon: "bubble.left.and.bubble.right.fill", title: String(localized: "menu.imp.chat"),
                     help: words("menu.imp.chat_help", name)) { run(.chat) },
            MenuItem(id: "hide", icon: "eye.slash.fill", title: String(localized: "menu.imp.hide"), help: words("menu.imp.hide_help", name)) { run(.hide) },
            fifth,
            sixth,
        ]
    }

    var body: some View {
        MenuCard {
            ImpMenuHeader(ready: ready, name: name, status: status, hue: hue)
            MenuGrid(items: buttons)
            if !place.isVisitor {
                VStack(spacing: MenuMetrics.inset) {
                    SizeRow(scale: scale, hue: hue) { scale = $0; run(.size($0)) }
                    ColourRow(hue: hue) { hue = $0; run(.colour($0)) }
                }
            }
            extra
        }
        .environment(\.impTint, Color.imp(hue))
    }
}

/// Where the Imp is: the fifth button of its menu sends it home from the desktop, lets it out of the window, or
/// (for a visitor, from the device it came from) flies it back there.
enum ImpMenuPlace: Equatable {
    case desktop, home
    case visitor(from: String)

    var isVisitor: Bool { if case .visitor = self { true } else { false } }
}

/// What a button of an Imp's menu does.
enum ImpMenuAction {
    case talk, message, chat, hide, move, settings, newChat
    case size(Double)
    case colour(Double)
}

extension ImpMenuCard where Extra == EmptyView {
    init(ready: Bool, name: String, status: String, hue: Double, scale: Double, place: Place, awake: Bool = true,
         run: @escaping (Action) -> Void) {
        self.init(ready: ready, name: name, status: status, hue: hue, scale: scale, place: place, awake: awake, run: run, extra: { EmptyView() })
    }
}

/// The end of an own Imp's menu, the same on the desktop and in the window: sharing it (Copy kit, Copy link),
/// then Goodbye, last and apart.
struct ImpMenuEnd: View {
    let canLink: Bool
    let canGoodbye: Bool
    let kit: () -> Void
    let link: () -> Void
    let goodbye: () -> Void

    var body: some View {
        MenuPills(items: [
            MenuItem(id: "kit", icon: "shippingbox.fill", title: String(localized: "menu.imp.copy_kit"), action: kit),
            MenuItem(id: "link", icon: "link", title: String(localized: "menu.imp.copy_link"), enabled: canLink, action: link),
        ])
        MenuDangerButton(item: MenuItem(id: "goodbye", icon: "hand.wave.fill", title: String(localized: "menu.imp.goodbye"),
                                        enabled: canGoodbye, action: goodbye))
    }
}

/// The Imp in its circle, its name and its status: the top of its menu.
struct ImpMenuHeader: View {
    let ready: Bool
    let name: String
    let status: String
    let hue: Double

    var body: some View {
        HStack(spacing: Spacing.cozy) {
            ImpBadge(ready: ready, hue: hue, side: BubbleMetrics.portrait)
            VStack(alignment: .leading, spacing: Spacing.hairline) {
                Text(verbatim: name).font(Typeface.cardTitle).foregroundStyle(Tone.text).lineLimit(1)
                HStack(spacing: Spacing.snug) {
                    Circle().fill(ready ? Tone.good : Tone.accent).frame(width: BubbleMetrics.pip, height: BubbleMetrics.pip)
                    Text(verbatim: status).font(Typeface.small).foregroundStyle(Tone.muted).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Small, medium and large: a dot that grows, in a pebble each. The chosen one is filled with the Imp's colour.
/// `scale` is nil for a group whose Imps differ: then none is chosen.
struct SizeRow: View {
    let scale: Double?
    let hue: Double
    let pick: (Double) -> Void

    /// The dots of the three sizes, small to large.
    private static let dots: [CGFloat] = [6, 10, 15]

    var body: some View {
        HStack(spacing: MenuMetrics.inset) {
            ForEach(Array(Panels.sizes.enumerated()), id: \.offset) { index, size in
                let picked = scale.map { abs($0 - size.1) < 0.01 } ?? false
                let dot = Self.dots[min(index, Self.dots.count - 1)]
                Button { pick(size.1) } label: {
                    Circle()
                        .fill(picked ? AnyShapeStyle(OnTint(Color.imp(hue))) : AnyShapeStyle(Tone.text))
                        .frame(width: dot, height: dot)
                        .frame(maxWidth: .infinity, minHeight: Sizing.control)
                        .background(picked ? AnyShapeStyle(TintFill(Color.imp(hue))) : AnyShapeStyle(Color.clear),
                                    in: RoundedRectangle(cornerRadius: Radius.tile, style: .continuous))
                }
                .buttonStyle(PebbleButtonStyle())
                .help(size.0)
                .accessibilityLabel(Text(verbatim: size.0))
                .accessibilityAddTraits(picked ? .isSelected : [])
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Size"))
    }
}

/// Every colour as a dot. The chosen one wears a tick. `hue` is nil for a group whose Imps differ.
struct ColourRow: View {
    let hue: Double?
    let pick: (Double) -> Void

    private static let swatch: CGFloat = 18

    var body: some View {
        HStack(spacing: 0) {
            ForEach(ImpProfile.colors, id: \.hue) { colour in
                let picked = hue.map { abs($0 - colour.hue) < 0.005 } ?? false
                Button { pick(colour.hue) } label: {
                    let tint = Color.imp(colour.hue)
                    Circle()
                        .fill(picked ? AnyShapeStyle(TintFill(tint)) : AnyShapeStyle(tint))
                        .frame(width: Self.swatch, height: Self.swatch)
                        .overlay {
                            if picked {
                                Image(systemName: "checkmark").font(.icon(.tiny, weight: .heavy)).foregroundStyle(OnTint(tint))
                            }
                        }
                        .frame(maxWidth: .infinity, minHeight: Self.swatch + MenuMetrics.inset)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(colour.name)
                .accessibilityLabel(Text(verbatim: colour.name))
                .accessibilityAddTraits(picked ? .isSelected : [])
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Colour"))
    }
}

/// The menu of several Imps picked together (`ImpPicks`): their faces and how many, what applies to all of them
/// at once, their size and colour (a choice shows only when every Imp has it), then `extra` (Brain, Goodbye).
struct GroupMenuCard<Extra: View>: View {
    typealias Action = GroupMenuAction

    let names: [String]
    let hues: [Double]
    let run: (Action) -> Void
    let extra: Extra
    @State private var scale: Double?
    @State private var hue: Double?

    init(names: [String], hues: [Double], scales: [Double], run: @escaping (Action) -> Void, @ViewBuilder extra: () -> Extra) {
        self.names = names
        self.hues = hues
        self.run = run
        self.extra = extra()
        _scale = State(initialValue: Set(scales).count == 1 ? scales.first : nil)
        _hue = State(initialValue: Set(hues).count == 1 ? hues.first : nil)
    }

    /// How many faces overlap in the header.
    private static var faces: Int { 3 }

    var body: some View {
        MenuCard {
            HStack(spacing: Spacing.cozy) {
                HStack(spacing: -BubbleMetrics.portrait * 0.55) {
                    ForEach(Array((hue.map { h in hues.map { _ in h } } ?? hues).prefix(Self.faces).enumerated()), id: \.offset) { _, h in
                        ImpBadge(ready: true, hue: h, side: BubbleMetrics.portrait * 0.8)
                    }
                }
                VStack(alignment: .leading, spacing: Spacing.hairline) {
                    Text(words("menu.group.title", names.count)).font(Typeface.cardTitle).foregroundStyle(Tone.text).lineLimit(1)
                    Text(verbatim: names.formatted(.list(type: .and, width: .narrow)))
                        .font(Typeface.small).foregroundStyle(Tone.muted).lineLimit(1).truncationMode(.tail)
                }
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .combine)
            MenuGrid(items: [
                MenuItem(id: "hide", icon: "eye.slash.fill", title: String(localized: "menu.imp.hide"),
                         help: String(localized: "menu.group.hide_help")) { run(.hide) },
                MenuItem(id: "let_out", icon: "arrow.up.forward.square.fill", title: String(localized: "menu.imp.let_out"),
                         help: String(localized: "menu.group.let_out_help")) { run(.letOut) },
                MenuItem(id: "kit", icon: "shippingbox.fill", title: String(localized: "menu.imp.copy_kit"),
                         help: String(localized: "menu.group.kit_help")) { run(.kit) },
            ])
            VStack(spacing: MenuMetrics.inset) {
                SizeRow(scale: scale, hue: hue ?? hues.first ?? 0) { scale = $0; run(.size($0)) }
                ColourRow(hue: hue) { hue = $0; run(.colour($0)) }
            }
            extra
        }
    }
}

/// What a button of the group's menu does.
enum GroupMenuAction { case hide, letOut, kit, size(Double), colour(Double) }

extension GroupMenuCard where Extra == EmptyView {
    init(names: [String], hues: [Double], scales: [Double], run: @escaping (Action) -> Void) {
        self.init(names: names, hues: hues, scales: scales, run: run, extra: { EmptyView() })
    }
}

/// An Imp in a soft circle of its own colour, centred by its drawing (horns included) rather than by its square:
/// an Imp stands on the floor of its square, so the square's middle sits above the Imp's.
struct ImpBadge: View {
    let ready: Bool
    let hue: Double
    let side: CGFloat

    /// Draws the Imp larger, with the horns scaled down so they keep their previous on-screen size.
    static func portrait(ready: Bool, hue: Double) -> Face {
        var f = Face.settled(ready ? .idle : .sad, lookX: 0.35, lookY: 0.25)
        f.hornSize *= 46.0 / 54.0
        f.hue = hue
        return f
    }

    /// How far down the drawing must move to be centred in its square, as a share of the side. Negative moves up.
    static func centring(_ face: Face) -> CGFloat {
        let middle = (ImpRenderer.restingTop(face) + ImpRenderer.size.bottom) / 2
        return CGFloat(50 - middle) / 100
    }

    var body: some View {
        let face = Self.portrait(ready: ready, hue: hue)
        ImpPortrait(face: face, shadow: false)
            .frame(width: side, height: side)
            .offset(y: Self.centring(face) * side)
            .frame(width: side, height: side)
            .background(Circle().fill(Color.imp(hue).opacity(Opacity.tintFill)).padding(Spacing.hairline))
            .accessibilityHidden(true)
    }
}
