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

Pressing something opens one sheet, with a header (picture and name), Cancel on the leading side and Done on the trailing side. Every sheet follows one order: the picture of the thing, its settings, its actions, and last what destroys. A sheet shows the settings of the thing pressed and never lists the nodes at the ends of a line: a device, an Imp and a line each have their own sheet. Cards and buttons fill the sheet's width, and a row of buttons shares it equally. Switches and plugs act at once; Done keeps them and Cancel puts them back as they were when the sheet opened (the Hop, the plugs and an Imp's tools; an Imp called home or a device forgotten stays so, those are actions). A chip inside a sheet that points at an Imp or a device swaps the sheet for that one. Forget, and Forget everyone, ask first; forgetting calls this Mac's Imps home from that device and sends its visitors home. A sheet about something that is gone (a forgotten device, an Imp that came home) closes.

The Hop is a setting, not a linked thing, so it has its own sheet (`DevicesSheet.hop`) that never depends on the Hop being in the map: it stays open while an address is being chosen. The Hop is on the canvas only when a line goes through it; This Mac's sheet has its entry.

| Pressed | The sheet shows | Actions |
| --- | --- | --- |
| This Mac | Reachable or not, the Local Network notice when the system blocks it, "Reachable at" its addresses, a Hop row (its state and host, or Add a Hop). | The Hop row opens the Hop's sheet. Link a device and Forget everyone, in one row of two equal buttons (the second only when anything is linked). |
| A linked device | How it stands and how it is reached. "On its screen": a chip for every Imp there (this Mac's, its own, its visitors). The plugs: what it can use here. Its last known addresses when it is not connected. | Plug or unplug. Open an Imp's sheet. Call home per Imp, and for all. Forget. |
| The Hop | How it stands, the Hop control (the same card as in the Link sheet), and chips for the devices reached through it. | Choose Imp's Hop, Custom or Off; type and Check an address. Open a device. |
| One of this Mac's Imps (its chip) | A picture: its body on one device, thinking on this Mac (one tile "Here" at home). When away, "Can use there": its tools as plugs, blocked ones dimmed with a lock. Its tools, folded. Whom it can message, as chips. | Press a blocked plug to open the connection where it is plugged in. Switch a tool group or tool server for this Imp. Open an Imp it talks to. Call home, when it is away. Open its settings. |
| An Imp of another device | A picture: where its body is and where it thinks. "Its device can use here": that device's plugs, read only. | Send home, when it is visiting this Mac. |
| A line (a connection) | A picture: the two devices joined in the colour of the line's state, with the route (Wi-Fi, or the Hop between them); its address in small type only when it is not up. "What the device can use here": the plugs. "Travelling": chips of the Imps going across it (this Mac's out, the device's own in). | Plug or unplug. Open an Imp. Call all home. Forget the device. |
| A tether | The sheet of its Imp. | As above. |

## Plugs

What a linked device may do with this Mac's Imps is shown as plugs and a socket strip, not as switches with names to learn: each capability is a plug (a picture and a short word), and when it is plugged into the device's socket the Imps here have that capability for that device. A plug that is in sits in the socket with a soft glow; one that is out rests above it with an outline. A tap plugs or unplugs it, and so does pulling it down into the socket or up out of it. The rows are even and full width, a short last row sharing its width (four plugs are two and two, never three and one). Each plug is a toggle for a screen reader, with its title and "plugged in" or "not plugged in". With Reduce Motion on, plugs fade instead of sliding.

The first plug is **Talk & files**: the device is trusted to talk to the Imps and to share files. Two rules combine (`DeviceAccess`):

1. **Talk & files.** A device without it gets no tools at all, whatever the other plugs say (`AskOrigin`). Plugging a tool plugs Talk & files too. Unplugging it keeps the tool plugs as they were, for when it is plugged back.
2. **Tool plugs.** A device with Talk & files gets the Imp's own tools less the groups that are not plugged for it: the tool groups an Imp of this Mac uses, the commands tool and every tool server that is on. Everything is plugged until it is unplugged.

A plug can only narrow: it never gives a tool to an Imp that does not have it. The limits are kept per device (`DeviceToolLimits`) and are removed when the device is forgotten. On the canvas a line's badge shows the route, then a plug and the capabilities plugged in (an outlined, dimmed plug when none is). See [Imp Link](/connecting/link).

## The Link sheet and the Hop

Link a device opens one sheet with two tabs, **Show code** and **Scan code** ([Imp Link](/connecting/link)). Show code is this Mac's code with the three steps for the other device, and Copy Link in the footer. Scan code is the camera, the link field and a status line, with Paste (a link or a picture of a code) and Link in the footer. A code the camera sees links at once.

Under the code is the **Hop**, a pill with its state that opens the Hop control in a popover. The control is one component with one fixed size, the same in this popover and in the Hop's sheet: a header (state icon, Check, help), the choice (Imp's Hop, Custom, Off) and the address row. The address row is always there, dimmed and locked unless Custom is chosen, so nothing grows, shifts or is clipped when the choice changes; choosing Custom puts the cursor in it. The Hop is the relay devices use to meet when they are not on the same network; what it is and what it carries is behind its help icon. A new code is made whenever its routes change, including when the Hop is set or cleared.

## Accessibility and keyboard

- SwiftFlow's nodes carry no names of their own, so the canvas is replaced for assistive technology by a list: a spoken summary of the whole map, then a button for every device, every Imp and every line. Pressing one opens its sheet, as a click does.
- Each has a spoken label that says what it is and how it stands: a card its summary, a chip the Imp and the device it is in (and whether it is a visitor), a line the two devices, the route and the state, a tether the Imp, where it is and where it thinks.
- Nothing depends on colour alone: a line's dashes, its tag and its state mark say the same.
- The zoom and Fit buttons are labelled buttons, and Esc and Back leave for the Imps.
