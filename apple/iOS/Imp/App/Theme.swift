import ImpDesign
import ImpKit
import SwiftUI
import UIKit

// The phone's look is ImpDesign's, the same as the Mac's. What stays here needs the phone's own
// services (the keyboard).

extension View {
    /// On a scrolling screen with a text field: dragging the content puts the keyboard away with the finger.
    /// For taps, put `tapAwayClosesKeyboard()` on the content inside the scroll view.
    func dismissesKeyboard() -> some View {
        scrollDismissesKeyboard(.interactively)
    }

    /// On the content of a scroll view: a tap on an empty part of it puts the keyboard away. The tap is
    /// caught behind the content, so a tap on a field, a button or a menu never reaches it. (Caught over the
    /// whole scroll view, it also fired for a tap on another field: the keyboard went away and came back,
    /// which looked like a stutter when moving from one field to the next.)
    func tapAwayClosesKeyboard() -> some View {
        background { Color.clear.contentShape(Rectangle()).tapClosesKeyboard().accessibilityHidden(true) }
    }

    /// Any tap on this puts the keyboard away. Only for what holds no field (a chat's transcript, whose
    /// field is under it): see `tapAwayClosesKeyboard` for a form.
    func tapClosesKeyboard() -> some View {
        onTapGesture {
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        }
    }

    /// On a form: the field being typed in rests `gap` above the keyboard, not right on it. The gap is a
    /// fixed margin below the scrolling content, not something that appears when the keyboard does: nothing
    /// is re-laid out as the keyboard comes, goes or changes (from one field to another), so the keyboard
    /// and the screen move as one. A screen that fills the scroll view subtracts `gap` from its height.
    func keyboardGap(_ gap: CGFloat = Spacing.huge) -> some View {
        contentMargins(.bottom, gap, for: .scrollContent)
    }

    /// For what lies under the sheets (the room, its pill): the keyboard is not its business. Without
    /// this, every keyboard that comes up in a sheet lays the room out again, right as the keyboard starts.
    func keyboardIgnored() -> some View {
        ignoresSafeArea(.keyboard, edges: .bottom)
    }

    /// A field for something technical (an address, a key, a model's name, a header): typed exactly as it
    /// is, on a keyboard of Latin letters, with no capitals, corrections, suggestions or AutoFill bar. Every
    /// such field takes the same keyboard (only a web address gets the `/` and `.com` keys, the same height),
    /// so going from one to the next does not swap the keyboard, change its language or move what is above it.
    func codeEntry(_ kind: CodeEntry = .code) -> some View {
        textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .keyboardType(kind == .address ? .URL : .asciiCapable)
            .textContentType(nil)
    }

    /// Tells `up` whether the keyboard is on screen, as it starts to come up or go away (so a change
    /// made here moves with it). The one way the app follows the keyboard, and only for what must change
    /// with it: each call is a pass over whatever it changes, so keep that small. Called only when the
    /// answer changes: moving between fields (the keyboard changes shape, or leaves and returns) says
    /// nothing new.
    func onKeyboard(_ up: @escaping (Bool) -> Void) -> some View {
        modifier(KeyboardWatch(up: up))
    }
}

private struct KeyboardWatch: ViewModifier {
    let up: (Bool) -> Void
    @State private var shown = false

    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in set(true) }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in set(false) }
    }

    private func set(_ now: Bool) {
        guard now != shown else { return }
        shown = now
        up(now)
    }
}

/// A form screen under its bar: the content scrolls, and the screen's one button (Save, Continue) stands
/// under it, just above the keyboard while one is up, so it is always in sight. Made for the keyboard:
/// - The content is laid out by the height the page has without the keyboard (`content` gets that size),
///   so nothing in it grows or shrinks as the keyboard comes and goes. Only the visible part of the scroll
///   view changes, and SwiftUI keeps the focused field in it.
/// - The button moves with the keyboard in the keyboard's own animation. It moves only when the keyboard
///   does: the fields of a form share one keyboard (`codeEntry`, `SecretField`), so going from one field
///   to the next changes nothing.
/// The page must reach the bottom of the sheet.
struct FormPage<Content: View, Footer: View>: View {
    private let content: (CGSize) -> Content
    private let footer: Footer
    /// The page's size with the keyboard left out.
    @State private var page = CGSize.zero
    @State private var foot: CGFloat = 0

    init(@ViewBuilder content: @escaping (CGSize) -> Content, @ViewBuilder footer: () -> Footer) {
        self.content = content
        self.footer = footer()
    }

    var body: some View {
        ScrollView {
            content(CGSize(width: page.width, height: max(page.height - foot - Spacing.huge, 0)))
                .frame(maxWidth: .infinity)
                .tapAwayClosesKeyboard()
        }
        .scrollBounceBehavior(.basedOnSize)
        .dismissesKeyboard()
        // The field being typed in rests a little above the button (or the keyboard), not right on it.
        .contentMargins(.bottom, Spacing.huge, for: .scrollContent)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            // Wrapped, so a footer that goes away (an `if` that turns false) measures nothing.
            VStack(spacing: 0) { footer }
                .frame(maxWidth: .infinity)
                .background(Tone.surface)
                .onGeometryChange(for: CGFloat.self, of: \.size.height) { foot = $0 }
        }
        .background {
            Color.clear
                .keyboardIgnored()
                .onGeometryChange(for: CGSize.self, of: \.size) { page = $0 }
        }
    }
}

extension FormPage where Footer == EmptyView {
    init(@ViewBuilder content: @escaping (CGSize) -> Content) {
        self.init(content: content) { EmptyView() }
    }
}

/// A control under its small title, with the help icon after the title when there is one.
struct Titled<Content: View>: View {
    let title: LocalizedStringKey
    var tip: InfoTip?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.tight) {
            HStack(spacing: 0) {
                Text(title).font(Typeface.caption).foregroundStyle(Tone.muted)
                    .accessibilityAddTraits(.isHeader)
                // The help icon keeps its finger-sized target but not its height in the form.
                if let tip { tip.padding(.vertical, -Spacing.cozy) }
            }
            content
        }
    }
}

extension AttentionNotice.Line {
    /// A problem from the settings map, with the button that fixes it when the fix is somewhere else.
    init(_ item: AttentionItem, fix: AttentionNotice.Fix? = nil) {
        self.init(id: item.id, symbol: item.symbol, text: item.text, fix: fix)
    }
}

/// An Imp's colour as a small dot, for places that only take an image: a menu draws its items' symbols in
/// one tint, so a dot there must be a picture in its own colours.
enum ImpSwatch {
    static func image(hue: Double) -> Image {
        let side = Spacing.large
        let color = UIColor(Color.imp(hue))
        let picture = UIGraphicsImageRenderer(size: CGSize(width: side, height: side)).image { context in
            color.setFill()
            context.cgContext.fillEllipse(in: CGRect(x: 0, y: 0, width: side, height: side).insetBy(dx: Spacing.hairline, dy: Spacing.hairline))
        }
        return Image(uiImage: picture.withRenderingMode(.alwaysOriginal)).renderingMode(.original)
    }
}

/// What a `codeEntry` field holds.
enum CodeEntry {
    /// A web address.
    case address
    /// Anything else typed exactly: a key, a model's name, a header.
    case code
}

/// A key or another secret, typed on the same keyboard as the fields around it (`codeEntry`). It shows what
/// was typed only while it is being edited, and dots otherwise.
///
/// Not a `SecureField`: that brings a keyboard of its own, which iOS builds again each time the field is
/// entered or left. It is always in English and has no suggestions row, so moving between an address and a
/// key made the keyboard stutter, change its language and change its height (moving the button above it).
/// What is typed here is a key you pasted or copied from a service's page, not a password you remember.
struct SecretField: View {
    let title: LocalizedStringKey
    @Binding var text: String
    var prompt: Text?
    @FocusState private var focused: Bool

    private var hidden: Bool { !focused && !text.isEmpty }

    var body: some View {
        TextField(title, text: $text, prompt: prompt)
            .focused($focused)
            .codeEntry()
            // While it is not being edited the text is drawn in no colour, and dots stand over it.
            .foregroundStyle(hidden ? AnyShapeStyle(Color.clear) : AnyShapeStyle(Tone.text))
            .overlay(alignment: .leading) {
                if hidden {
                    Text(verbatim: String(repeating: "•", count: min(text.count, Self.dots)))
                        .foregroundStyle(Tone.text)
                        .lineLimit(1)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .privacySensitive()
            .accessibilityValue(hidden ? Text("phone.secret.hidden") : Text(verbatim: text))
    }

    /// Enough dots to say something is there, never so many that they run out of the field.
    private static let dots = 24
}
