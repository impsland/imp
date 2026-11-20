# Parity

Which screens and states exist on which platform. Keep this table current.

- **Built** means it exists and matches the specification.
- **Earlier** means it exists in an earlier form and is rebuilt from this specification.
- **To build** means it is specified here and not built yet on that Apple platform.
- **Planned** means the platform has no app yet.
- A dash means the platform does not have it by design.

## Screens

| Screen | macOS | iPhone | Android | Windows | Linux |
| --- | --- | --- | --- | --- | --- |
| [Main screen](/ux/main-screen) (canvas, more button, menus) | Earlier | Earlier | Planned | Planned | Planned |
| One flat surface, light and dark (Pebble) | To build | To build | Planned | Planned | Planned |
| [Imp](/ux/imps) (drag, click, double click, phone icon) | Earlier | Earlier | Planned | Planned | Planned |
| Let out and Send home | Earlier | - | - | Planned | Planned (X11 only) |
| Peek of hidden Imps | To build | To build | Planned | Planned | Planned |
| Undo bar | Earlier | Earlier | Planned | Planned | Planned |
| [Imp Settings](/ux/imp-settings) (Imp in the middle) | Earlier | To build | Planned | Planned | Planned |
| [All Imps settings](/ux/all-imps-settings) | To build | To build | Planned | Planned | Planned |
| [Devices screen](/ux/devices) (map, inspector, Link sheet) | Built | Earlier | Planned | Planned | Planned |
| [First run](/ux/first-run) | To build | To build | Planned | Planned | Planned |
| Status icon | Earlier | - | - | Planned | Planned |

## States

| State | macOS | iPhone | Android | Windows | Linux |
| --- | --- | --- | --- | --- | --- |
| Empty canvas | Earlier | To build | Planned | Planned | Planned |
| Sleeping Imp | Earlier | Earlier | Planned | Planned | Planned |
| Waking Imp | Earlier | Earlier | Planned | Planned | Planned |
| Offline | Earlier | Earlier | Planned | Planned | Planned |
| Only the Hop set up | To build | To build | Planned | Planned | Planned |
| No servers set up | To build | To build | Planned | Planned | Planned |
| Error sentences | Earlier | Earlier | Planned | Planned | Planned |
| Reduce Motion | Earlier | Earlier | Planned | Planned | Planned |
| Screen reader | Earlier | Earlier | Planned | Planned | Planned |

## Behavior and design sources

| Thing | macOS | iPhone | Android | Windows | Linux | Browser extension |
| --- | --- | --- | --- | --- | --- | --- |
| Tokens generated from `design/tokens.json` | Built | Built | Planned | Planned | Planned | Built |
| Strings generated from `design/strings` | Built | Built | Planned | Planned | Planned | Built |
| Shared behavior vectors | Earlier | Earlier | Planned | Planned | Planned | - |

## Not on the phone yet

What the Mac has from this specification and the iPhone does not, to build:

- **Scope of triggers and animations.** The phone's Imps keep their own triggers and have no shared set, so there is nothing to label or override. The Mac's model (`SettingScope`, `ImpPreferences.saveTrigger`) is shared code the phone can adopt.
- **The server card.** The phone's Devices section still shows The Hop with its own menu and Check (`PhoneServerCards`), not the Mac's `ServerCard` layout. The choices and the check work the same.
- **Link a device as one sheet.** Done on the first screen (its own sheet with the same cards). The Mac has no Devices section in Settings any more (it is the Devices screen). In Settings the phone still shows the code, Scan and Paste as cards of its Devices section.
- **Field actions.** The phone's fields do not use `FieldWell` yet. None of its fields has a button beside it.

The first run uses the same model (`FirstRunModel`) and words, with Remote and Local, on both. The phone shows it on one screen, without step numbers.

## The phone leaves out

- **Animations.** There are no built-in animations. Animations are made and assigned on the Mac (or added from a kit), and nothing on the page changed what a phone user sees. Removed. Reactions have no on/off setting on the phone.
- **Tools** (MCP) in the app's settings. Tools run on a computer. The phone's Imps use the tools of a trusted linked device through the "Mine" switch on that device. A pocket Imp's MCP servers are in its Tools, and its one built-in tool (Message Imps) is behind the wand in its Personality, as on the Mac. Talking between Imps: the phone has no Between-Imps settings. Whether a message waits for the answer is always up to the Imp (`wait`, the Mac's Decides), and a pocket Imp's Description is in its Personality, in one block with its name.
- **Sharing** (The Den). Sharing, finding and taking animations happen on the Mac. A pocket Imp has no gallery tools.
- The bubble's Background (Solid or Translucent) is the Mac's: it blurs the desktop behind the bubble's own panel, and the phone's bubble sits over the app's stage.
- The Window setting (the smallest window) is the Mac's: the phone's app fills the screen.
- Permissions, Bubble and Backup are the Mac's. The phone asks for each permission when it needs it.
