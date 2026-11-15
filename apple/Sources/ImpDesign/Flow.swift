import SwiftUI

// The two pieces every modal flow shares, on the Mac and on the iPhone: the bar at the top of a sheet
// and the dots that show where you are in a short flow.

/// The top bar of a modal or a sheet: a Back icon button on the leading edge, an optional centred
/// title or progress (a `StepIndicator`, say), and a Close icon button on the trailing edge. A button
/// that is not wanted is left out and the centre stays centred. Where there is no Back, the leading
/// corner may hold one action of the whole sheet. The icon buttons have no background
/// until they are pointed at or pressed. Esc closes (the Close button carries the cancel shortcut).
public struct SheetBar<Center: View, Leading: View>: View {
    let back: (() -> Void)?
    let close: (() -> Void)?
    let center: Center
    let leading: Leading

    /// `leading`: an action of the whole sheet (an icon button) in the corner Back leaves free. It
    /// gives way to Back, so the leading corner always holds one thing and mirrors Close.
    public init(back: (() -> Void)? = nil, close: (() -> Void)? = nil, @ViewBuilder center: () -> Center,
                @ViewBuilder leading: () -> Leading) {
        self.back = back
        self.close = close
        self.center = center()
        self.leading = leading()
    }

    public var body: some View {
        HStack(spacing: Spacing.small) {
            HStack(spacing: 0) {
                if let back { HoverIconButton(systemName: "chevron.left", help: "common.back", tint: Tone.text, action: back).accessibilityIdentifier("sheet.back") }
                else { leading }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity)
            center.layoutPriority(1)
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                if let close {
                    HoverIconButton(systemName: "xmark", help: "common.close", tint: Tone.text, action: close)
                        .keyboardShortcut(.cancelAction)
                        .accessibilityIdentifier("sheet.close")
                }
            }
            .frame(maxWidth: .infinity)
        }
        .frame(minHeight: Sizing.hit)
    }
}

extension View {
    /// Where the bar of every sheet sits (Back, title, Close), on every platform: the same distance from
    /// the sheet's top and sides, so a corner button's circle is as far from the side as from the top
    /// and Close is always in the same place.
    public func sheetBarInsets() -> some View {
        padding(.horizontal, Spacing.medium).padding(.top, Spacing.medium)
    }
}

extension SheetBar where Leading == EmptyView {
    public init(back: (() -> Void)? = nil, close: (() -> Void)? = nil, @ViewBuilder center: () -> Center) {
        self.init(back: back, close: close, center: center) { EmptyView() }
    }
}

extension SheetBar where Center == EmptyView, Leading == EmptyView {
    public init(back: (() -> Void)? = nil, close: (() -> Void)? = nil) {
        self.init(back: back, close: close) { EmptyView() }
    }
}

/// The steps of a short flow as a row of round marks: the current one lit in the Imp's colour, done
/// ones ticked, the rest numbered. Each is spoken as "Step 2 of 3, <name>" (`common.step`). Give
/// `select` to make the steps tappable (each a full hit target), leave it out for a plain indicator.
public struct StepIndicator: View {
    let names: [String]
    let current: Int
    let select: ((Int) -> Void)?
    let reachable: (Int) -> Bool
    @Environment(\.impTint) private var tint

    /// `steps` are the localized step names, in order. `current` is the zero-based index.
    /// `reachable` says which steps can be jumped to now: the others are dimmed and do nothing.
    public init(steps names: [String], current: Int, reachable: @escaping (Int) -> Bool = { _ in true },
                select: ((Int) -> Void)? = nil) {
        self.names = names
        self.current = current
        self.reachable = reachable
        self.select = select
    }

    public var body: some View {
        HStack(spacing: select == nil ? Spacing.small : 0) {
            ForEach(names.indices, id: \.self) { index in
                if let select {
                    Button { select(index) } label: { mark(index).frame(minWidth: Sizing.hit, minHeight: Sizing.hit).contentShape(Rectangle()) }
                        .buttonStyle(.plain)
                        .disabled(!reachable(index))
                        .opacity(reachable(index) || index == current ? 1 : Opacity.disabled)
                        .accessibilityLabel(label(index))
                        .accessibilityAddTraits(index == current ? .isSelected : [])
                } else {
                    mark(index)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(label(index))
                        .accessibilityAddTraits(index == current ? .isSelected : [])
                }
            }
        }
    }

    private func label(_ index: Int) -> String {
        words("common.step", index + 1, names.count, names[index])
    }

    @ViewBuilder private func mark(_ index: Int) -> some View {
        let lit = index == current
        let done = index < current
        ZStack {
            Circle().fill(lit ? AnyShapeStyle(TintFill(tint)) : AnyShapeStyle(Tone.card))
            if done {
                Image(systemName: "checkmark").font(.icon(.tiny, weight: .heavy)).foregroundStyle(Tone.text)
            } else {
                Text(verbatim: "\(index + 1)").font(Typeface.small.weight(.semibold).monospacedDigit())
                    .foregroundStyle(lit ? AnyShapeStyle(OnTint(tint)) : AnyShapeStyle(Tone.muted))
            }
        }
        .frame(width: Sizing.mark, height: Sizing.mark)
    }
}
