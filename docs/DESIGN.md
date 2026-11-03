# Design

Imp has one look on the Mac and the iPhone, kept in the `ImpDesign` library (`Sources/ImpDesign`). It is SwiftUI only, so both apps import it. Anything that needs AppKit or UIKit (the Mac's title bar and sheets, the phone's keyboard handling) stays in its own app.

## The rule

Custom look, standard behavior. Every control is a real SwiftUI control (`Button`, `Toggle`, `TextField`, `Slider`, `Picker`, `Menu`) wearing the app's style. Do not rebuild a control from gestures. Keep what the system gives for free: the keyboard focus ring, VoiceOver, Dynamic Type on the iPhone, Return and Esc, pressed, hover and disabled states. A control's hit area is at least 44 pt on the iPhone and 28 pt on the Mac.

## Tokens

| Token | What it is |
| --- | --- |
| `Dungeon` | The palette: `deep`, `wallTop`, `wallBottom`, `wall`, `stone`, `stoneLight`, `doorway`, `ember`, `flame`, `cream`, `muted`, `card`, `cardEdge`, `well`, `good`. Fixed colours for the dark wall, they do not follow Light and Dark. |
| `Radius` | `small` 8, `medium` 14, `large` 18, `bubble` 22. |
| `Spacing` | `hairline` 2, `tight` 4, `small` 8, `medium` 12, `large` 16, `page` 20, `huge` 28. |
| `Sizing` | `hit` (44 iPhone, 28 Mac) and `control` (44 iPhone, 30 Mac). |
| `Typeface` | `title`, `cardTitle`, `body`, `label`, `caption`, `small`, `mono`. Dynamic Type on the iPhone, fixed sizes on the Mac. |
| `Timing` | `short` 0.12 s and `medium` 0.25 s, with `quick` and `smooth` animations. |
| `impTint` | An environment value: the colour of the Imp being shown. Buttons, switches, fields and tabs follow it. |

Motion honours Reduce Motion. Use `.impAnimation(value:)` instead of `.animation(_, value:)` and `withImpAnimation(reduceMotion:)` instead of `withAnimation`.

## Components

- Buttons: `.buttonStyle(.primary)`, `.secondary`, `.quiet`, `.destructive`, or `.imp(kind, small:)`. `.impPill(kind)` dresses a `Menu` label the same way. `EmberButtonStyle` is the phone's big full-width button.
- Switch: `.toggleStyle(.impSwitch)`. It is a `Toggle` and reads as a switch to VoiceOver.
- Fields: `.impField()` on a `TextField` or `SecureField`, `EditorWell` for a fixed-height editor, and `TextArea(title, text:, placeholder:, minLines:, maxLines:)` for a few lines that grow with the text and then scroll (same well, edge and radius as `.impField()`, muted placeholder at the text's inset).
- Slider: `.impSlider()` on a `Slider`.
- Stepper: `ImpStepper(value:in:step:label:)` (a label and a minus and plus pill, a real `Stepper` for VoiceOver).
- Short choices: `ImpSegmented` for a few text options on one line. Toggle button: `.toggleStyle(.impButton)`. Time of day: `ImpTimeField`. A switch with no label of its own (the row has the title): `.toggleStyle(.impSwitchBare)`.
- Icon-only: `HoverIconButton` and `HoverIconMenu` (a glyph with a hover circle, always give them a `help`).
- Tabs: `SegmentedTabs`. Choices: `ChoiceChip`.
- Menus: `CompactMenu` for a menu with your own items, `ImpPicker` for a `Picker` shown as a menu.
- Containers: `Card`, `Row`, `FieldRow`, `CardDivider`, `SelectableCard`, `Badge`, `StatusText`, `InfoTip`, and the modifiers `.impCard()` and `.impListRow()`.
- The wall: `DungeonWall` (gradient, bricks, floor). Each app lays its own embers on top.

## Using it

Add `import ImpDesign`, then put `.impControls()` on the root of a screen to get the switch, the secondary buttons and the Imp's tint for everything below it. Pass `tint:` to colour the screen after an Imp. Single controls can still choose a different `.buttonStyle(...)`. Text fields and sliders opt in one by one with `.impField()` and `.impSlider()`. On the Mac, `SettingsPage`, `SheetFrame` and the model popover already apply `.impControls()`, so Settings never shows a system-styled button or switch. System file panels, native menu items and alerts stay system on purpose. `AppStyleTests` fails if any Mac UI file or iPhone file brings a system style back, and if an iPhone screen root drops `.impControls(`.

On the Mac the package target `Imp` depends on `ImpDesign`. On the iPhone `iOS/project.yml` lists the `ImpDesign` product next to `ImpKit`.

When you need a number, a colour or a corner, look in the tokens first. If it is missing and two screens want it, add it there instead of writing it twice.
