<!-- generated from design/components.json, do not edit. Run: node design/generate.mjs -->
# Components

Every Pebble component as a spec. A platform implements the same anatomy with the same tokens, so the Mac, the iPhone, Android, Windows, Linux and the browser popup look and behave alike. The source is `design/components.json`. Sizes are given for the desktop (macOS) and, where they differ, the other platforms are in the generated files of each platform (see `design/generated/<platform>/README.md`).

The rules of the language (one surface, pebbles, no dividers, monochrome chrome, flat, icon-first, help for every setting, nothing clips) are in [the design language](./index.md).

## pebble

A group: a soft fill with big corners. Never an outline, never a divider inside, never a gradient or a shadow.

| Property | Value |
| --- | --- |
| `fill` | `color.card` (dark rgba(255, 255, 255, 0.059), light rgba(23, 24, 28, 0.039)) |
| `fillHover` | `color.cardHover` (dark rgba(255, 255, 255, 0.102), light rgba(23, 24, 28, 0.078)) |
| `radius` | `radius.medium` (16 px) |
| `padding` | `spacing.large` (16 px) |
| `gap` | `spacing.snug` (6 px) |
| `border` | `none` |
| `shadow` | `none` |

- Items inside a pebble are separated by spacing only. A list of things is a stack of pebbles with the 'gap' between them.
- A pebble inside a pebble uses radius.tile.
- The fill is the only thing that shows the group. On the surface colour it must be visible in light and dark.

## surface

The one background of every window, screen and sheet. A sheet has exactly the same background as the app.

| Property | Value |
| --- | --- |
| `fill` | `color.surface` (dark #141519, light #f3f1ec) |
| `text` | `color.text` (dark #f2f0ea, light #17181c) |
| `border` | `none` |
| `gradient` | `none` |

- Only things that float for a moment (popover, menu, bubble, undo bar) use color.raised.

## row

One setting: a picture, one to three plain words and a control. A help question mark only when the title cannot be understood without it.

| Property | Value |
| --- | --- |
| `minHeight` | `size.hit` (28 px) |
| `iconTile` | `size.iconTile` (24 px) |
| `iconSize` | `icon.small` (10 px) |
| `gap` | `spacing.cozy` (10 px) |
| `title` | `type.body` (13 px, weight 400, rounded) |
| `titleColor` | `color.text` (dark #f2f0ea, light #17181c) |
| `helpColor` | `color.muted` (dark rgba(242, 240, 234, 0.702), light rgba(23, 24, 28, 0.702)) |
| `divider` | `none` |

- Every row has an icon. It has its own info tip only when its one-to-three-word title cannot be understood without it, and never a second tip for the same thing (a label tip and a field tip, a section tip and its only row's tip). Help is one tip per card or section header.
- The icon sits in an icon tile and never touches the tile's edge: padding on every side is at least spacing.snug.
- When the control does not fit beside the title, it moves under the title. Nothing overlaps or clips (R13).
- There is no line between rows.

## iconTile

A round bead behind an icon.

| Property | Value |
| --- | --- |
| `size` | `size.iconTile` (24 px) |
| `radius` | `radius.full` (999 px) |
| `fill` | `color.card` (dark rgba(255, 255, 255, 0.059), light rgba(23, 24, 28, 0.039)) |
| `iconColor` | `color.text` (dark #f2f0ea, light #17181c) |
| `iconSize` | `icon.small` (10 px) |

- Inside an Imp's context the fill is the Imp's own colour and the icon uses 'on tint' (ink or paper by contrast).

## button.primary

The one main action of a screen. Filled with the accent (the Imp's colour inside an Imp's context).

| Property | Value |
| --- | --- |
| `fill` | `color.accent` (dark #f2f0ea, light #17181c) |
| `text` | `color.onAccent` (dark #17181c, light #f2f0ea) |
| `radius` | `radius.full` (999 px) |
| `paddingX` | `spacing.large` (16 px) |
| `paddingY` | `spacing.small` (8 px) |
| `minHeight` | `size.hit` (28 px) |
| `type` | `type.label` (12.5 px, weight 600, rounded) |
| `motionHover` | `motion.hover` (0.15 s) |
| `motionPress` | `motion.press` (0.15 s) |

- The label has padding on every side and never touches the edge.
- A label that does not fit becomes an icon (FitLabel), it is never scaled down or cut.
- Disabled uses opacity.disabled.

## button.secondary

A second action next to the primary one.

| Property | Value |
| --- | --- |
| `fill` | `color.card` (dark rgba(255, 255, 255, 0.059), light rgba(23, 24, 28, 0.039)) |
| `fillHover` | `color.cardHover` (dark rgba(255, 255, 255, 0.102), light rgba(23, 24, 28, 0.078)) |
| `text` | `color.text` (dark #f2f0ea, light #17181c) |
| `radius` | `radius.full` (999 px) |
| `paddingX` | `spacing.large` (16 px) |
| `paddingY` | `spacing.small` (8 px) |
| `minHeight` | `size.hit` (28 px) |
| `type` | `type.label` (12.5 px, weight 600, rounded) |
| `border` | `none` |

- No outline.

## button.quiet

A text or icon button without a fill until hovered.

| Property | Value |
| --- | --- |
| `fill` | `none` |
| `fillHover` | `color.cardHover` (dark rgba(255, 255, 255, 0.102), light rgba(23, 24, 28, 0.078)) |
| `text` | `color.muted` (dark rgba(242, 240, 234, 0.702), light rgba(23, 24, 28, 0.702)) |
| `textHover` | `color.text` (dark #f2f0ea, light #17181c) |
| `radius` | `radius.full` (999 px) |
| `paddingX` | `spacing.medium` (12 px) |
| `paddingY` | `spacing.small` (8 px) |
| `minHeight` | `size.hit` (28 px) |
| `type` | `type.label` (12.5 px, weight 600, rounded) |

- An icon-only quiet button is a round glyph: size.glyph visible, size.hit as the hit area.

## button.destructive

An action that removes something.

| Property | Value |
| --- | --- |
| `fill` | `color.errorBackground` (dark rgba(255, 80, 80, 0.141), light #ffe8e6) |
| `text` | `color.danger` (dark #ff7a70, light #c62828) |
| `radius` | `radius.full` (999 px) |
| `paddingX` | `spacing.large` (16 px) |
| `paddingY` | `spacing.small` (8 px) |
| `minHeight` | `size.hit` (28 px) |
| `type` | `type.label` (12.5 px, weight 600, rounded) |
| `border` | `none` |

- Always asks again or offers an undo bar.

## segmented

A choice of two to five exclusive options in one pebble.

| Property | Value |
| --- | --- |
| `track` | `color.card` (dark rgba(255, 255, 255, 0.059), light rgba(23, 24, 28, 0.039)) |
| `selectedFill` | `color.accent` (dark #f2f0ea, light #17181c) |
| `selectedText` | `color.onAccent` (dark #17181c, light #f2f0ea) |
| `text` | `color.muted` (dark rgba(242, 240, 234, 0.702), light rgba(23, 24, 28, 0.702)) |
| `radius` | `radius.full` (999 px) |
| `padding` | `spacing.tight` (4 px) |
| `segmentMinHeight` | `size.control` (30 px) |
| `type` | `type.label` (12.5 px, weight 600, rounded) |

- Falls back in this order when the width is too small: words, then icons (every option has an icon), then a menu button. It never reports a width smaller than its columns need, so the fallback is never skipped and nothing overlaps or clips at any text size.
- The segments are equal columns. The bar fills the width it is given, except beside its title on a wide row, where it is only as wide as its words.
- Three long sentence-like options are a picker or a list of selectable cards, not a segmented bar.
- The selected segment is filled, the others have no fill and no outline.

## switch

An on/off control.

| Property | Value |
| --- | --- |
| `trackWidth` | `size.switchTrack` (42 px) |
| `trackOff` | `color.card` (dark rgba(255, 255, 255, 0.059), light rgba(23, 24, 28, 0.039)) |
| `trackOn` | `color.accent` (dark #f2f0ea, light #17181c) |
| `knob` | `color.onAccent` (dark #17181c, light #f2f0ea) |
| `hit` | `size.hit` (28 px) |
| `motion` | `motion.quick` (0.12 s) |

- The whole row can be tapped as well. The knob animates with motion.quick (no animation under Reduce Motion).

## field

A text field.

| Property | Value |
| --- | --- |
| `fill` | `color.well` (dark rgba(0, 0, 0, 0.278), light rgba(23, 24, 28, 0.059)) |
| `radius` | `radius.small` (10 px) |
| `paddingX` | `spacing.cozy` (10 px) |
| `height` | `size.control` (30 px) |
| `text` | `color.text` (dark #f2f0ea, light #17181c) |
| `placeholder` | `color.faint` (dark rgba(242, 240, 234, 0.451), light rgba(23, 24, 28, 0.502)) |
| `type` | `type.body` (13 px, weight 400, rounded) |
| `border` | `none` |
| `focusRing` | `stroke.focus` (2 px) |

- The only outline is the focus ring (color.focus) while the field has focus.
- The label sits in a column size.fieldLabel wide, or above the field on narrow widths.
- An action that works on the field's value (choose from a list, show, paste or remove a key, clear a search) sits inside the field, at its trailing edge, as a 'fieldAction'. It is never a separate button beside the field: a capsule next to the field's corners clashes.
- An action of the page (New, Add, Import) is never on the field's line. It goes in the header of the card or list the field belongs to.
- A search field shows its magnifying glass inside the field, on the leading edge.

## fieldAction

An action inside a field: a quiet glyph at the field's trailing edge.

| Property | Value |
| --- | --- |
| `inset` | `spacing.tight` (4 px) |
| `radius` | `radius.small` (10 px) |
| `icon` | `icon.medium` (12 px) |
| `text` | `color.muted` (dark rgba(242, 240, 234, 0.702), light rgba(23, 24, 28, 0.702)) |
| `textHover` | `color.text` (dark #f2f0ea, light #17181c) |
| `fillHover` | `color.cardHover` (dark rgba(255, 255, 255, 0.102), light rgba(23, 24, 28, 0.078)) |
| `fillPressed` | `color.line` (dark rgba(255, 255, 255, 0.122), light rgba(23, 24, 28, 0.122)) |
| `border` | `none` |

- As tall as the field less 'inset' above and below, and square.
- Its corner is the field's 'radius' less 'inset', so the corners stay concentric.
- No fill until hovered or pressed. It always has a help text, which is also its spoken label.
- Several actions sit side by side in the order they are used (show, paste, remove).

## infoTip

The help question mark and the popover it opens. One or two short sentences for a child.

| Property | Value |
| --- | --- |
| `button` | `size.hit` (28 px) |
| `glyph` | `icon.tiny` (8 px) |
| `glyphColor` | `color.muted` (dark rgba(242, 240, 234, 0.702), light rgba(23, 24, 28, 0.702)) |
| `maxWidth` | `size.tipWidth` (260 px) |
| `fill` | `color.raised` (dark #1e2026, light #ffffff) |
| `radius` | `radius.medium` (16 px) |
| `padding` | `spacing.cozy` (10 px) |
| `text` | `color.text` (dark #f2f0ea, light #17181c) |
| `type` | `type.caption` (12.5 px, weight 500, rounded) |
| `shadow` | `shadow.card` (y 10, blur 30) |

- The popover is exactly as wide as its words, at most maxWidth. Never a full-width block.
- The popover is one surface: its body and its arrow share one fill, and the arrow points at the glyph itself, not at a larger target around it. Where the platform draws the arrow itself and offers no colour for it (macOS, iOS), the whole popover keeps the platform's own popover background. Never a custom fill under a system arrow. Elsewhere the fill is color.raised.
- Opens on click or tap only, closes on Escape or a click outside. There is no hover tooltip: it is the only help mechanism.
- One per card or section header. A row has its own only when its title cannot be understood without it. In all three languages.

## tintFill

The fill of a coloured control (a filled button, the selected segment, a switch that is on, a badge on an Imp's colour).

| Property | Value |
| --- | --- |
| `ink` | `color.ink` (dark #17181c, light #17181c) |
| `paper` | `color.paper` (dark #f2f0ea, light #f2f0ea) |
| `least` | `4.5` |

- What sits on a coloured control is white (paper) or black (ink). The person chooses it once for the whole app, and white is the default.
- A fill with a hue (an Imp's colour) is used as it is when the chosen white or black has at least 4.5 to 1 on it (WCAG relative luminance). Otherwise the fill moves toward black (under white) or toward white (under black) by the least amount that reaches 4.5, keeping its hue. A yellow or green Imp under white shows a deeper yellow or green.
- A fill with no hue (the monochrome accent, a grey) is used as it is, and carries ink or paper, whichever has the higher ratio.
- The fill and what sits on it come from this one rule on every control, on every screen and platform.

## onTint

Text, an icon or a switch knob on a 'tintFill'.

| Property | Value |
| --- | --- |
| `ink` | `color.ink` (dark #17181c, light #17181c) |
| `paper` | `color.paper` (dark #f2f0ea, light #f2f0ea) |
| `least` | `4.5` |

- On a fill with a hue it is the white or black the person chose. Never the colour the fill is made of.
- It always sits on a 'tintFill' of the same colour, never on the raw colour, so it has at least 4.5 to 1.

## legibleTint

An Imp's colour used as a foreground (text, an icon, a link) on the surface or a raised surface.

| Property | Value |
| --- | --- |
| `least` | `4.5` |
| `ground` | `color.surface` (dark #141519, light #f3f1ec) |
| `raisedGround` | `color.raised` (dark #1e2026, light #ffffff) |

- The colour is used as it is when its contrast ratio on its ground is at least 4.5. Otherwise it moves toward white (dark appearance) or black (light appearance) by the least amount that reaches 4.5, keeping its hue as far as it can.
- The raw colour is never a foreground. As the fill of a control it goes through 'tintFill', with 'onTint' on top.

## sheetBar

The top bar of every modal flow and sheet: Back leading, a centred title or step indicator, Close trailing.

| Property | Value |
| --- | --- |
| `height` | `size.hit` (28 px) |
| `gap` | `spacing.cozy` (10 px) |
| `glyph` | `icon.small` (10 px) |
| `glyphColor` | `color.muted` (dark rgba(242, 240, 234, 0.702), light rgba(23, 24, 28, 0.702)) |
| `title` | `type.cardTitle` (14 px, weight 600, rounded) |
| `background` | `none` |

- Back (leading) returns to the previous step or the hub and never closes the flow. Close (trailing, modal flows only) dismisses the flow and carries Escape. Leave out the one that does not apply.
- Both are plain icon glyphs with no background until hover or press, and each keeps a target of size.hit.
- A sheet's main action is one primary button at the bottom of the content, not a text button in the bar.

## stepIndicator

Round marks for the steps of a flow, the current one filled with the Imp's colour.

| Property | Value |
| --- | --- |
| `mark` | `icon.tiny` (8 px) |
| `gap` | `spacing.small` (8 px) |
| `done` | `color.muted` (dark rgba(242, 240, 234, 0.702), light rgba(23, 24, 28, 0.702)) |
| `todo` | `color.faint` (dark rgba(242, 240, 234, 0.451), light rgba(23, 24, 28, 0.502)) |
| `current` | `color.accent` (dark #f2f0ea, light #17181c) |
| `hit` | `size.hit` (28 px) |

- Tappable when the steps can be revisited, each with a target of size.hit. Spoken as 'Step 2 of 3, name'.
- It sits in the sheet bar, centred.

## sectionRail

The sections of a settings screen, always one tap away.

| Property | Value |
| --- | --- |
| `itemMinHeight` | `size.hit` (28 px) |
| `itemRadius` | `radius.tile` (12 px) |
| `selectedFill` | `color.card` (dark rgba(255, 255, 255, 0.059), light rgba(23, 24, 28, 0.039)) |
| `hover` | `color.cardHover` (dark rgba(255, 255, 255, 0.102), light rgba(23, 24, 28, 0.078)) |
| `icon` | `icon.small` (10 px) |
| `gap` | `spacing.tight` (4 px) |
| `type` | `type.body` (13 px, weight 400, rounded) |

- A vertical rail beside the content on a desktop window. A horizontal scrolling bar above the content on a phone or a narrow window.
- Each item is an icon and one to three words. The selected one is a pebble. An item that needs attention shows a small dot, and the state is also spoken.
- On a phone the section's panel replaces the hub, with Back in the sheet bar. Beside the hub when there is room.

## presetGrid

Evenly sized choices (the service choices, Remote and Local) as tiles in a grid, each with a link to the provider's page.

| Property | Value |
| --- | --- |
| `minColumn` | `size.menuTitle` (150 px) |
| `gap` | `spacing.small` (8 px) |
| `radius` | `radius.tile` (12 px) |
| `fill` | `color.card` (dark rgba(255, 255, 255, 0.059), light rgba(23, 24, 28, 0.039)) |
| `selectedFill` | `color.accent` (dark #f2f0ea, light #17181c) |
| `selectedText` | `color.onAccent` (dark #17181c, light #f2f0ea) |
| `minHeight` | `size.hit` (28 px) |

- Every cell is exactly as wide as the others. The column count is the most that fit at the minimum width, and the last row is balanced rather than leaving one orphan.
- A tile shows its symbol, its title (Remote, Local) and a detail (the service it fills in). The chosen one is filled with the accent.
- Choosing one fills the address and the name when untouched, and the address stays freely editable, so any compatible service works. There is no separate 'Other'.
- A tile's link opens the provider's key or model page without choosing the tile.
- The service choices come from data (spec/presets/services.json), not from code.

## bubble

The Imp's speech bubble on the desktop.

| Property | Value |
| --- | --- |
| `fill` | `color.raised` (dark #1e2026, light #ffffff) |
| `text` | `color.text` (dark #f2f0ea, light #17181c) |
| `radius` | `radius.bubble` (24 px) |
| `padding` | `spacing.medium` (12 px) |
| `shadow` | `shadow.card` (y 10, blur 30) |
| `type` | `type.body` (13 px, weight 400, rounded) |

- A shadow is allowed because it floats over other content.
- Desktop only. The phone's bubble sits over the app's own stage, so it has no appearance setting.
- Appearance is a style, solid (default) or translucent, and an opacity between opacity.bubbleMin and 1 (default opacity.bubbleDefault). Solid is color.raised as is.
- Translucent is color.raised at that opacity over a blur of whatever is behind the bubble, so text never sits on raw pixels. The blur and the fill cover the bubble and its tail as one shape, with a hairline edge (stroke.hairline) so the shape reads on a background of its own colour.
- Only the fill is translucent: text, icons and controls stay at full opacity, and an Imp's colour as a foreground is legible on color.raised.
- Reduce Transparency or Increase Contrast in the system makes the bubble solid. On a platform with no background blur, translucent falls back to solid.

## popover

A small floating panel with a list or a small form.

| Property | Value |
| --- | --- |
| `fill` | `color.raised` (dark #1e2026, light #ffffff) |
| `radius` | `radius.medium` (16 px) |
| `padding` | `spacing.medium` (12 px) |
| `width` | `size.popoverWidth` (340 px) |
| `shadow` | `shadow.card` (y 10, blur 30) |
| `border` | `none` |

- Items inside are pebbles or plain rows, never separated by lines.
- A popover with a system-drawn arrow (macOS, iOS) keeps the platform's own popover background for body and arrow alike. See 'infoTip'.

## barMenu

The menu of the menu bar or tray icon: the Imps that are out and a few actions.

| Property | Value |
| --- | --- |
| `fill` | `color.raised` (dark #1e2026, light #ffffff) |
| `radius` | `radius.medium` (16 px) |
| `padding` | `spacing.small` (8 px) |
| `rowMinHeight` | `size.hit` (28 px) |
| `rowRadius` | `radius.tile` (12 px) |
| `rowHover` | `color.cardHover` (dark rgba(255, 255, 255, 0.102), light rgba(23, 24, 28, 0.078)) |
| `iconSize` | `icon.small` (10 px) |
| `gap` | `spacing.cozy` (10 px) |
| `type` | `type.body` (13 px, weight 400, rounded) |
| `width` | `size.popoverWidth` (340 px) |

- Rows are icon first, one to three words, no separators. Groups are separated by spacing.
- The Imp's colour is the only colour.

## undoBar

A bar that floats at the bottom after something was removed.

| Property | Value |
| --- | --- |
| `fill` | `color.raised` (dark #1e2026, light #ffffff) |
| `text` | `color.text` (dark #f2f0ea, light #17181c) |
| `radius` | `radius.full` (999 px) |
| `padding` | `spacing.medium` (12 px) |
| `shadow` | `shadow.card` (y 10, blur 30) |
| `motion` | `motion.expand` (0.2 s) |

- Disappears by itself after a few seconds. Under Reduce Motion it fades.

## badge

A tiny status label or count.

| Property | Value |
| --- | --- |
| `fill` | `color.card` (dark rgba(255, 255, 255, 0.059), light rgba(23, 24, 28, 0.039)) |
| `text` | `color.muted` (dark rgba(242, 240, 234, 0.702), light rgba(23, 24, 28, 0.702)) |
| `radius` | `radius.full` (999 px) |
| `paddingX` | `spacing.snug` (6 px) |
| `paddingY` | `spacing.tight` (4 px) |
| `type` | `type.small` (11.5 px, weight 400, rounded) |

- Status colours (good, danger, warn) are the only coloured badges.

## focus

The keyboard focus ring of every control.

| Property | Value |
| --- | --- |
| `color` | `color.focus` (dark #f2f0ea, light #17181c) |
| `width` | `stroke.focus` (2 px) |
| `offset` | `spacing.hairline` (2 px) |

- Drawn only for keyboard focus, on every interactive element.

