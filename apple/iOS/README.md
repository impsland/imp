# Imp for iPhone

The phone's side of Imp, built on Imp Link (`docs/connecting/link.md`). An iPhone links with Macs and other
iPhones: any device can show an invite code and any can scan it, and one device can have many links.
Imps you toss off the side of a screen land on another: drag them around with a finger, tap one to
chat, shake the phone to make them dizzy, and throw them on. An Imp keeps thinking at its **home**,
the device it was hatched on (models, keys, tools, chats). A phone holds its **body and chat**. An Imp
is never on two devices at once.

## Build

The requirement is iOS 18 or later (`apple/iOS/project.yml`, `deploymentTarget`). Run the commands from
the repository root.

| Goal | Command |
|------|---------|
| Open in Xcode | `cd apple/iOS && xcodegen generate && open ImpPhone.xcodeproj` |
| Simulator build | `make ios` |
| Snapshot tests, build only | `make ios-snapshots-build` |
| Install on your iPhone | `make ios-device` |

`xcodegen generate` is only needed after changing `project.yml`, because `ImpPhone.xcodeproj` is committed.

Simulator build without the Makefile:

```sh
xcodebuild -project apple/iOS/ImpPhone.xcodeproj -scheme ImpPhone -destination 'generic/platform=iOS Simulator' \
    -derivedDataPath .build/ios CODE_SIGNING_ALLOWED=NO build
```

To run on a device from Xcode, select the `ImpPhone` target, open Signing & Capabilities and choose your
team. The project ships with an empty `DEVELOPMENT_TEAM`.

`make ios-device` signs with the team signed in to Xcode (or `TEAM=<Team ID>`), installs on the one connected
iPhone (or `DEVICE=<name or UDID>`) and opens it. It works over a cable, or over Wi-Fi once Xcode has paired
the phone. `CONFIG=Debug` sends a debug build.

Debug builds understand `-openChat` and `-hatch`, handy for screenshots, and `-join <implink://…>` with
`-ask <text>` for end-to-end checks against a running Mac (`apple/iOS/Imp/App/ImpPhoneApp.swift`).
`apple/iOS/scripts/make-icon.sh` re-renders the app icon from the Mac app's own icon art (`Imp --render-ios-icon`).

## Linking and tossing

1. On one device, show a code: **Show my code** on the phone's first screen (or its **Devices** sheet, from
   the status pill), or the Devices card in the Mac's settings.
2. On the other, scan it with the Camera app (it opens Imp through the `implink://` link) or with
   **Scan a Code** in the app. **Paste Link** works too. Either side can be the one that shows the code.
3. Toss an Imp off the side of a screen. It flies in from the matching side of the other one. With
   several links, each side is split into **doors**, one band per device, and the height of the throw
   picks one. While an Imp is carried near an edge, `DoorLabels` names the bands, the one under the finger
   lights up with a tick, a visiting Imp's way back is marked "back to" its device, and a side that leads
   nowhere says so. The labels stay away during a game, respect Reduce Motion, and the long-press menu's
   **Send to** items do the same job for VoiceOver. If the target can't take the Imp, it bounces
   back with the reason.

## Visiting Imps

An Imp away from its home keeps thinking there. While its home is out of reach it sleeps, and its
chat says so and waits. A visiting Imp's menu has Hide and Send Home. The **Devices** sheet
(`DevicesSheet`) shows, per linked device, whether it is connected, reached through the server, or away,
and which of this phone's Imps it holds, with **Call Home**. A visiting Imp can be passed on to a third
device with its **ticket**, which lets that device act for the Imp at its home.

## Imps hatched on the phone

The status pill's menu (or **Hatch an Imp** on the first screen) hatches a pocket Imp:
a name, a colour, a personality, an OpenAI-compatible service and optional HTTP tool servers. It thinks on
the phone (`PocketRuntime`, built on ImpKit's `PocketBrain`), with or without a Mac linked. Its chats and settings
are one JSON file in Application Support (`PocketStore`). Keys and header values are only in the Keychain
(`PocketKeychain`) and the form only says "Saved" afterwards. Throw one off a side while the Mac is
connected and it moves home for good.

## Security

Each device has an Ed25519 key that never leaves it (in the Keychain). A link pins the other side's
public key, taken from the code itself. The code also carries a random 256-bit door key, which is
**never sent over the network**: both sides derive a TLS pre-shared key from it (HMAC-SHA256), and the
connection uses `TLS_ECDHE_PSK_WITH_CHACHA20_POLY1305_SHA256`, so only a device that scanned the code can
connect, and an ephemeral key exchange keeps recorded sessions unreadable even to another invited device.
Each side then signs a proof tied to that one connection, so it can't be relayed. A stranger can only
visit with a ticket and is dropped after 15 seconds without one. Forgetting everyone makes a new door key,
so every old code stops working.

## Reaching other devices

A device finds the others with Bonjour (`_imp-link._tcp`) and also tries the host names in the code or
the latest routes on port 47824, so a manual host or a VPN such as Tailscale already works. With an Imp
server set (the Devices sheet's **Server** field), it also waits at the server's Hop, a blind relay of
encrypted bytes, so devices reach each other from anywhere. The server can't read anything. The link
only runs while the app is in front. Nothing in the app depends on the transport being local.

## The look: Pebble

The phone shares the Mac's design language (`apple/Sources/ImpDesign`, tokens in `design/tokens.json`).
One flat surface (`Tone.surface`) under every screen and every sheet (`.presentationBackground(Tone.surface)`).
Groups are soft fills (`Tone.card`) with big continuous corners: no outlines, no dividers, no gradients, no
shadows on chrome. Chrome is monochrome (`Tone.accent`), and the colour belongs to the Imp (`impTint`). Text on a
fill uses `Tone.onAccent` or `OnTint`. `Tone.paper` is only for text over the stage, the camera or a scrim.
Only a bubble that floats over the stage casts a shadow. The games keep their warm colours through the
`Tone.spark*` tokens. Icons sit in `IconTile` beads or `HoverIconButton`, never edge to edge.

Settings mirror the Mac. The pages of the Devices sheet are the `SettingsGroup`s the phone has (Brains,
Devices, Animations, Talking, App). An Imp's own pages are the `ImpSetting`s it has (Brain, Personality, Look,
Tools), with the same titles, icons and help keys as the Mac. Every setting is a `Row` or a field with an icon
and an `InfoTip`. Controls adapt to a narrow screen and the largest Dynamic Type size by themselves.

## Energy

Everything that animates goes through `Imp/App/Energy.swift` and `FramePolicy`: a frame is drawn only while
something moves, at the rate the policy allows. Animation pauses when the app is not active, when the screen is
covered by a sheet or the chat, when nothing is moving, in Low Power Mode (slower) and under Reduce Motion (still).

A room at rest is what an open phone shows most of the time, so it costs next to nothing. The stage draws no
frames. Each Imp draws its own blinks (`BlinkTimeline`), its breath and float are a transform on the finished
picture (`RestMotion`), and a picture that did not change is not drawn again (`ImpPicture`). After a minute with
nothing happening the room settles: the Imps stop floating and only blink, until something happens.

`PhoneEnergyAuditTests` fails on any `TimelineView(` or `repeatForever` outside `Energy.swift`, and on
`CADisplayLink` or a repeating `Timer` anywhere. Do not add continuous animation.
