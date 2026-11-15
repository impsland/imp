# Accessibility

Imp uses the platform's own behavior under its custom look. A control is a real control. It is not rebuilt from gestures. Every screen keeps keyboard use, focus, screen readers, text scaling, contrast, touch targets and Reduce Motion.

## Keyboard

- Everything can be done with the keyboard. The Tab key moves between Imps and controls. Arrow keys move a focused Imp. Return or Space does the main action. Esc closes a panel or a menu.
- Focus is always visible. The focus ring uses the `focus` color and is not removed.
- Shortcuts follow the platform: Command on macOS, Control on Windows and Linux. New Imp is N, Settings is a comma. See [Platforms](/ux/platforms).
- A menu that opens on a right click also opens with the keyboard (the menu key, Shift and F10, or the more button).

## Screen readers

Names come from the string keys, so they are the same words on every platform.

- The canvas has a name and a hint (`home.canvas.label`, `home.canvas.hint`).
- An Imp is read as its name and state (`imp.a11y.label`) and has actions: talk, open settings, hide, let out, send home.
- A drag has a keyboard and screen reader way: the actions above, and arrow keys to move.
- The Hidden Imps element on the floor is always focusable, with "Bring back {name}" for each. A peek is announced (`home.hidden.peek`).
- Imp Settings can always be read as a plain list in a calm order: Brain, Personality, Look, Tools, Triggers, Moves, then Share and Goodbye. See [Imp Settings](/ux/imp-settings).
- Every linked device on the Devices page is one row a screen reader reads whole: its name and its controls. How it is reached is an icon with a spoken label.
- A field's own actions (`fieldAction`) are buttons with a spoken label, after the field in reading order.
- An animation that shows a state has a spoken description, such as `brain.zzz`.
- Changes that happen on their own are announced: an Imp waking, a transfer, an Undo bar, an error.

## Text size

- Apple phones use Dynamic Type. Android uses font scaling (sp). Windows uses text scale. Linux uses the desktop text scale factor.
- Layouts reflow. Text wraps and is never cut off. A row grows taller instead of clipping.
- At accessibility sizes, Imp Settings switches to its plain list.
- On desktop, type sizes are fixed per token and follow the system text scale where the platform has one.

## Contrast

- Text (`text`) has at least 4.5 to 1 against `surface`, `card` and `raised`, in light and dark. The quiet text colors (`muted`, `faint`) are only for secondary text and stay readable.
- The focus ring, the state shapes and controls have at least 3 to 1 against what is around them.
- State is never only a color. A state has a word, a shape or an icon too. The map nodes use both.
- Text, an icon or a switch knob on a coloured control (a button, the selected segment, a switch that is on) is white or black, as the person chose in Settings, App, On colour (`OnTint`). White is the default.
  - The control's fill (`TintFill`) is the Imp's colour when the choice has at least 4.5 to 1 on it. Otherwise it is the nearest deeper (under white) or lighter (under black) shade that does.
  - On a yellow or green Imp, white sits on a deeper yellow or green. The colour of the control gives way, never the legibility.
- The monochrome accent has no hue to keep. It carries ink or paper, whichever reads better.
- An Imp's colour used as text or an icon is adjusted to at least 4.5 to 1 on its ground (`LegibleTint`). It is lighter in dark and darker in light. An Imp can be nearly black or nearly white, so the raw colour is never drawn as it is.
- `ContrastTests` checks this over a sweep of hues in both appearances.
- Light and dark both come from `design/tokens.json` and follow the system appearance. Groups are shown by their fill, never by an outline, so the fill must stay visible against the surface in both.

## Touch targets

The smallest a control's hit area gets:

<!-- tokens: sizes -->
| Size | iPhone | Android | macOS | Windows | Linux | What it is |
| --- | --- | --- | --- | --- | --- | --- |
| `receiptLift` | 84 | 84 | 84 | 84 | 84 | How far a short receipt bar sits above the bottom edge, clear of the hidden Imps' floor and the home indicator. |
| `hit` | 44 | 48 | 28 | 32 | 32 | The smallest a control's hit area gets. |
| `control` | 44 | 48 | 30 | 32 | 34 | The height of a text field or a menu button. |
| `glyph` | 32 | 40 | 26 | 28 | 28 | The visible circle of an icon button. |
| `iconTile` | 30 | 32 | 24 | 28 | 28 | The tile behind a card's or a row's icon. |
| `menuWidth` | 300 | 300 | 300 | 300 | 300 | The width of the menu bar panel. |
| `toastTop` | 70 | 72 | 48 | 48 | 48 | Where a notice in a sheet hangs from the top: below the header, clear of the sheet's grabber. |
| `sheetIcon` | 36 | 40 | 32 | 32 | 32 | The icon tile in a sheet's header. |
| `tipWidth` | 260 | 280 | 260 | 280 | 280 | The widest a help tip's text runs. |
| `popoverWidth` | 340 | 360 | 340 | 360 | 360 | The width of a popover that holds a list or a small form. |
| `popupWidth` | 380 | 380 | 380 | 380 | 380 | The fixed width of a browser toolbar popup. Wide enough for a pebble and a button, narrow enough to stay a popup. |
| `popupListHeight` | 300 | 300 | 300 | 300 | 300 | The tallest a scrolling list grows inside a small popup before it scrolls. |
| `panelWidth` | 380 | 400 | 380 | 400 | 400 | A side panel beside the Imp on a wide screen. |
| `column` | 720 | 720 | 720 | 760 | 720 | The widest a settings column grows. Wider screens centre it. |
| `sheetWidth` | 520 | 560 | 520 | 560 | 560 | The width of a sheet on a desktop. |
| `marker` | 48 | 56 | 44 | 44 | 44 | A setting's round marker around the Imp. |
| `impPortrait` | 44 | 48 | 36 | 40 | 40 | The Imp drawn in a row or a card. |
| `fieldLabel` | 96 | 104 | 76 | 96 | 96 | The label column of a form row, so a card's controls line up. |
| `mark` | 24 | 24 | 20 | 20 | 20 | A round tick or a status mark. |
| `menuTitle` | 180 | 180 | 150 | 160 | 160 | The widest a menu button's title runs before it ends in an ellipsis, so a long name never widens a form. |
| `heroFace` | 64 | 72 | 68 | 68 | 68 | An Imp's face on the kit review's header. |
| `dot` | 8 | 8 | 6 | 6 | 6 | A status dot or a small marker beside a title. |
| `editorWidth` | 390 | 390 | 780 | 780 | 780 | The animation editor's sheet: the stage, the beat's pose and the timeline side by side. |
| `stageWidth` | 320 | 320 | 268 | 268 | 268 | The animation editor's stage, where the Imp acts a beat out. |
| `editorTop` | 300 | 300 | 256 | 256 | 256 | The height of the animation editor's stage and pose row, above the timeline. |
| `switchTrack` | 51 | 52 | 42 | 40 | 46 | The width of a switch's track. |
| `codeSide` | 200 | 200 | 188 | 188 | 188 | The side of the linking QR code. |
| `viewfinderHeight` | 240 | 240 | 220 | 220 | 220 | The height of the camera view that scans a code. |
| `viewfinderAim` | 160 | 160 | 150 | 150 | 150 | The side of the frame to aim a code at. |
| `heroImp` | 120 | 120 | 120 | 120 | 120 | The sleeping Imp on the first-run sheet. |
| `gameButton` | 48 | 48 | 48 | 48 | 48 | The round button that starts a game. |
| `coachBadge` | 34 | 34 | 34 | 34 | 34 | The icon place on a game rules card. |
| `gameIcon` | 26 | 26 | 26 | 26 | 26 | The icon column of a game message. |
| `gameRing` | 16 | 16 | 16 | 16 | 16 | The ring beside the score. |
| `echoPad` | 128 | 128 | 128 | 128 | 128 | The touch pad of the Echo game. |
| `gameCard` | 320 | 320 | 320 | 320 | 320 | The widest a game's results or rules card runs. |
| `gameStat` | 84 | 84 | 84 | 84 | 84 | The narrowest column of a results stat, before the stats stack. |
| `meter` | 110 | 110 | 110 | 110 | 110 | The bar that counts a special phase down. |
| `doorLabel` | 150 | 150 | 150 | 150 | 150 | The widest a door label runs. |
| `bubbleHeader` | 220 | 220 | 220 | 220 | 220 | The widest a speech bubble header runs. |
| `thumbHeight` | 110 | 110 | 110 | 110 | 110 | The tallest a picture in a speech bubble gets. |
| `thumbWaitWidth` | 80 | 80 | 80 | 80 | 80 | The place held for a picture still loading. |
| `thumbWaitHeight` | 60 | 60 | 60 | 60 | 60 | The place held for a picture still loading, its height. |
| `hiddenStrip` | 28 | 28 | 28 | 28 | 28 | The strip along the bottom edge where a hiding Imp peeks. |
<!-- /tokens -->

A control can look smaller than its hit area. The hit area is never smaller than the number above.

## Other rules

- Dark and light both follow the system on platforms that offer them.
- Color pickers are never the only way to set a color: a Look slider has a numeric value for a screen reader.
- Sound is never needed. Anything spoken also has text.

## Why

Following the platform means people can use the tools they already know. Writing it down means every platform has to meet it.

## Rejected

An allowlist of controls that skip these rules. A control that cannot meet them is redesigned.
