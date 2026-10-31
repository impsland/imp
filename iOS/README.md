# Imp for iPhone

The phone's side of Imp, built on Imp Link 2 (`docs/LINK.md`). An iPhone links with Macs and other
iPhones: any device can show an invite code and any can scan it, and one device can have many links.
Imps you toss off the side of a screen land on another: drag them around with a finger, tap one to
chat, shake the phone to make them dizzy, and throw them on. An Imp keeps thinking at its **home**,
the device it was hatched on (models, keys, tools, chats); a phone holds its **body and chat**. An Imp
is never on two devices at once.

## Build

```sh
cd iOS
xcodegen generate
open ImpPhone.xcodeproj
```

To run on a device, select the `ImpPhone` target › Signing & Capabilities and choose your team (the
project ships with an empty `DEVELOPMENT_TEAM`). iOS 17 or later. Simulator build from the command line:

```sh
xcodebuild -project iOS/ImpPhone.xcodeproj -scheme ImpPhone -destination 'generic/platform=iOS Simulator' \
    -derivedDataPath .build/ios CODE_SIGNING_ALLOWED=NO build
```

To send it to your iPhone in one go (connected by cable, or over Wi-Fi once set up in Xcode), run
`make ios-device` from the repository root: it signs with the team signed in to Xcode (or
`TEAM=<Team ID>`), installs on the one connected iPhone (or `DEVICE=<name or UDID>`) and opens it.
`CONFIG=Debug` sends a debug build.

Debug builds understand `-demo` (two Imps and a chat, no network), `-demoVoice <url>` (one of them answers out loud), `-openChat` and `-hatch`, handy for screenshots,
and `-join <implink://…>` with `-ask <text>` for end-to-end checks against a running Mac.
`scripts/make-icon.sh` re-renders the app icon from the Mac app's own icon art (`Imp --render-ios-icon`).

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

Visits: an Imp away from its home keeps thinking there. While its home is out of reach it sleeps, and its
chat says so and waits. A visiting Imp's menu has Chat, Talks and Send Home. The **Devices** sheet
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

Each device has an Ed25519 key that never leaves it (in the Keychain); a link pins the other side's
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
encrypted bytes, so devices reach each other from anywhere; the server can't read anything. The link
only runs while the app is in front. Nothing in the app depends on the transport being local.
