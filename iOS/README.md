# Imp for iPhone

The phone's side of Imp. Imps you toss off the side of your Mac's screen land here: you can drag them
around with a finger, tap one to chat, shake the phone to make them dizzy, and throw them back to the
Mac. The Mac keeps each Imp's brain (models, keys, tools, chats); the phone is its **body and chat**.
An Imp is never on both devices at once.

The Imps are drawn by the Mac's own renderer: `project.yml` compiles `Sources/Imp/Character/*` straight
into the app, and the wire protocol (`Sources/ImpKit/Link/`) is shared with the Mac, so the two can't drift.

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

Debug builds understand `-demo` (two Imps and a chat, no network), `-demoVoice <url>` (one of them answers out loud), `-openChat` and `-hatch`, handy for screenshots,
and `-pair <implink://…>` with `-ask <text>` for end-to-end checks against a running Mac.
`scripts/make-icon.sh` re-renders the app icon from the Mac app's own icon art (`Imp --render-ios-icon`).

## Pairing and tossing

1. On the Mac: Imp's window › All Imps › App › iPhone › **Pair…**. It shows a QR code.
2. Scan it with the Camera app (it opens Imp through the `implink://` link) or with **Scan Code** in the
   app. **Paste Link** works too.
3. Toss an Imp off the side of the Mac's screen. It flies in from the matching side of the phone.
   Flick one off the left or right edge of the phone (or throw the phone sideways, or use the long-press
   menu › Send to Mac) and it flies onto the Mac, continuing the way it went. If the Mac can't take it,
   it bounces back with the reason.

## Imps hatched on the phone

The status pill's menu (or **Or hatch an Imp on this iPhone** on the first screen) hatches a pocket Imp:
a name, a colour, a personality, an OpenAI-compatible service and optional HTTP tool servers. It thinks on
the phone (`PocketRuntime`, built on ImpKit's `PocketBrain`), with or without a Mac. Its chats and settings
are one JSON file in Application Support (`PocketStore`). Keys and header values are only in the Keychain
(`PocketKeychain`) and the form only says "Saved" afterwards. Throw one off a side while the Mac is
connected and it moves home for good.

## Security

The QR code carries a random 256-bit secret. It is stored in the Keychain and **never sent over the
network**: both sides derive a TLS pre-shared key from it (HMAC-SHA256), so only a phone that scanned the
code can connect, and everything after is encrypted (TLS 1.2 PSK, AES-128-GCM). Unpairing on either side
discards the secret.

## Reaching the Mac

The phone finds the Mac with Bonjour (`_imp-link._tcp`) and also tries the host names in the pairing link
on port 47824, so a manual host or a VPN such as Tailscale already works. The link only runs while the app
is in front. Later, the same frames can travel over the internet through a relay; nothing in the app
depends on the transport being local.
