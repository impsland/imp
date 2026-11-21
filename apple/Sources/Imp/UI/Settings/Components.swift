import AppKit
import Carbon.HIToolbox
import ImpDesign
import ImpKit
import SwiftUI

extension ImpProfile {
    /// What settings call this Imp in a sentence.
    static var stranger: String { String(localized: "this Imp") }
    var callName: String { name.isEmpty ? Self.stranger : name }
}

// `impTint` (from ImpDesign) colours buttons, icons and highlights after the Imp being set up.

/// Keys rendered as physical-looking keycaps.
struct Keycaps: View {
    let hotkey: Hotkey?
    var small = false

    var body: some View {
        HStack(spacing: Spacing.hairline) {
            if let hotkey {
                ForEach(Array(Self.parts(hotkey).enumerated()), id: \.offset) { _, part in
                    Text(part)
                        .font(small ? Typeface.small : Typeface.label)
                        .padding(.horizontal, small ? Spacing.tight : Spacing.snug)
                        .frame(minWidth: small ? Sizing.iconTile - Spacing.tight : Sizing.iconTile,
                               minHeight: small ? Sizing.iconTile - Spacing.tight : Sizing.iconTile)
                        .background(RoundedRectangle(cornerRadius: Radius.tiny, style: .continuous).fill(Tone.cardHover))
                }
            } else {
                Text("No keys").font(Typeface.caption).foregroundStyle(Tone.faint)
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

/// An async check with its result beside it: a spinner, then a tick or a cross (the text is its
/// tooltip). It is as wide as its words, so a row can put it on its trailing edge.
struct TestButton: View {
    let title: LocalizedStringKey
    let action: () async throws -> String
    /// What a failure says to the user, with what to do about it.
    var explain: (Error) -> String = { $0.localizedDescription }
    @State private var state: ActionState = .idle
    @State private var running: Task<Void, Never>?
    @Environment(\.postNotice) private var postNotice

    var body: some View {
        Button {
            state = .working
            running = Task {
                do {
                    let text = try await action()
                    state = .done
                    postNotice(.success(text))
                } catch is CancellationError {
                    return
                } catch {
                    state = .failed
                    postNotice(.error(explain(error)))
                }
            }
        } label: { StatefulLabel(title, symbol: "checkmark.circle", state: state) }
            .buttonStyle(.imp(.secondary, small: true))
            .disabled(state == .working)
            .impActionState($state)
            // A sheet closed mid-request must not answer into nothing.
            .onDisappear { running?.cancel() }
            .fixedSize()
    }
}


/// Click, then press the keys. ⎋ cancels, ⌫ clears.
struct HotkeyField: View {
    @Environment(\.impTint) private var tint
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Binding var hotkey: Hotkey?
    @State private var recording = false
    @State private var monitor: Any?
    @State private var invalid = false

    var body: some View {
        HStack(spacing: Spacing.cozy) {
            Button {
                recording ? stop() : start()
            } label: {
                HStack(spacing: Spacing.small) {
                    if recording {
                        Image(systemName: "record.circle").foregroundStyle(LegibleTint(on: .raised))
                            .symbolEffect(.pulse, isActive: true)
                        Text("Press keys…").font(Typeface.label).foregroundStyle(Tone.muted)
                    } else {
                        if hotkey != nil {
                            Keycaps(hotkey: hotkey)
                        } else {
                            Image(systemName: "record.circle").foregroundStyle(LegibleTint(on: .raised))
                            Text("Record keys").font(Typeface.label).foregroundStyle(Tone.muted)
                        }
                    }
                }
                .padding(.horizontal, Spacing.cozy)
                .frame(minHeight: Sizing.control)
                .background(RoundedRectangle(cornerRadius: Radius.small, style: .continuous)
                    .fill(recording ? AnyShapeStyle(tint.opacity(Opacity.tintFillStrong)) : AnyShapeStyle(Tone.well)))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .modifier(Shake(amount: invalid ? 1 : 0))
            if hotkey != nil && !recording {
                HoverIconButton(systemName: "xmark", help: "Clear keys") { hotkey = nil }
            }
        }
        .onDisappear { stop() }
        .help("Click, then press keys. ⎋ cancels, ⌫ clears.")
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
                withImpAnimation(ImpDesign.Motion.quick, reduceMotion: reduceMotion) { invalid.toggle() }
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
