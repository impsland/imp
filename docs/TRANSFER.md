# Transfer by shaking

Stand next to a linked device, shake the iPhone, and the Imp you were last playing with flies off the
screen and lands on the other device. The rules live in `Sources/ImpKit/Link/ShakeTransfer.swift`
(pure, tested in `Tests/ImpKitTests/ShakeTransferTests.swift`). The iPhone side is `iOS/Imp/PhoneStage.swift`
(`shaken(from:)`) and `iOS/Imp/ShakeSend.swift`.

## What already existed, and what this reuses

- A sideways throw of an Imp off the screen edge (`Toss`, `StageEngine.toss`) and a sideways jolt of the
  whole phone (`JoltDetector.thrown`) already send the focused Imp through a "door" to a device.
- The menu send ("Send to <device>" on the iPhone, "Send <Imp> to <device>…" on the Mac) already uses
  `LinkNode.pass`, which is a visit: the Imp stays that device's own and a visitor lives on the other.
- A shake used to make the Imps dizzy. It still does when there is nothing to send or nowhere to send it.
- Shake detection is the `JoltDetector` on the shared `TiltSource`. There is still one motion manager.

## The interaction

1. A deliberate shake (four pushes back and forth, each over the sensitivity threshold) is spotted.
2. `ShakeTransfer.decide` picks the Imp and the device (below).
3. `send`: the Imp drifts off the side the shake started toward, a medium haptic ticks, and a bar at the
   bottom says "Sending Pip to Studio Mac". When the other device takes it the bar says "Pip is on
   Studio Mac" with Undo for 6 seconds, and VoiceOver announces the same. Undo calls the Imp home.
4. `ask`: a dialog names the Imp and the choices ("Where should Pip go?" or "Send Pip to Sam's iPhone?")
   with one button per device. Nothing moves until a button is tapped.
5. Failure (nobody answers, the device is playing, the link drops, no room): the existing path brings
   the Imp back in from the side it left and a message says why. The bar goes away.
6. Reduce Motion: the bar fades instead of sliding, and the Imp still drifts (the same flight as the menu send).

Ignored: while a sheet is over the stage (chat, editor, Devices, which is also where all typing happens),
during a round of Embers or Echo (`engine.isBlocking`), and for one second after a shake (cooldown).

## Proximity

There is no ranging. "Nearby" means evidence the link already has:

- near: connected over the local network right now (same Wi-Fi or Bonjour reach).
- recent: connected through the Hop server now, but seen on the local network in the last 10 minutes
  (`ShakeSettings.nearbyWindow`). The hub remembers the last local sighting of each device.
- far: neither. A device only reachable through the server and never seen nearby lately.

Near devices win over recent ones. Bluetooth is not used: the local network already finds every device
the link can reach, a Bluetooth scan would add a permission prompt, battery cost and a second trust
path, and it could not tell a linked device from any other. Ultra Wideband direction is not available
between a Mac and an iPhone in a way an app can rely on.

## Trust

A target must be linked (in the book of devices, so its key was exchanged by a code or scan) and connected.
Nothing else is ever offered, so a shake cannot reach a stranger's device. `LinkNode.pass` also refuses a
device that is not a connected peer (test: `aShakeCannotReachADeviceThatIsNotLinked`). A linked device the
owner has not marked "Mine" is somebody else's screen, so a shake asks before sending to it
(setting "Ask before sending to a friend", on by default).

## Transport and latency

The existing `pass` over the link (local network, or the Hop relay). The flight takes about a second and
the other device answers within a moment on the same network. If there is no answer in the transfer
timeout, the pass counts as declined and the Imp is called home. No new messages were added, so Macs
and iPhones on 2.0.x work with this unchanged.

## The cost of a wrong transfer

Low and reversible, which is why the default is no question: the Imp becomes a visitor on the other
device (the Imp, its chats and its keys stay home), Undo calls it back, and "Send Home" or "Call Home"
still work later. It is higher when the device is somebody else's or far away, so those ask.

## Failure keeps the Imp intact

The body stays on the stage as "away" until the other device says `took`. A decline, a timeout or a
lost connection ends the pass as `declined`, the app brings the body back, and the node marks the Imp
as not away. Tests in `LinkNodeTests`: `aDeclinedImpBouncesAndIsNotAway`,
`aThrowNobodyAnswersTimesOutAndTheImpIsCalledHome`, `aTransferInterruptedByALostConnectionLeavesTheImpAtHome`,
`aLateTookForAnImpOfOursIsToldGone` (a late acceptance cannot leave two bodies).

## The three decisions

(a) One eligible nearby device: send at once, no confirmation, Undo for 6 seconds. The cost is low and
Undo is one tap, while a question every time would remove the magic. It requires that the device is
near or was seen nearby within 10 minutes and that it is marked Mine. Without those (a far device, or
a friend's), the dialog comes first. Several devices nearby also ask, because guessing wrong there is
common, not rare.

(b) Which Imp: the one carried, thrown or flown in last ("moved"), then the one touched last, then
by name so it is always the same. Compared with the other ideas:
- last touched alone: a tap opens its chat, and a chat covers the stage, so taps say little about what you want to send.
- last active (working on a task): moving an Imp away mid-task is the worst surprise.
- nearest the shake: a shake has no place on the screen.
- the one being looked at: nothing on the phone knows it, apart from touches, which are the same signal.
Only Imps on the phone's own screen and free (not held, flying, away or still arriving) count. Visiting
Imps do not: they have their own "Send Home". No Imp is ever sent while a game is on.

(c) Direction: by default the direction means nothing, because most people have one device nearby and
a rule to learn would only get in the way. The "Left or right" setting gives two nearby devices a side:
the shake starting toward the right goes to the first by name and toward the left to the second.
It is limited to exactly two. With three or more, or when the side cannot be told, the dialog asks.
A real "device in that direction" is not possible without knowing where the devices are. A ring of
"next and previous" was rejected as it needs a remembered position that changes under the user.

## Settings (iPhone, Devices sheet)

- Shake to send: on by default. Off keeps the old dizzy shake.
- How hard: Gentle (1.5 g), Normal (2.0 g, as before), Firm (2.8 g and five pushes).
- Which device: Any way (default) or Left or right.
- Ask before sending to a friend: on by default.

## The Mac

A Mac has no motion sensor, so it does not start a shake. The transfer starts from the Imp's context
menu, which already has "Send <Imp> to <device>…" for each connected device, and from throwing the Imp
at the side of the screen. It also receives: an Imp shaken toward a Mac lands as a visitor as usual.
