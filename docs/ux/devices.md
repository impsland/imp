# Devices

The Devices screen is the one place that says where every Imp is and how the devices talk to each other. It is its own screen, not a section of Settings. It is on the Mac. The iPhone still has a Devices sheet and a Devices section in its settings ([Parity](/ux/parity)).

## Where it opens

- The **Devices** corner button of the [main screen](/ux/main-screen): bottom left on macOS, bottom right where the window buttons are top right. It wears a small green dot while a linked device is connected, and a warning mark while a linked device cannot be reached.
- A link to a Devices setting (`imp://settings?setting=devices_hop`, a tool that points at it, an attention item) opens this screen and lights the setting.

## The layout

A canvas fills the window under a top bar. The top bar has Back, the title and one Link a device button (the QR icon). While nothing is linked, the same action also floats at the bottom of the canvas as a button, so the first step is never hidden. Pressing a device, an Imp or a line opens a sheet about it. Pressing empty canvas does nothing. Back (and Esc) leaves for the Imps.

## The map

The map is a canvas drawn with [SwiftFlow](https://github.com/aaurelions/SwiftFlow) (MIT, see `THIRD_PARTY_NOTICES.md`) in the app's own look: the window's surface, quiet dots, muted lines. `DeviceGraph` turns the live `DeviceMap` into the canvas's nodes and lines, so what is drawn is always the current state.

- **Devices are cards.** This Mac and every linked Mac or iPhone, each with its icon, its name and a state mark. This Mac is in the middle and the other devices are on its two sides. A device this Mac knows only through another (the home of a visitor, or where an Imp was passed on to) is drawn dimmed, has no state mark and hangs on the device that relays it by a thin dotted line. It can be opened and linked directly.
- **The Hop is a button in the bar**, not a card: one icon, tinted green when a channel runs through it or a check reached it, red when it is set wrong or unreachable, and muted otherwise. It opens the Hop's sheet.
- **Imps are chips inside the device their body is on**, in a grid of at most three across. An Imp of this Mac is a strong chip, an Imp of another device is a visitor and is lighter.
- **A channel is one line between two devices**, with no text on it: solid on the local network, dashed through the Hop. Pressing a dashed line opens the channel's sheet, which shows the Hop as a row. A line that is not connected is faint. What a device may do is not on its line: it is in its sheet.
- **Hovering** a device, an Imp or a line lights it and its lines and dims the rest. Small dots run only along the lines in the light.
- **Tethers** are thin lines in the Imp's own colour, from an Imp's chip to the device where it thinks and runs its tools (its home). They are hidden, and appear only while the Imp or one of the two devices is hovered or open. An Imp that is away wears a tiny house and the symbol of its home device on its chip, so where it lives is seen without a line. Talk lines, to the Imps it can message, appear the same way. An Imp's body can be somewhere else. Its mind is always at home ([Imp Link](/connecting/link)).
- Nothing on the canvas can be selected, connected or deleted, so SwiftFlow's own keys (Delete, undo) never change the map.

### Moving around

- **Pan** by dragging empty canvas, or with two fingers or the scroll wheel. Scrolling pans. It does not zoom.
- **Zoom** with the pinch gesture or the **+** and **-** buttons.
- **Drag a device** to move it. It stays where it was put while the app runs. A refresh of the link never puts it back. Imps cannot be dragged out of their device.
- **The controls** sit at the bottom leading corner: Zoom in, Zoom out, and Show all, which shows the whole map again.

### How it fits on open

The first view is worked out from the devices' own sizes and places (`DeviceViewport`), not from the canvas measuring them, so it is the same every time: the whole map, centred, with a margin (the `vast` spacing token) on every side. The zoom is held between 0.2 and 1.2, so a small map is not blown up and a huge one is not shrunk to nothing.

It is fitted again when the window changes size, when a device or an Imp comes or goes, and when Show all is pressed. Once you pan or zoom, the view is yours: a window resize or a refresh of the link no longer moves it, until you press Show all or the set of devices and Imps changes.

## The sheets

Pressing something opens one sheet, one compact layout for every kind. The header has a picture, the name and one status pill (a coloured dot and one or two words: Here, Nearby, Via server, Away, Through the device that relays it, Visiting). Then come one row of actions, a short list of rows with a picture each, and last, alone, what destroys. There are no paragraphs: what a row means is its tooltip and spoken hint. A row that points at another thing (a device, an Imp, the line, the Hop) swaps the sheet for that one. Cancel is on the leading side and Done on the trailing side. Switches act at once. Done keeps them and Cancel puts them back as they were when the sheet opened (the Hop, the plugs and an Imp's tools). An Imp sent home or a device forgotten stays so, because those are actions. Forget, and Forget everyone, ask first. Forgetting calls this Mac's Imps home from that device and sends its visitors home. A sheet about something that is gone (a forgotten device, an Imp that came home) closes.

The Hop is a setting, not a linked thing, so it has its own sheet (`DevicesSheet.hop`) that never depends on the Hop being in the map: it stays open while an address is being chosen. Its button is in the bar, and the sheet of a dashed line has it as a row.

| Pressed | The sheet shows | Actions |
| --- | --- | --- |
| This Mac | Link a device. Its addresses (or Not reachable), the Local Network notice when the system blocks it. "On its screen": its Imps. | Link a device. Forget Everyone, alone and last (only when anything is linked). |
| A linked device | Its connection (opens the line's sheet), the Mine switch (it plugs in Talk & files), "What it can use here" (tool plugs, folded, while it is Mine), "On its screen": its Imps. | Switch Mine and its tools. Open an Imp. Send home per Imp, and for all. Forget, alone and last. |
| A device known only through another | The pill says "Through" the device that relays it. "On its screen": its Imps. | Link, which opens the Link sheet. |
| The Hop | The Hop control (the same card as in the Link sheet), and chips for the devices reached through it. | Choose Imp's servers, Custom or Off. Type and Check an address. Open a device. |
| One of this Mac's Imps (its chip) | Where it is when away (opens that device), its home (opens it), its tools, folded, and whom it can message, as chips. | Send home, when it is away. Open its settings. Switch a tool group or tool server for this Imp. Open an Imp it talks to. |
| An Imp of another device | Its home (opens it). The pill says where it is (Visiting, or its device). | Send home, when it is visiting this Mac. |
| A line (a connection) | Its two ends (each opens its sheet) and its path: the address, or the Hop as a row when the line is dashed. | Open a device or the Hop. |
| A tether | The sheet of its Imp. | As above. |

## Plugs

What a linked device may do with this Mac's Imps is shown as plugs and a socket strip, not as switches with names to learn: each capability is a plug (a picture and a short word), and when it is plugged into the device's socket the Imps here have that capability for that device. A plug that is in sits in the socket with a soft glow. One that is out rests above it with an outline. A tap plugs or unplugs it, and so does pulling it down into the socket or up out of it. The rows are even and full width, a short last row sharing its width (four plugs are two and two, never three and one). Each plug is a toggle for a screen reader, with its title and "plugged in" or "not plugged in". With Reduce Motion on, plugs fade instead of sliding.

The first plug is **Talk & files**: the device is trusted to talk to the Imps and to share files. Two rules combine (`DeviceAccess`):

1. **Talk & files.** A device without it gets no tools at all, whatever the other plugs say (`AskOrigin`). Plugging a tool plugs Talk & files too. Unplugging it keeps the tool plugs as they were, for when it is plugged back.
2. **Tool plugs.** A device with Talk & files gets the Imp's own tools less the groups that are not plugged for it: the tool groups an Imp of this Mac uses, the commands tool and every tool server that is on. Everything is plugged until it is unplugged.

A plug can only narrow: it never gives a tool to an Imp that does not have it. The limits are kept per device (`DeviceToolLimits`) and are removed when the device is forgotten. On the canvas a line's badge shows the route, then a plug and the capabilities plugged in (an outlined, dimmed plug when none is). See [Imp Link](/connecting/link).

## The Link sheet and the Hop

Link a device opens one sheet with two tabs, **Show code** and **Scan code** ([Imp Link](/connecting/link)). Show code is this Mac's code with the three steps for the other device, and Copy link in the footer. Scan code is the camera, the link field and a status line, with Paste (a link or a picture of a code) and Link in the footer. A code the camera sees links at once.

Under the code is the **Hop**, a pill with its state that opens the Hop control in a popover. The control is one component with one fixed size, the same in this popover and in the Hop's sheet: a header (state icon, Check, help), the choice (Imp's servers, Custom, Off) and the address row. The address row is always there, dimmed and locked unless Custom is chosen, so nothing grows, shifts or is clipped when the choice changes. Choosing Custom puts the cursor in it. The Hop is the relay devices use to meet when they are not on the same network. What it is and what it carries is behind its help icon. A new code is made whenever its routes change, including when the Hop is set or cleared.

## Accessibility and keyboard

- SwiftFlow's nodes carry no names of their own, so the canvas is replaced for assistive technology by a list: a spoken summary of the whole map, then a button for every device, every Imp and every line. Pressing one opens its sheet, as a click does.
- Each has a spoken label that says what it is and how it stands: a card its summary, a chip the Imp and the device it is in (and whether it is a visitor), a line the two devices, the route and the state, a dotted line the device it leads to, a tether the Imp, where it is and where it thinks.
- Nothing depends on colour alone: a line's dashes, a card's state mark and a sheet's status word say the same.
- The Zoom in, Zoom out and Show all buttons are labelled buttons, and Esc and Back leave for the Imps.
