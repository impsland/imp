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
| [Imp Settings](/ux/imp-settings) (Imp in the middle) | To build | To build | Planned | Planned | Planned |
| [All Imps settings](/ux/all-imps-settings) | To build | To build | Planned | Planned | Planned |
| [First run](/ux/first-run) | To build | To build | Planned | Planned | Planned |
| Status icon | Earlier | - | - | Planned | Planned |

## States

| State | macOS | iPhone | Android | Windows | Linux |
| --- | --- | --- | --- | --- | --- |
| Empty canvas | To build | To build | Planned | Planned | Planned |
| Sleeping Imp | Earlier | Earlier | Planned | Planned | Planned |
| Waking Imp | Earlier | Earlier | Planned | Planned | Planned |
| Offline | Earlier | Earlier | Planned | Planned | Planned |
| Only the Den set up | To build | To build | Planned | Planned | Planned |
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
- **The server card.** The phone's Devices and Sharing sections still show The Hop and The Den with their own menu and Check (`PhoneServerCards`), not the Mac's `ServerCard` layout. The choices and the check work the same.
- **Link a device as one sheet.** Done on the first screen (its own sheet with the same cards). In Settings the phone still shows the code, Scan and Paste as cards of its Devices section.
- **Field actions.** The phone's fields do not use `FieldWell` yet. None of its fields has a button beside it.

The first run and its two steps, Remote and Local, are the same on both.

## The phone leaves out

- **Animations.** The phone page only listed the five built-in animations. They are made, assigned and found in The Den on the Mac, and nothing on the page changed what a phone user sees. Removed. Reactions have no on/off setting on the phone.
- **Tools** (MCP). Tools run on a computer. The phone never had a page for them, and its Imps use the tools of a trusted linked device through the "Mine" switch on that device.
- The bubble's Background (Solid or Translucent) is the Mac's: it blurs the desktop behind the bubble's own panel, and the phone's bubble sits over the app's stage.
- The Window setting (the smallest window) is the Mac's: the phone's app fills the screen.
- Permissions, Bubble and Backup are the Mac's. The phone asks for each permission when it needs it.
