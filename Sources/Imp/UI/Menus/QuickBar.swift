import ImpKit
import SwiftUI

/// An Imp's right-click menu header: a little Imp, its status, and the three things you do most.
struct MenuHeader: View {
    /// A bigger Imp than before, horns kept at their old on-screen size.
    static func portrait(ready: Bool, hue: Double) -> Face {
        var f = Face.settled(ready ? .idle : .sad, lookX: 0.35, lookY: 0.25)
        f.hornSize *= 46.0 / 54.0
        f.hue = hue
        return f
    }

    let ready: Bool
    let name: String
    let hue: Double
    let status: String
    let talk: () -> Void
    let type: () -> Void
    let settings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                ImpPortrait(face: Self.portrait(ready: ready, hue: hue), shadow: false)
                    .frame(width: 54, height: 54)
                    .background(Circle().fill(Color.imp(hue).opacity(0.10)).padding(2))
                VStack(alignment: .leading, spacing: 2) {
                    Text(name).font(.system(size: 15, weight: .bold, design: .rounded))
                    HStack(spacing: 5) {
                        Circle().fill(ready ? Color.green : Color.orange).frame(width: 6, height: 6)
                        Text(status).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            QuickBar(buttons: [
                QuickBar.Item(icon: "mic.fill", title: "Talk", help: "Talk to \(name)", action: talk),
                QuickBar.Item(icon: "keyboard.fill", title: "Type", help: "Type to \(name)", action: type),
                QuickBar.Item(icon: "slider.horizontal.3", title: "Settings", help: "\(name)'s settings", action: settings),
            ], padded: false)
        }
        .padding(.horizontal, 14)
        .padding(.top, 6)
        .padding(.bottom, 8)
        .frame(minWidth: 260, maxWidth: .infinity, alignment: .leading)
    }
}

/// A row of big, equal, monochrome buttons for the top of a menu.
struct QuickBar: View {
    struct Item {
        var icon: String
        var title: String
        var help: String
        var enabled = true
        var action: () -> Void
    }

    let buttons: [Item]
    /// Each button's width in a menu of just this row: room for its title, however many there are.
    static let buttonWidth: CGFloat = 64
    /// Its own margins (a menu of just this row) or none (inside a header that has them).
    var padded = true

    var body: some View {
        HStack(spacing: 6) {
            ForEach(Array(buttons.enumerated()), id: \.offset) { _, b in
                QuickButton(icon: b.icon, title: b.title, action: b.action)
                    .frame(minWidth: padded ? Self.buttonWidth : nil)
                    .disabled(!b.enabled)
                    .help(b.help)
            }
        }
        .padding(.horizontal, padded ? 8 : 0)
        .padding(.vertical, padded ? 3 : 0)
    }
}

/// Black and white, like the menu around it: a soft grey tile that turns solid on hover.
struct QuickButton: View {
    let icon: String
    let title: String
    let action: () -> Void
    @State private var hover = false
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        let on = hover && enabled
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: icon).font(.system(size: 13, weight: .semibold))
                Text(title).font(.system(size: 10, weight: .medium))
            }
            .frame(maxWidth: .infinity, minHeight: 40)
            .foregroundStyle(on ? Color(nsColor: .textBackgroundColor) : Color.primary)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(on ? Color.primary.opacity(0.85) : Color.primary.opacity(0.07)))
            .opacity(enabled ? 1 : 0.4)
            .contentShape(Rectangle())
            .animation(.easeOut(duration: 0.12), value: on)
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .accessibilityLabel(title)
    }
}
