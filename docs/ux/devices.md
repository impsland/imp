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
- **Every Imp has its own line.** An Imp that is away from its home has a thin line in its own colour. It leaves the device its body is on at a port of that Imp alone, level with its chip, and arrives at a port of the same Imp at its home, never in the middle of a card. A dot of the Imp's colour marks each end. The ports on one side keep the order of the chips, at both ends, and keep apart, so the lines run side by side and do not cross. They are hidden and appear while the Imp, its line or one of the two devices is hovered or open. Then the Imp's path is lit, with its channel and its talk lines, and the rest of the map is dimmed. **A talk line** is thin and dashed, in the colour of the Imp that can message. It is drawn above the devices and runs from that Imp's chip to the chip of the Imp it reaches, never to the edge of a card. A dot of the Imp's colour marks each end. Where several lines leave or arrive at one chip, each has its own port on the chip's side, in the order of the chips at their other ends, so they fan out and do not cross. If another chip is in the way on the facing side, the line uses the top or bottom of the chip. An Imp that is away also wears a tiny house and the symbol of its home device on its chip, so where it lives is seen without a line. An Imp's body can be somewhere else. Its mind is always at home ([Imp Link](/connecting/link)).
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

Pressing something opens one compact sheet, the same for every kind. The header holds the picture, the name, one status pill (a coloured dot and one or two words: Here, Nearby, Via server, Away, Through the device that relays it, Visiting) and the actions as icon buttons, each with a tooltip and a spoken label: Link, Send home, Settings, Forget (in red). The page is chips that wrap and fill the width, then at most one card of switches. No row holds only one small button and there are no paragraphs: what a chip means is its tooltip and spoken hint. A chip that points at another thing (a device, an Imp, the line, the Hop) swaps the sheet for that one. Cancel is on the leading side and Done on the trailing side. Switches act at once. Done keeps them and Cancel puts them back as they were when the sheet opened (the Hop, Mine, the tools and an Imp's tools). An Imp sent home or a device forgotten stays so, because those are actions. Forget and Forget everyone ask first. Forgetting calls this Mac's Imps home from that device and sends its visitors home. A sheet about something that is gone (a forgotten device, an Imp that came home) closes.

The Hop is a setting, not a linked thing, so it has its own sheet (`DevicesSheet.hop`) that never depends on the Hop being in the map: it stays open while an address is being chosen. Its button is in the bar, and the sheet of a dashed line has it as a chip.

| Pressed | Chips and cards | Header actions |
| --- | --- | --- |
| This Mac | Its addresses (or Not reachable) and its Imps, in one flow. The Local Network notice when the system blocks it. | Link a device. Forget everyone (only when anything is linked). |
| A linked device | Its connection (opens the line's sheet), its Imps (each with a way home), then the Mine card: the switch is in the card's header and, while it is on, the tools. | Send all home (when more than one is there). Forget. |
| A device known only through another | Its Imps. The pill says Through the device that relays it. | Link, which opens the Link sheet. |
| The Hop | The Hop control (the same card as in the Link sheet), and the devices reached through it. | None in the header. Choose Imp's servers, Custom or Off, type and Check an address. |
| One of this Mac's Imps (its chip) | Where it is when away and its home (each opens that device), the Imps it can message, then the Tools card. | Send home (when it is away). Settings. |
| An Imp of another device | Its home (opens it). The pill says where it is (Visiting, or its device). | Send home, when it is visiting this Mac. |
| A line (a connection) | Its two ends (each opens its sheet) and its path: the address, or the Hop when the line is dashed. | None. |
| An Imp's line | The sheet of its Imp. | As above. |

## Tools

Mine and an Imp's own tools are one control, the tool grid. Tools are grouped by kind, Built in first and then Servers (tool servers that were added). Each group has a header with its icon, its name and how many of its tools are on (`3/5`), and one icon button that switches the whole group on or off (when it has more than one tool). Under the header the tools are chips with a picture and a name that flow across the width: lit in the app's tint while on, quiet while off. Pressing a chip switches that tool. Each chip is a toggle for a screen reader, with its name and On or Off.

What a linked device may do with this Mac's Imps is two rules (`DeviceAccess`):

1. **Mine.** A device that is not Mine gets no tools at all, whatever the chips say (`AskOrigin`). Switching a tool on makes it Mine too. Switching Mine off keeps the tool chips as they were, for when it is switched back.
2. **Tools.** A Mine device gets the Imp's own tools less the ones switched off for it: the tool groups an Imp of this Mac uses, the commands tool and every tool server that is on. Everything is on until it is switched off.

A switch can only narrow: it never gives a tool to an Imp that does not have it. The limits are kept per device (`DeviceToolLimits`) and are removed when the device is forgotten. On the canvas a line's badge shows the route. See [Imp Link](/connecting/link).

## The Link sheet and the Hop

Link a device opens one sheet with two tabs, **Show code** and **Scan code** ([Imp Link](/connecting/link)). Show code is this Mac's code with the three steps for the other device, and Copy link in the footer. Scan code is the camera, the link field and a status line, with Paste (a link or a picture of a code) and Link in the footer. A code the camera sees links at once.

Under the code is the **Hop**, a pill with its state that opens the Hop control in a popover. The control is one component with one fixed size, the same in this popover and in the Hop's sheet: a header (state icon, Check, help), the choice (Imp's servers, Custom, Off) and the address row. The address row is always there, dimmed and locked unless Custom is chosen, so nothing grows, shifts or is clipped when the choice changes. Choosing Custom puts the cursor in it. The Hop is the relay devices use to meet when they are not on the same network. What it is and what it carries is behind its help icon. A new code is made whenever its routes change, including when the Hop is set or cleared.

## Accessibility and keyboard

- SwiftFlow's nodes carry no names of their own, so the canvas is replaced for assistive technology by a list: a spoken summary of the whole map, then a button for every device, every Imp and every line. Pressing one opens its sheet, as a click does.
- Each has a spoken label that says what it is and how it stands: a card its summary, a chip the Imp and the device it is in (and whether it is a visitor), a line the two devices, the route and the state, a dotted line the device it leads to, an Imp's line the Imp, where it is and where it thinks.
- Nothing depends on colour alone: a line's dashes, a card's state mark and a sheet's status word say the same.
- The Zoom in, Zoom out and Show all buttons are labelled buttons, and Esc and Back leave for the Imps.
