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
                Text("No keys").font(.caption).foregroundStyle(.tertiary)
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
    let title: LocalizedStringKey
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


/// Click, then press the keys. ⎋ cancels, ⌫ clears.
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
                .frame(minHeight: Sizing.control)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.black.opacity(0.24)))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(recording ? tint : Dungeon.cardEdge, lineWidth: recording ? 1.5 : 1))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .modifier(Shake(amount: invalid ? 1 : 0))
            if hotkey != nil && !recording {
                HoverIconButton(systemName: "xmark", help: "Clear keys") { hotkey = nil }
            }
        }
        .onDisappear { stop() }
        .help("Click, then press the keys. Use ⌃, ⌥ or ⌘ with a key, or a function key. ⎋ cancels and ⌫ clears.")
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
