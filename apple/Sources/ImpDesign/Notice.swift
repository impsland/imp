import SwiftUI

// How a result is shown without moving anything (spec `notice`): a button that carries its own state,
// a floating message over the bottom of the container, and a line of fixed height that swaps words.

/// Where an action that takes a moment is: waiting to start, running, or just finished.
public enum ActionState: Equatable, Sendable {
    case idle, working, done, failed

    /// How long a finished state stays before it goes back to idle. Nil while it has nothing to reset.
    public var resetDelay: Duration? {
        switch self {
        case .done, .failed: .seconds(Behavior.noticeSeconds)
        case .idle, .working: nil
        }
    }

    /// The symbol that replaces the button's own icon while it is not idle. Nil while running: a wheel is drawn.
    var symbol: String? {
        switch self {
        case .done: "checkmark"
        case .failed: "xmark"
        case .idle, .working: nil
        }
    }

    /// Settles a result into `done` or `failed`.
    public static func result(_ ok: Bool) -> ActionState { ok ? .done : .failed }
}

private struct ActionStateReset: ViewModifier {
    @Binding var state: ActionState

    func body(content: Content) -> some View {
        content.task(id: state) {
            guard let delay = state.resetDelay else { return }
            try? await Task.sleep(for: delay)
            if !Task.isCancelled { state = .idle }
        }
    }
}

extension View {
    /// Sends a finished `ActionState` back to idle after `Behavior.noticeSeconds`. Put it on the button.
    public func impActionState(_ state: Binding<ActionState>) -> some View {
        modifier(ActionStateReset(state: state))
    }
}

/// A button's label whose icon becomes a progress wheel, then a tick or a cross, in a frame of the
/// icon's own size, so the button never changes size.
public struct StatefulLabel: View {
    let title: Text?
    let symbol: String
    let state: ActionState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(_ title: LocalizedStringKey, symbol: String, state: ActionState) {
        self.title = Text(title); self.symbol = symbol; self.state = state
    }

    /// An icon-only button.
    public init(symbol: String, state: ActionState) {
        self.title = nil; self.symbol = symbol; self.state = state
    }

    public var body: some View {
        Group {
            if let title {
                ViewThatFits(in: .horizontal) {
                    row(title: title)
                    row(title: nil)
                }
                .help(title)
            } else {
                row(title: nil)
            }
        }
        .animation(Motion.quick.reducedAware(reduceMotion), value: state)
        .accessibilityValue(Text(verbatim: Self.spoken(state)))
    }

    private func row(title words: Text?) -> some View {
        HStack(spacing: Spacing.tight) {
            ZStack {
                switch state {
                case .working:
                    ProgressView().controlSize(.small).transition(.opacity)
                case .done, .failed:
                    Image(systemName: state.symbol ?? symbol).font(.icon(.small))
                        .foregroundStyle(state == .done ? Tone.good : Tone.danger).transition(.opacity)
                case .idle:
                    Image(systemName: symbol).font(.icon(.small)).transition(.opacity)
                }
            }
            .frame(width: IconSize.small.points, height: IconSize.small.points)
            .accessibilityHidden(true)
            if let words { words.lineLimit(1).fixedSize() }
        }
    }

    private static func spoken(_ state: ActionState) -> String {
        switch state {
        case .idle: ""
        case .working: String(localized: "common.action_working")
        case .done: String(localized: "common.action_done")
        case .failed: String(localized: "common.action_failed")
        }
    }
}

/// A message that floats over the bottom of a container.
public struct ImpNotice: Equatable, Identifiable, Sendable {
    public enum Kind: Sendable { case info, success, warning, error }
    public let id = UUID()
    public let kind: Kind
    public let text: String

    public init(_ kind: Kind, _ text: String) { self.kind = kind; self.text = text }
    public static func info(_ text: String) -> ImpNotice { .init(.info, text) }
    public static func success(_ text: String) -> ImpNotice { .init(.success, text) }
    public static func warning(_ text: String) -> ImpNotice { .init(.warning, text) }
    public static func error(_ text: String) -> ImpNotice { .init(.error, text) }

    var symbol: String {
        switch kind {
        case .info: "info.circle.fill"
        case .success: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .error: "xmark.octagon.fill"
        }
    }

    var color: Color {
        switch kind {
        case .info: Tone.accent
        case .success: Tone.good
        case .warning: Tone.warnText
        case .error: Tone.danger
        }
    }
}

private struct NoticeOverlay: ViewModifier {
    @Binding var notice: ImpNotice?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .bottom) {
                if let notice {
                    HStack(alignment: .firstTextBaseline, spacing: Spacing.snug) {
                        Image(systemName: notice.symbol).foregroundStyle(notice.color).font(.icon(.small))
                        Text(verbatim: notice.text).font(Typeface.label).foregroundStyle(Tone.text)
                            .lineLimit(3).multilineTextAlignment(.leading)
                    }
                    .padding(.horizontal, Spacing.large).padding(.vertical, Spacing.cozy)
                    .background(Capsule().fill(Tone.raised))
                    .shadow(color: Elevation.cardColor, radius: Elevation.cardBlur / 2, y: Elevation.cardY / 2)
                    .padding(Spacing.large)
                    .onTapGesture { self.notice = nil }
                    .accessibilityElement(children: .combine)
                    .accessibilityAddTraits(.isButton)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .id(notice.id)
                    .task(id: notice.id) {
                        AccessibilityNotification.Announcement(notice.text).post()
                        try? await Task.sleep(for: .seconds(Behavior.noticeSeconds))
                        if !Task.isCancelled { self.notice = nil }
                    }
                }
            }
            .animation(Motion.spring.reducedAware(reduceMotion), value: notice)
    }
}

extension View {
    /// Floats `notice` over the bottom of this view. It is an overlay, so nothing moves. It goes away by
    /// itself after `Behavior.noticeSeconds`, on a tap, and is announced to VoiceOver.
    public func impNotice(_ notice: Binding<ImpNotice?>) -> some View {
        modifier(NoticeOverlay(notice: notice))
    }
}

/// A line of fixed height that is always there and swaps its words in place, with a crossfade.
public struct StatusSlot: View {
    let text: String?
    let symbol: String?
    let color: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(_ text: String?, symbol: String? = nil, color: Color = Tone.muted) {
        self.text = text; self.symbol = symbol; self.color = color
    }

    public var body: some View {
        ZStack {
            StatusText(verbatim: " ").hidden()
            if let text {
                StatusText(verbatim: text, symbol: symbol, color: color).id(text).transition(.opacity)
            }
        }
        .animation(Motion.fade.reducedAware(reduceMotion), value: text)
        .accessibilityElement(children: .combine)
    }
}

/// The notices a host shows. A reference, so the poster handed down is the same value for as long as
/// the host lives and nothing below it is redrawn when a notice comes or goes.
@MainActor @Observable
final class NoticeCenter {
    var notice: ImpNotice?
}

/// Posts a floating notice on the nearest window, page or sheet that has `.impNoticeHost()`. Called like a
/// function: `postNotice(.error(text))`. Equal while it posts to the same host.
public struct NoticePost: Equatable {
    private weak var center: NoticeCenter?

    init(_ center: NoticeCenter?) { self.center = center }

    @MainActor public func callAsFunction(_ notice: ImpNotice) { center?.notice = notice }

    public static func == (a: Self, b: Self) -> Bool { a.center === b.center }
}

extension EnvironmentValues {
    /// Posts a floating notice on the nearest notice host (nowhere without one).
    @Entry public var postNotice = NoticePost(nil)
}

private struct NoticeHost: ViewModifier {
    @State private var center = NoticeCenter()

    func body(content: Content) -> some View {
        @Bindable var center = center
        return content
            .environment(\.postNotice, NoticePost(center))
            .impNotice($center.notice)
    }
}

extension View {
    /// Makes this view the place where `@Environment(\.postNotice)` shows its notices: a window, a page or
    /// a sheet. Screens inside it post to it instead of inserting a line.
    public func impNoticeHost() -> some View { modifier(NoticeHost()) }
}

/// Hands its content the poster of the notice host it sits in. A sheet's own body is built outside its
/// host, so it reads the poster here, from inside, instead of with `@Environment`.
public struct NoticePoster<Content: View>: View {
    @Environment(\.postNotice) private var post
    let content: (@escaping @MainActor (ImpNotice) -> Void) -> Content

    public init(@ViewBuilder content: @escaping (@escaping @MainActor (ImpNotice) -> Void) -> Content) {
        self.content = content
    }

    public var body: some View { content { post($0) } }
}
