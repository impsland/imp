# Devices

The Devices screen is the one place that says where every Imp is and how the devices talk to each other. It is its own screen, not a section of Settings. It is on the Mac. The iPhone still has a Devices sheet and a Devices section in its settings ([Parity](/ux/parity)).

## Where it opens

- The **Devices** corner button of the [main screen](/ux/main-screen): bottom left on macOS, bottom right where the window buttons are top right. It wears a small green dot while a linked device is connected, and a warning mark while a linked device cannot be reached.
- A link to a Devices setting (`imp://settings?setting=devices_hop`, a tool that points at it, an attention item) opens this screen and lights the setting.

## The layout

A canvas fills the window under a top bar. The top bar has Back, the title and one Link a device button (the QR icon). While nothing is linked, the same action also floats at the bottom of the canvas as a button, so the first step is never hidden. Pressing a device, an Imp or a line opens a sheet about it; pressing empty canvas does nothing. Back (and Esc) leaves for the Imps.

## The map

The map is a canvas drawn with [SwiftFlow](https://github.com/aaurelions/SwiftFlow) (MIT, see `THIRD_PARTY_NOTICES.md`) in the app's own look: the window's surface, quiet dots, muted lines. `DeviceGraph` turns the live `DeviceMap` into the canvas's nodes and lines, so what is drawn is always the current state.

- **Devices are cards.** This Mac, every linked Mac or iPhone, and the Hop, which is always there, set or not. Each has its icon, its name, and a state mark (connected, away, offline). The Hop's mark says off (none set), needs an address, connected (a channel runs through it) or not in use. This Mac is on the leading side, the Hop in the middle and the linked devices on the trailing side, one under the other. With local channels the Hop sits below the rest, out of their way.
- **Imps are chips inside the device their body is on**, in a grid of at most three across. An Imp of this Mac is a strong chip, an Imp of another device is a visitor and is lighter.
- **Channel lines join the devices.** A line is solid when the devices talk on the local network and dashed when they go through the Hop (one line to the Hop and one from it). Its tag is Wi-Fi, or the Hop's address. A line that is not connected is faded.
- **Tethers** are thin lines in the Imp's own colour, from an Imp's chip to the device where it thinks and runs its tools (its home). An Imp's body can be somewhere else; its mind is always at home ([Imp Link](/connecting/link)).
- Nothing on the canvas can be selected, connected or deleted, so SwiftFlow's own keys (Delete, undo) never change the map.

### Moving around

- **Pan** by dragging empty canvas, or with two fingers or the scroll wheel. Scrolling pans; it does not zoom.
- **Zoom** with the pinch gesture or the **+** and **-** buttons.
- **Drag a device** to move it. It stays where it was put while the app runs; a refresh of the link never puts it back. Imps cannot be dragged out of their device.
- **The controls** sit at the bottom leading corner: zoom in, zoom out, and Fit, which shows the whole map again.

### How it fits on open

The first view is worked out from the devices' own sizes and places (`DeviceViewport`), not from the canvas measuring them, so it is the same every time: the whole map, centred, with a margin (the `vast` spacing token) on every side. The zoom is held between 0.2 and 1.2, so a small map is not blown up and a huge one is not shrunk to nothing.

It is fitted again when the window changes size, when a device or an Imp comes or goes, and when Fit is pressed. Once you pan or zoom, the view is yours: a window resize or a refresh of the link no longer moves it, until you press Fit or the set of devices and Imps changes.

## The sheets

Pressing something opens one sheet, with a header (picture and name), Cancel on the leading side and Done on the trailing side. Every sheet follows one order: the status line, the main actions, the details and switches, and last what destroys. Rows lead with a picture; there are no sentences, and what needs explaining sits behind a help icon. Switches act at once; Done keeps them and Cancel puts them back as they were when the sheet opened (the Hop, Mine, the tool limits and an Imp's tools; an Imp called home or a device forgotten stays so, those are actions). A button inside a sheet that points at another device or Imp swaps the sheet for that one. Forget, and Forget everyone, ask first; forgetting calls this Mac's Imps home from that device and sends its visitors home. A sheet about something that is gone (a forgotten device, an Imp that came home) closes.

The Hop is a setting, not a linked thing, so it has its own sheet (`DevicesSheet.hop`) that never depends on the Hop being in the map: it stays open while an address is being chosen.

| Pressed | The sheet shows | Actions |
| --- | --- | --- |
| This Mac | Reachable or not, the Local Network notice when the system blocks it, its addresses. | Link a device. Forget everyone, when anything is linked. |
| A linked device | How it stands and how it is reached. **Mine** (a switch row). The tool limits, a row of the tools that are on that opens into switches. The Imps of this Mac it holds. Its last known addresses when it is not connected. | Mine switch. A switch per tool group. Call home per Imp, and for all. Forget. |
| The Hop | How it stands, the Hop control (the same card as in the Link sheet), and the devices reached through it. | Choose Imp's Hop, Custom or Off; type and Check an address. Jump to a device. |
| One of this Mac's Imps | Where its body is. Its tools, a row of pictures that opens into switches. Whom it can message. | Call home and a jump to the device, when it is away. Open its settings. Switch a tool group or tool server for this Imp. Jump to an Imp it talks to. |
| An Imp of another device | Where its body is and where it thinks, each a row that opens that device. | Send home, when it is visiting this Mac. |
| A channel line | How it stands and how it goes. A row for each end and for the Hop it passes through. | Forget the device. |
| A tether | Where its body is and where it thinks, and the tools it may use where it is (or a lock row when the device is not Mine). | Call home. |

## Tool limits

An Imp of this Mac that a linked device holds answers that device's asks here, with this Mac's tools. Two rules combine:

1. **Mine.** A device that is not marked Mine gets no tools at all, whatever is set below (`AskOrigin`). The linked device's sheet says so instead of listing switches.
2. **Tool limits.** A device that is Mine gets the Imp's own tools, less the groups switched off for that device. The switches list the tool groups an Imp of this Mac uses, the commands tool and every tool server that is on. Nothing is off until it is switched off.

A limit can only narrow. It never gives a tool to an Imp that does not have it. The limits are kept per device (`DeviceToolLimits`) and are removed when the device is forgotten. See [Imp Link](/connecting/link).

## The Link sheet and the Hop

Link a device opens one sheet with two tabs, **Show code** and **Scan code** ([Imp Link](/connecting/link)). Show code is this Mac's code with the three steps for the other device, and Copy Link in the footer. Scan code is the camera, the link field and a status line, with Paste (a link or a picture of a code) and Link in the footer. A code the camera sees links at once.

Under the code is the **Hop**, a pill with its state that opens the Hop control in a popover. The control is one component with one fixed size, the same in this popover and in the Hop's sheet: a header (state icon, Check, help), the choice (Imp's Hop, Custom, Off) and the address row. The address row is always there, dimmed and locked unless Custom is chosen, so nothing grows, shifts or is clipped when the choice changes; choosing Custom puts the cursor in it. The Hop is the relay devices use to meet when they are not on the same network; what it is and what it carries is behind its help icon. A new code is made whenever its routes change, including when the Hop is set or cleared.

## Accessibility and keyboard

- SwiftFlow's nodes carry no names of their own, so the canvas is replaced for assistive technology by a list: a spoken summary of the whole map, then a button for every device, every Imp and every line. Pressing one opens its sheet, as a click does.
- Each has a spoken label that says what it is and how it stands: a card its summary, a chip the Imp and the device it is in (and whether it is a visitor), a line the two devices, the route and the state, a tether the Imp, where it is and where it thinks.
- Nothing depends on colour alone: a line's dashes, its tag and its state mark say the same.
- The zoom and Fit buttons are labelled buttons, and Esc and Back leave for the Imps.
