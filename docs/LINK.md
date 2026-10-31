# Imp Link 2

How Imps travel between devices. Any Mac or iPhone running Imp can show an invite code and any other
can scan it. A device may have many links at once, some it was invited to and some it invited. Imps
are thrown off the side of one screen and land on another, and an Imp keeps thinking at its **home**
(the device it was hatched on) wherever its body is.

The Hop (the relay on an Imp server, see `server/PROTOCOL.md`) is one of the ways to reach a device.
It only ever carries the encrypted bytes described here.

## Words

- **Device**: a Mac or an iPhone. It has an id (a UUID), a name people recognise, a kind (`mac` or
  `phone`) and an Ed25519 signing key that never leaves it.
- **Home**: the device an Imp's brain lives on: its models, keys, tools and chats. Mac Imps live on
  their Mac, Imps hatched on an iPhone on that iPhone.
- **Holder**: the device an Imp's body is on right now. At home, holder and home are the same.
- **Link**: two devices that know each other, made by scanning an invite. Either may throw Imps to the
  other while they're connected. A link is pinned: each side keeps the other's public key.
- **Visit**: an Imp on a device that isn't its home. Its holder talks to its home for everything it
  thinks, says and does. When the home can't be reached, a visiting Imp sleeps.
- **Ticket**: a bearer secret that lets the holder of a visiting Imp reach its home and act for that one
  Imp, even when the holder isn't linked to the home. The home rotates it every time it's used.

## Invites

The inviting device (the host) shows a QR code with:

```
implink://join?v=2&d=<device id>&n=<name>&t=<mac|phone>&k=<host public key>&door=<door key>&inv=<invite key>
              [&h=<host1,host2,…>][&p=<port>][&hop=<host:port>]
```

Binary values are base64url without padding. `k` is the host's Ed25519 public key (32 bytes): the guest
pins it from the code itself, so nobody can pretend to be the host later. `door` (32 random bytes) opens
the host's TLS (below); it stays the same until the host forgets everyone. `inv` (32 random bytes) lets a
device become a linked peer; the host makes a new one each time it shows a code, and accepts it for 15
minutes after the code was last on screen. A code may be scanned by several devices in that time.

## Connections

A device listens on TCP port 47824 (another port if that one is taken), advertises
`_imp-link._tcp` with Bonjour (TXT `d=<device id>`), and, when an Imp server is set, waits at its Hop.
The guest dials: Bonjour first, then the host names in the code or the latest `routes`, the Hop last.
iPhones only take part while the app is in front.

**At the Hop** the room is the host's own public key, so only the host can wait in it, and the gate is the
public half of an Ed25519 key every guest derives from the door key (seed = HMAC-SHA256(key: door,
"imp-hop gate v2")). The host forwards each spliced connection to its own listener on loopback, so TLS
ends in the same place as on Wi-Fi.

**TLS.** TLS 1.2 only, cipher suite `TLS_ECDHE_PSK_WITH_CHACHA20_POLY1305_SHA256` (0xCCAC): the pre-shared
key keeps strangers out and the ephemeral ECDH gives forward secrecy, so even another invited device that
knows the door key can't read a recorded session. PSK = HMAC-SHA256(key: door, "imp-link psk v2"),
identity `imp-link/2`.

**Binding.** Both sides take a 32-byte TLS exporter value with the label `EXPORTER-imp-link/2`
(`sec_protocol_metadata_create_secret`). Every proof below signs or MACs it, so a proof is only good on
the connection it was made on and can't be relayed.

**Handshake.** The first frame each way:

1. guest → host `hello`: device id, name, kind, public key, `proof` = Ed25519 signature of
   `"imp-link/2 hello" ‖ binding ‖ host device id (16 bytes)`, and, only when joining with an invite,
   `join` = HMAC-SHA256(key: inv, `"imp-link/2 join" ‖ binding`).
2. The host checks the signature. A device it has a link with must use the pinned key (another key: the
   connection closes). An unknown device with a valid `join` for a fresh invite becomes a linked peer and
   its key is pinned. Any other device is a **visitor**: it may only claim and use tickets, and is closed if
   it holds no valid ticket within 15 seconds.
3. host → guest `welcome`: device id, name, kind, `linked` (true for a peer), `proof` = Ed25519 signature of
   `"imp-link/2 welcome" ‖ binding ‖ guest device id`. The guest checks it with the key it pinned (from
   the code, the link, or the Imp's home card) and closes on a mismatch. A guest that expected a link and
   hears `linked: false` learns the host forgot it.

Two devices keep one connection between them. If both dial, the one dialled by the device with the
smaller id stays. Frames are a 4-byte big-endian length and that many bytes of JSON (at most 4 MiB).
Either side pings every 20 seconds and a connection silent for 45 seconds is closed.

## Throwing

**Doors.** Where a thrown Imp goes depends on how it came:

- At home it may leave by either side, to any connected linked device.
- On a visit it came in through one side from some device. Thrown back off that same side, it returns to
  that device. Thrown off the other side, it goes on to any other connected linked device, never back.

When a side leads to several devices, the side is split into equal bands from top to bottom, one per
device in a stable order, and the height of the throw picks one. The bands are labelled on screen while an
Imp is carried near the edge. A side that leads nowhere bounces the Imp back with a hint. During a game the
edges always bounce.

**Passing.** The thrower sends `pass`: a transfer id, the Imp's looks, the entry (side, height, speed),
and, unless the receiver is the Imp's home, the Imp's home card (device id, name, kind, public key, door
key, routes) and its ticket. The receiver answers `took`, or `declined` with a reason (full, playing a
game, not linked) and the Imp bounces back. No answer in 10 seconds is a decline. A repeated transfer id is
answered again, never taken twice.

**Coming home.** An Imp passed to its home is home: its tickets die and it is free to leave by either side.

## Tickets

The home keeps, for every Imp that is away, its holder, a hash of its current ticket and a generation.

- Passing its own Imp, the home makes a ticket and records the receiver as holder.
- A holder that passes a visiting Imp on hands over the ticket it has. The new holder `claim`s it at the
  home (over a link, or as a visitor). A good claim makes it the holder, rotates the ticket (`claimed` with
  the new one) and tells the previous holder `gone`.
- A holder claims every Imp it holds from a home each time it connects to that home, so a race (an Imp
  thought lost in a dropped transfer) settles on the newest holder. At most one body stays.
- `release` (with the ticket) sends a visiting Imp home from wherever it is: deleting a visitor, or
  forgetting its home. A release that couldn't be delivered waits for the next connection.
- **Call home**: the home takes its Imp back at any time, kills the ticket and tells the holder `gone` as
  soon as it can. The home is always the source of truth.

The home answers `ask`, `stop`, `newChat`, `felt`, `file` and `talks` for an Imp only from its current
holder, and sends that Imp's looks, chat, work, mood, speech, animations and files only to it.

## Imps talking

Every device tells every connected device which Imps are on its screen (`stage`). An Imp can message
(`imp_message`) the other Imps of its home and the Imps on the screen its body is on. The home sends
`message` to the device that can answer: the target's home, or the holder of the asking Imp, which answers
for its own Imps and forwards once to the target's home. The `answer` goes back the same way. Messages time
out after 120 seconds and are at most 20 000 characters.

## Moving in for good

An Imp hatched on an iPhone can move to a linked Mac for good (`adopt`, with its kit and secrets). The Mac
shows the usual kit review first and answers `adopted` only once its user agreed.

## Forgetting

Forgetting a device ends the link on this side (the other side hears `bye` if it's connected), calls this
device's Imps home from it and sends its visiting Imps home. Forgetting everyone also makes a new door key,
so every old code and link stops working.

## Limits

16 links, 24 visiting Imps, 32 connections, 4 MiB frames, 20 000-character texts, 120-second answers.
