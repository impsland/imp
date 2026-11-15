# Platforms

The screens, states, words and behavior are the same everywhere. The look and the controls are native to each platform. Views are written by hand with each platform's own tools. Only tokens, component specs (`design/components.json`) and strings are generated, for every platform, into `design/generated/<platform>`. See [Design](/design/#building-a-new-platform) for how a new platform uses them and the Rust core.

| Platform | UI toolkit | Status |
| --- | --- | --- |
| macOS | SwiftUI, with AppKit for windows and panels | Built |
| iPhone | SwiftUI | Built |
| Android | Jetpack Compose | Planned |
| Windows | WinUI 3 | Planned |
| Linux | GTK 4 with libadwaita | Planned |

The browser extension and the CLI are companions. The extension uses the same colors and type through `extension/tokens.css`. See [Parity](/ux/parity).

## Window chrome

| Platform | Main window |
| --- | --- |
| macOS | Full-size content, transparent title bar, no title text. Close, minimize and full screen stay. A strip 28 points tall along the top drags the window (`dragStripPoints`). |
| iPhone | Full screen under the system bars. |
| Android | Edge to edge, transparent system bars, the more button in the top corner. |
| Windows | Content extends into the title bar, Mica material, system caption buttons. The more button sits left of them. |
| Linux | Flat, transparent libadwaita header bar over the canvas, the desktop's own button layout. The more button is in the header bar's end. |

## The more button and menus

The more button is in the top trailing corner on every platform. It opens the canvas menu. A right click on empty space opens the same menu. On a phone, touch and hold on empty space opens it.

Menus use the platform's own style: `NSMenu` on macOS, a popup menu on iPhone and Android, a flyout on Windows, a popover menu on Linux. The items and the words are the same.

## Shortcuts

| Action | macOS | Windows and Linux | iPhone and Android |
| --- | --- | --- | --- |
| New Imp | Command-N | Control-N | Menu item |
| Settings | Command-comma | Control-comma | Menu item |
| Close panel or menu | Esc | Esc | Back |
| Open the canvas menu | Menu key or Control-click | Menu key or Shift-F10 | Touch and hold |
| Talk to the focused Imp | Return | Return | Tap |
| Imp Settings for the focused Imp | Command-I | Control-I | Double tap |

## Status icon

| Platform | Status icon |
| --- | --- |
| macOS | A menu bar item. Its menu has `home.tray.show`, New Imp, Settings and `home.tray.quit`. |
| Windows | A notification area icon with the same menu. |
| Linux | A status notifier icon, where the desktop shows one. The app does not depend on it, because some desktops do not show any. |
| iPhone and Android | None. |

## Letting an Imp out

| Platform | Free Imps |
| --- | --- |
| macOS | Yes, a borderless panel. |
| Windows | Yes, a borderless topmost layered window. |
| Linux, X11 | Yes. |
| Linux, Wayland | No. Imps stay in the window and the menu explains why (`imp.let_out.unavailable`). |
| iPhone | No. Imps stay in the app. |
| Android | No. Imps stay in the app. |

## Touch and pointer

- Pointer platforms use click, double click and right click. Touch platforms use tap, double tap and touch and hold.
- Hover effects are only for pointers. Nothing needs hover to be understood.
- Hit areas follow the table on [Accessibility](/ux/accessibility).

## Imp Settings

The sections of the app Settings are a rail on both platforms: vertical beside the content on a desktop window, a horizontal bar above it on the phone. Light and dark appearance follow the system on both.

The panel of a marker is a side panel on a desktop window wide enough to hold it. Below `narrowWindowPoints` and on phones it is a sheet. The plain list replaces the markers on narrow windows, at accessibility text sizes and with a screen reader.

## Language and text

Words come from the generated strings of each platform (see [UX specification](/ux/)). English, Spanish and Simplified Chinese are shipped. A platform that has no translation for a key falls back to English and never shows the key.

## Platform notes

- **macOS.** Liquid Glass is used on versions that have it, behind availability checks. The app needs macOS 15 or newer.
- **iPhone.** Imps stay in the app. The app needs iOS 18 or newer. Dynamic Type is used.
- **Android.** Planned. Material 3 motion is not used. The Imp motion presets are used.
- **Windows.** Planned. WinUI 3 with the generated resource dictionary.
- **Linux.** Planned. GTK 4 with libadwaita. The generated CSS sets the libadwaita named colors.
