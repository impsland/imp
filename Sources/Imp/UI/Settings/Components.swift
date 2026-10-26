import AppKit
import Carbon.HIToolbox
import ImpKit
import SwiftUI

// `impTint` (declared with the bubble) colours buttons, icons and highlights after the Imp being set up.

/// Shortcut rendered as physical-looking keycaps.
struct Keycaps: View {
    let hotkey: Hotkey?
    var small = false

    var body: some View {
        HStack(spacing: 3) {
            if let hotkey {
                ForEach(Array(Self.parts(hotkey).enumerated()), id: \.offset) { _, part in
                    Text(part)
                        .font(.system(size: small ? 10 : 12, weight: .semibold, design: .rounded))
                        .padding(.horizontal, small ? 4 : 6)
                        .frame(minWidth: small ? 16 : 22, minHeight: small ? 16 : 22)
                        .background(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(Color.white.opacity(0.1))
                                .shadow(color: .black.opacity(0.35), radius: 0, y: 1)
                        )
                        .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(Color.primary.opacity(0.15)))
                }
            } else {
                Text("no shortcut").font(.caption).foregroundStyle(.tertiary)
            }
        }
    }

    static func parts(_ h: Hotkey) -> [String] {
        var p: [String] = []
        if h.modifiers & Hotkey.control != 0 { p.append("⌃") }
        if h.modifiers & Hotkey.option != 0 { p.append("⌥") }
        if h.modifiers & Hotkey.shift != 0 { p.append("⇧") }
        if h.modifiers & Hotkey.command != 0 { p.append("⌘") }
        p.append(KeyNames.name(for: h.keyCode))
        return p
    }
}

/// Inline async check with a tiny status readout.
struct TestButton: View {
    let title: String
    let action: () async throws -> String
    var onResult: ((Bool, String) -> Void)?
    @State private var state: (ok: Bool, text: String)?
    @State private var busy = false

    var body: some View {
        HStack(spacing: 8) {
            if busy {
                ProgressView().controlSize(.small)
            } else if let state {
                Image(systemName: state.ok ? "checkmark.circle.fill" : "xmark.octagon.fill")
                    .foregroundStyle(state.ok ? .green : .red)
                    .help(state.text)
            }
            Button(title) {
                busy = true; state = nil
                Task {
                    do { state = (true, try await action()) } catch { state = (false, error.localizedDescription) }
                    busy = false
                    if let state { onResult?(state.ok, state.text) }
                }
            }
            .buttonStyle(.imp(.secondary, small: true))
            .disabled(busy)
        }
    }
}


/// Click, then press a shortcut. ⎋ cancels, ⌫ clears.
struct HotkeyField: View {
    @Environment(\.impTint) private var tint
    @Binding var hotkey: Hotkey?
    @State private var recording = false
    @State private var monitor: Any?
    @State private var invalid = false

    var body: some View {
        HStack(spacing: 10) {
            Button {
                recording ? stop() : start()
            } label: {
                HStack(spacing: 8) {
                    if recording {
                        Image(systemName: "record.circle").foregroundStyle(tint)
                            .symbolEffect(.pulse, isActive: true)
                        Text("Press keys…").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                    } else {
                        if hotkey != nil {
                            Keycaps(hotkey: hotkey)
                        } else {
                            Image(systemName: "record.circle").foregroundStyle(tint)
                            Text("Record keys").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.horizontal, 10)
                .frame(minHeight: Metrics.control)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.black.opacity(0.24)))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(recording ? tint : Dungeon.cardEdge, lineWidth: recording ? 1.5 : 1))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .modifier(Shake(amount: invalid ? 1 : 0))
            if hotkey != nil && !recording {
                HoverIconButton(systemName: "xmark", help: "Remove shortcut") { hotkey = nil }
            }
        }
        .onDisappear { stop() }
        .help("Click, then press a function key or a combination with ⌃, ⌥ or ⌘. ⎋ cancels, ⌫ clears.")
    }

    private func start() {
        recording = true
        HotkeyCenter.shared.suspend()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let mods = Self.carbonModifiers(event.modifierFlags)
            if event.keyCode == UInt16(kVK_Escape) && mods == 0 { stop(); return nil }
            if (event.keyCode == UInt16(kVK_Delete) || event.keyCode == UInt16(kVK_ForwardDelete)) && mods == 0 {
                hotkey = nil; stop(); return nil
            }
            let hk = Hotkey(keyCode: UInt32(event.keyCode), modifiers: mods)
            if hk.isValidGlobalShortcut {
                hotkey = hk
                stop()
            } else {
                withAnimation(.default) { invalid.toggle() }
                NSSound.beep()
            }
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if recording { HotkeyCenter.shared.resume() }
        recording = false
    }

    static func carbonModifiers(_ f: NSEvent.ModifierFlags) -> UInt32 {
        var m: UInt32 = 0
        if f.contains(.command) { m |= Hotkey.command }
        if f.contains(.option) { m |= Hotkey.option }
        if f.contains(.control) { m |= Hotkey.control }
        if f.contains(.shift) { m |= Hotkey.shift }
        return m
    }
}

struct Shake: GeometryEffect {
    var amount: CGFloat
    var animatableData: CGFloat {
        get { amount }
        set { amount = newValue }
    }
    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(translationX: 5 * sin(amount * .pi * 4), y: 0))
    }
}

// MARK: - Buttons

/// Imp's buttons: one family, a few weights. Pills with soft fills instead of system bezels,
/// so Settings feels like the rest of Imp.
///  - `.primary`: the one main thing on a card (Run now, Grant, Save).
///  - `.secondary`: helpful extras (Test, Add, Import…).
///  - `.quiet`: low-key options (Duplicate, Cancel, Edit…).
///  - `.destructive`: Remove, Delete.
struct ImpButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary, quiet, destructive }
    var kind: Kind
    var small = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .labelStyle(PillLabelStyle())
            .impPill(kind, small: small, pressed: configuration.isPressed)
    }
}

/// The pill look, usable on any label (buttons, menus) so menus match buttons exactly.
private struct ImpPill: ViewModifier {
    let kind: ImpButtonStyle.Kind
    let small: Bool
    var pressed = false
    @Environment(\.isEnabled) private var enabled
    @Environment(\.colorScheme) private var scheme
    @Environment(\.impTint) private var tint
    @State private var hover = false

    func body(content: Content) -> some View {
        content
            .font(.system(size: small ? 11.5 : 13, weight: .semibold))
            .lineLimit(1)
            .foregroundStyle(foreground)
            .padding(.horizontal, small ? 10 : 14)
            .padding(.vertical, small ? 4 : 6)
            .background(Capsule().fill(fill))
            .overlay(Capsule().strokeBorder(kind == .primary ? Color.white.opacity(0.25) : Color.clear, lineWidth: 0.5))
            .shadow(color: kind == .primary ? tint.opacity(hover ? 0.35 : 0.2) : .clear, radius: hover ? 6 : 3, y: 2)
            .contentShape(Capsule())
            .scaleEffect(pressed ? 0.96 : 1)
            .opacity(enabled ? 1 : 0.45)
            .animation(.snappy(duration: 0.15), value: pressed)
            .animation(.easeOut(duration: 0.15), value: hover)
            .onHover { hover = $0 && enabled }
    }

    private var foreground: Color {
        switch kind {
        case .primary: .white
        case .secondary: scheme == .dark ? Color.white.opacity(0.94) : tint
        case .quiet: .primary
        case .destructive: scheme == .dark ? Color(red: 1, green: 0.5, blue: 0.48) : .red
        }
    }

    private var fill: AnyShapeStyle {
        let boost = hover ? 1.6 : 1
        switch kind {
        case .primary: return AnyShapeStyle(tint.gradient.opacity(hover ? 1 : 0.92))
        case .secondary: return AnyShapeStyle(tint.opacity((scheme == .dark ? 0.34 : 0.16) * boost))
        case .quiet: return AnyShapeStyle(Color.primary.opacity(0.07 * boost))
        case .destructive: return AnyShapeStyle(Color.red.opacity(0.1 * boost))
        }
    }
}

extension View {
    /// Dresses a label (e.g. a `Menu` label) as an Imp pill button.
    func impPill(_ kind: ImpButtonStyle.Kind, small: Bool = false, pressed: Bool = false) -> some View {
        modifier(ImpPill(kind: kind, small: small, pressed: pressed))
    }
}

/// Icon and title close together, icon a touch smaller.
private struct PillLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 5) {
            configuration.icon.imageScale(.small)
            configuration.title
        }
    }
}

extension ButtonStyle where Self == ImpButtonStyle {
    static var primary: ImpButtonStyle { ImpButtonStyle(kind: .primary) }
    static var secondary: ImpButtonStyle { ImpButtonStyle(kind: .secondary) }
    static var quiet: ImpButtonStyle { ImpButtonStyle(kind: .quiet) }
    static var destructive: ImpButtonStyle { ImpButtonStyle(kind: .destructive) }
    static func imp(_ kind: ImpButtonStyle.Kind, small: Bool = false) -> ImpButtonStyle { ImpButtonStyle(kind: kind, small: small) }
}

/// A bare glyph that grows a soft circle on hover. Shared by icon buttons and icon menus.
struct HoverGlyph: View {
    let systemName: String
    var tint: Color = .secondary
    @State private var hover = false
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(hover ? tint : tint.opacity(0.85))
            .frame(width: 26, height: 26)
            .background(Circle().fill(tint.opacity(hover ? 0.14 : 0)))
            .contentShape(Circle())
            .opacity(enabled ? 1 : 0.4)
            .animation(.easeOut(duration: 0.12), value: hover)
            .onHover { hover = $0 && enabled }
    }
}

/// Icon-only button with a hover circle. Always give it a `help`.
struct HoverIconButton: View {
    let systemName: String
    let help: String
    var tint: Color = .secondary
    let action: () -> Void

    var body: some View {
        Button(action: action) { HoverGlyph(systemName: systemName, tint: tint) }
            .buttonStyle(.plain)
            .help(help)
            .accessibilityLabel(help)
    }
}

/// Icon-only menu with the same hover circle.
struct HoverIconMenu<Content: View>: View {
    let systemName: String
    let help: String
    @ViewBuilder var content: Content

    var body: some View {
        Menu { content } label: { HoverGlyph(systemName: systemName) }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .help(help)
            .accessibilityLabel(help)
    }
}
