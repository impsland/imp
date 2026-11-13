# Design

Imp has one look, called **Pebble**, on every platform. On the Mac and the iPhone it lives in the `ImpDesign` library (`apple/Sources/ImpDesign`, SwiftUI only). The browser extension, and later Android, Windows and Linux, read the same numbers from files generated out of `design/`. The Imp character is the only thing with a look of its own.

## The rule

Custom look, standard behavior. Every control is a real control of its platform (`Button`, `Toggle`, `TextField`, `Slider`, `Picker`, `Menu`) wearing the app's style. Do not rebuild a control from gestures. Keep what the system gives for free: the keyboard focus ring, screen readers, Dynamic Type on the iPhone, Return and Esc, pressed, hover and disabled states. A control's hit area is at least 44 pt on the iPhone and 28 pt on the Mac (see `Sizing` in `design/tokens.json`).

## The 12 principles

1. **One surface.** Every window, screen and sheet sits on `Tone.surface` (`Backdrop()`), flat. A sheet has the same background as the app. Only things that float for a moment (popovers, menus, the desktop bubble, the undo bar) use `Tone.raised`.
2. **Pebbles, not boxes.** A group is a soft fill (`Tone.card`, hover `Tone.cardHover`) with big continuous corners. No outlines on cards, rows, chips, buttons or fields. The only strokes are the keyboard focus ring, a focused field's ring and real drawings (timeline tracks, charts, the Imp).
3. **No dividers** between list items or rows. Separate with spacing, grouping, or by making each item its own pebble.
4. **Monochrome chrome, the colour belongs to the Imp.** `Tone.accent` is paper white in dark and ink in light. Inside an Imp's context the tint is the Imp's colour (`impTint`). Status colours stay: `good`, `danger`, `warnText` and `warnBackground`.
5. **Flat.** No gradients and no shadows or glows on chrome. A shadow is allowed only under something that floats over other content (`Elevation.cardColor`).
6. **Text on a fill** uses `OnTint(tint)` on a `TintFill(tint)`. On an Imp's colour it is white or black, as the person chose in Settings (white by default), and the fill is the colour itself or the nearest shade of it on which that choice has 4.5 to 1. The monochrome accent keeps ink or paper. Never `.white` on a raw tint. An Imp's colour used as a foreground (text, an icon, a link) goes through `LegibleTint`: it is adjusted to at least 4.5 to 1 on its ground, lighter in dark and darker in light. The raw colour is never drawn as it is.
7. **Icons never touch the edge** of their background, and a filled button always pads its content. Use `IconTile`, `HoverIconButton` and the button styles.
8. **Icon first, few words.** Every setting row has a picture and a title of one to three plain words, understandable by a child. No explanatory paragraphs on screen.
9. **Help once per card.** A card or a section has at most one `InfoTip`, at the trailing end of its header (after any control, never beside the title with empty space on the right): one or two short sentences. A row has its own only when its one-to-three-word title cannot be understood without it, and never two tips for the same thing. The tip is a compact popover exactly as wide as its words (at most `Sizing.tipWidth`), one surface including its arrow, opened by a click or a tap only (no hover tooltip).
10. **Nothing overlaps or clips on a narrow width.** A `Row` moves its control under the title when they do not fit. `ImpSegmented` falls back from words to icons to a menu. A button never shrinks or cuts its label.
11. **Feedback and motion.** Controls have hover, press and focus states. Animate only through the `Motion` presets, which honour Reduce Motion. Nothing repeats forever for decoration, and anything that animates continuously pauses when hidden, idle or under Reduce Motion.
12. **The room never leaves.** On a phone the app is one room where the Imps fly freely over the whole screen. Everything else is one sheet over it. A sheet about an Imp brings that Imp up into the room left above it and wears its colour. Every sheet has the same bar and the same way back. See [The room never leaves](/design/room).

### What changed, and why

- **Principle 12 is new** (the iPhone redesign). The room was already open and people like it, so it stays as it is. What changed is everything that covered it: a chat with a small portrait of the Imp in its header, a second sheet for talks on top of the chat, settings that closed into a chat nobody asked for, sheets in the app's grey whatever Imp they were about, and a first screen with five ways to begin. Now the Imp itself is in view while you talk to it, one sheet holds everything about an Imp, Close has one rule, and the first screen has one main button.
- **Principle 4 is now kept on the phone.** "Inside an Imp's context the tint is the Imp's colour" was true on the Mac only. An Imp's sheets on the phone were monochrome.

## Tokens

Every colour, space, corner, type size, touch target, animation and shared behavior number is in `design/tokens.json`. Nobody copies them by hand. `node design/generate.mjs` (or `make tokens`) writes what each platform reads.

| Generated file | Read by |
| --- | --- |
| `apple/Sources/ImpDesign/Tokens.generated.swift` | The Mac and iPhone apps (`ImpDesign`). |
| `extension/tokens.css` and `extension/_locales/*/messages.json` | The browser extension (`popup.css`, `chrome.i18n`). |
| `design/generated/android/` (`ImpTheme.kt`, `ImpComponents.kt`, `values*/strings.xml`) | The Android app (Compose). |
| `design/generated/windows/` (`ImpTokens.xaml`, `ImpComponents.xaml`, `ImpTokens.cs`, `*/Resources.resw`) | The Windows app (WinUI 3). |
| `design/generated/gtk/` (`imp-colors-*.css`, `imp-tokens.css`, `imp-components.css`) and `design/generated/gettext/` | The Linux app (GTK 4 and libadwaita). |
| `cli/src/theme.generated.rs` and `cli/src/strings.generated.rs` | The terminal app (`imp`). The `cli.*` words go only here. |
| `docs/design/components.md` | The component specs, for people. |

`node design/generate.mjs --check` (or `make tokens-check`) fails when a generated file is out of date. CI runs it, and the `ImpDesignTests` suite runs it, so `make test` covers it.

In Swift the tokens are:

| Token | What it is |
| --- | --- |
| `Tone` | The adaptive palette, light and dark: `surface`, `raised`, `raisedHigh`, `deep`, `doorway`, `ink`, `paper` (fixed light, for text over pictures and scrims), `text`, `muted`, `faint`, `card`, `cardHover`, `line` (drawings only), `well`, `accent`, `accentBright`, `onAccent`, `heart`, `link`, `warnBackground`, `warnText`, `warnEdge`, `errorBackground`, `errorEdge`, `danger`, `okBackground`, `okEdge`, `focus`, `good`, `off`, `scrim`, `veil`, and the `spark` colours of the phone's game. Ordinary text is `Tone.text`. |
| `Radius` | `tiny` 6, `small` 10, `tile` 12, `medium` 16, `large` 20, `bubble` 24, `full`. |
| `Spacing` | `hairline` 2, `tight` 4, `snug` 6, `small` 8, `cozy` 10, `medium` 12, `roomy` 14, `large` 16, `page` 20, `wide` 24, `huge` 28, `vast` 40. |
| `Stroke` and `Opacity` | Line widths and opacities (`disabled`, `dimmed`, `tintFill`, `tintFillStrong`, `hoverFill`, `glow`). |
| `Sizing` | Per platform: `hit`, `control`, `iconTile`, `switchTrack`, `tipWidth`, `popoverWidth` and more. See [Accessibility](/ux/accessibility). |
| `Typeface` | `title`, `cardTitle`, `body`, `label`, `caption`, `small`, `mono`, all rounded, built from `TypeScale`. Dynamic Type on the iPhone. |
| `IconSize` | `tiny`, `small`, `medium`, `large`, `big`, `huge`, used as `.font(.icon(.medium))`. |
| `Timing`, `Motion`, `Elevation`, `Behavior` | Animation lengths and presets (each says what it does with Reduce Motion), the one shadow of floating things, and shared numbers such as the Undo bar time. |
| `impTint` | An environment value: the colour of the Imp being shown. Buttons, switches, fields and tabs follow it. |

Motion honours Reduce Motion. Use `.impAnimation(Motion.smooth, value:)` and `withImpAnimation(Motion.smooth, reduceMotion:)`. The presets are listed in [Motion](/ux/motion).

When you need a number, a colour or a corner, look in the tokens first. If it is missing, add it to `design/tokens.json` and run `make tokens`. `AppStyleTests` fails on a literal font size, colour, corner, gap or animation in screen code.

## Words

Every user-facing word has a key in `design/strings/<area>.json` (`area.thing.detail`) with English, Spanish and Simplified Chinese. The generator writes the Apple String Catalog (as manual entries), Android `strings.xml`, Windows `.resw`, GTK `.po` files, the extension's `_locales` (`extension.*` keys) and the terminal app's Rust table (`cli.*` keys). `StringCatalogTests` checks each key against the output it is generated into. See [UX specification](/ux/) and [Glossary](/glossary).

## Components

Public types of `ImpDesign`. Platform specs of each are in [Components](/design/components).

- Surface: `Backdrop`, `Card(title, icon:, info:, accessory:)`, `SectionHeader(title, icon:, info:, accessory:)` (icon tile and title leading; accessory then the tip trailing), `.impCard(radius:)`, `.impListRow()`, `SelectableCard`, `SelectMark`.
- Settings: `Row(title, icon:, info:)`, `FieldRow(label, info:)`, `IconTile`, `InfoTip`, `StatusText`, `Badge`.
- Buttons: `.buttonStyle(.primary)`, `.secondary`, `.quiet`, `.destructive`, `.imp(kind, small:)`, `ImpButtonStyle`; `WideButtonStyle` is the phone's big full-width button. `FitLabel(title, systemImage:)` shows icon and title, or the icon alone when narrow. `OnTint` is the ink or paper ShapeStyle for text on a fill.
- Controls: `.toggleStyle(.impSwitch)`, `.impSwitchBare`, `.impButton`; `ImpSegmented` (words, then icons, then a menu; always pass `symbol:`); `ImpStepper`, `ImpPicker`, `CompactMenu`, `ImpTimeField`, `SegmentedTabs`, `ChoiceChip`.
- Fields: `.impField()`, `EditorWell`, `TextArea`, `.impSlider()`.
- Icon-only: `HoverIconButton`, `HoverIconMenu`.
- Notice (spec `notice`): `ActionState` with `StatefulLabel(title, symbol:, state:)` and `.impActionState($state)` (a button carries its own state: wheel, then tick or cross, in a fixed frame; idle again after `Behavior.noticeSeconds`), `.impNotice($notice)` with `ImpNotice.info/success/warning/error` (a floating capsule over the bottom, self-dismissing, tappable, announced), `StatusSlot(text, symbol:, color:)` (a fixed-height line that swaps its words in place). `AttentionNotice` stays for problems that persist.
- Floating: `.impPopover(isPresented:)`, `.impPopoverSurface()`, `PopoverHeader`, `UndoBar`.
- Focus: `.focusRing(_:shown:)`, the only stroke on a control.

Mac-only shared pieces (`SheetFrame`, `SheetScaffold`, `SettingsPage`) are in `apple/Sources/Imp/UI/Shared/DesignSystem.swift`.

Add `import ImpDesign`, then `.impControls()` on the root of a screen for the switch, the buttons and the Imp's tint below it. Pass `tint:` to colour the screen after an Imp. `AppStyleTests` fails when a Mac or iPhone UI file brings a system style back.

## Help, choices and space

- **Feedback never moves the layout.** An error, a warning, progress or an info line is never inserted between things. A button that takes a moment carries its own state (`StatefulLabel` with `ActionState`: wheel, then tick or cross, at a fixed size). A result that is about the page floats over its bottom (`ImpNotice`, `.impNotice`, or `postNotice` from a screen inside `.impNoticeHost()`). A line that explains a field is a `StatusSlot`: always there, same height, words swap in place.
- **Help is a small icon.** `InfoTip` sits after the title of a card or section header. A click or a tap opens a popover as wide as its words. Every platform does the same.
- **One click.** A menu that only holds more buttons is not used. Actions are icon buttons (with a help text) or labelled buttons beside what they act on.
- **Choices by content.** Buttons over dropdowns. Up to five short options are `ImpSegmented` with a symbol on each (words, then icons, then a menu when narrow). A button that would open a small menu of actions shows those actions as icon buttons instead (`HoverIconButton` with help). A menu stays only for a long or open list (languages, models, voices, devices, counts, Imps) and for right-click context menus. It fills its container (equal columns) unless it is beside its title on a wide row. On and off is a switch.
- **Narrow means icons, not small text.** A button never wraps, shrinks or cuts its label.
- **Selection is the Imp's colour.** A chosen thing is filled or lit with the tint. No outline boxes.

## Building a new platform

A new native app (Android, Windows, Linux) shares four things and writes only its views.

1. **Tokens.** Copy `design/generated/<platform>` into the app: Android `ImpTheme.kt` (palettes, `ImpSpacing`, `ImpRadius`, `ImpType`, `ImpMotions`, the `ImpTheme` composable), Windows `ImpTokens.xaml` (Light and Dark theme dictionaries) and `ImpTokens.cs`, Linux `imp-colors-light.css`, `imp-colors-dark.css` and `imp-tokens.css` (`@define-color`). Read a colour from the theme, never as a literal.
2. **Component specs.** `design/components.json` says how each component is built from tokens: pebble, surface, row, icon tile, buttons, segmented, switch, field, info tip, sheet, sheet bar, step indicator, section rail, preset grid, on tint, legible tint, bubble, popover, undo bar, badge, focus. The generator writes them as typed values (`ImpComponents.kt`), styles (`ImpComponents.xaml`) and CSS classes (`imp-components.css`). Build each view from its spec and the rules above. Never add an outline, divider or gradient.
3. **Words.** `values*/strings.xml` (Android), `*/Resources.resw` (Windows) and `gettext/*.po` (Linux) hold every word in all three languages. A key's dots become underscores on Android. Each platform README in `design/generated/<platform>` has the exact steps.
4. **Logic.** The Rust core (`core/`, with the uniffi bindings in `core/ffi`) holds chats, Brains, Imps, triggers, the link between devices and storage. UniFFI writes the Swift bindings today and the same crate gives Kotlin bindings (and a C interface for C# and GTK) later, so the app only draws state and sends intents. See [Architecture](/architecture/).

Then follow the [UX specification](/ux/) screen by screen, the [parity table](/ux/parity) for what each platform has, and [Accessibility](/ux/accessibility). Run `make tokens-check` in CI so the copies never drift from `design/`.
