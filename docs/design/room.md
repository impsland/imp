# The room never leaves

This is the idea behind the phone app. It names roles, tokens and behaviour, not pixels or platform controls, so Android can build the same thing. The iPhone ships it first.

## The idea

The app is one room where the Imps fly freely, over the whole screen. Nothing restricts them and nothing permanent is drawn over them. Everything else in the app is a sheet that rises over the room, and the room stays there, alive, above it.

Three rules follow from that.

1. **The Imp comes to you.** When a sheet about an Imp opens, that Imp flies up into the room left above the sheet and waits there, in its glow. You talk to the Imp, not to a picture of it in a header. It can still be touched, carried and thrown.
2. **An Imp's sheet wears the Imp's colour.** Its chat, its talks, its settings and its first run are tinted with it. The app's own sheets (Settings, Link a device) stay monochrome.
3. **One sheet, one anatomy, one way back.** There is only ever one sheet. Every sheet has the same bar, and Close always leads to the same place.

## The sheets

| Sheet | About | Rests at half height | What it holds |
| --- | --- | --- | --- |
| Imp | One Imp | Yes | Its chat with you. Settings is one tap away in the bar. Its talks with other Imps are a side room of the same sheet, opened from the Imp's menu. |
| Imp Settings | One Imp | No | The Imp with its markers, then one panel at a time. |
| First run | One Imp | No | Waking an Imp with a Brain, step by step. |
| New Imp | Nobody yet | No | The same as Imp Settings, for an Imp being hatched. |
| Settings | The app | Yes | Brains, Devices, Sharing, App. |
| Link a device | The app | No | Only on the first screen: this device's code, the two ways to take another code, this device's name. |

A sheet that rests at half height opens there (`behavior.sheetHalfCover`), and the room above it takes touches. Pulled up, it covers the screen and the room rests.

### Anatomy

| Part | Role | Tokens |
| --- | --- | --- |
| Surface | The app surface, flat. | `color.surface` |
| Bar | Back on the leading side (only inside a step), who or what the sheet is about, Close on the trailing side. Always the same distance from the top and the sides. | `size.hit`, `spacing.medium`, `type.cardTitle` |
| Imp bar | For an Imp's sheet the bar shows the name and one line of state on the leading side. It shows the Imp's small portrait whenever the room is not in view (the sheet at full height, or lifted by the keyboard), because otherwise the Imp itself is in view. The portrait plays what the Imp in the room plays (its mood and the animations its home sends) and watches what you type. | `size.impPortrait`, `type.small`, `color.muted` |
| Content | Pebbles in one scrolling column. | `spacing.page` at the sides, `spacing.medium` between |
| Main action | At most one wide button, pinned at the bottom. | `button.primary`, wide |

### One way back

Shared code decides (`PhoneRouter` in ImpKit), so every platform does the same.

- Close returns to the room.
- One exception: Imp Settings opened from that Imp's sheet returns to that sheet, on the side it was on. If the Imp said goodbye there, it returns to the room.
- Swiping a sheet down always returns to the room.
- Tapping another Imp in the room above an Imp's sheet turns the sheet into that Imp's, in place.
- When an Imp leaves (it went home, or said goodbye), a sheet about it closes.
- Waking an Imp ends in its chat.

## The Imp comes to you

- Where: the middle of the free room, `behavior.summonHeight` of the way down, so its speech bubble has room above it (`Summon` in ImpKit).
- How: a spring (`behavior.summonStiffness`, `behavior.summonDamping`), with a small overshoot. It then rests exactly there, so the room goes back to its calm frame rate.
- It wears `opacity.glow` while its sheet is open. The others keep `opacity.tintFill`.
- Carried and let go, it comes back. Thrown off the side, it leaves as always.
- With too little free room (the sheet covers the screen), nobody is moved.
- With Reduce Motion nobody is moved. The glow still shows whose sheet it is.
- When the sheet closes the Imp stays where it is and drifts as before.

## The first screen

One sleeping Imp, what it says, and three ways to begin in order of weight: a wide main button that wakes it, a wide quiet button that links a device, and a small button that hatches an Imp of your own. Linking is its own sheet, so the first screen has no code, no camera and no field on it.

## What stays

The room itself: the open canvas, the top bar, the menus on an Imp, the games. It was already what the app is about.
