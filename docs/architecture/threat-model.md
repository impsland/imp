# Threat model of Imp Link

This page says what Imp Link protects, from whom, and with which construction. It also says why the
handshake uses a standard pattern.

**An independent security review of the link is recommended before a wide release.** The handshake uses a
maintained library and a standard pattern, but the way Imp joins the pieces (the door key, invites,
tickets and the Hop proofs) is Imp's own.

## What the link protects

| Asset | Why it matters |
|---|---|
| Chats, replies, files and the Imps' looks that cross between devices | Private to the owner |
| An Imp's brain: its keys, tools and memory | They stay at the home device and never cross the link. An Imp on a visit asks its home |
| The device seed (32 bytes, one per device) | It makes the device's identity. Whoever holds it is that device |
| The door key (32 bytes, one per device) | It lets a device open a session with this one at all |
| The invite key (32 bytes, one per shown code) | It lets one more device become a linked peer, for 15 minutes after the code was last on screen |
| Tickets | Let the holder of a visiting Imp act for that one Imp at its home |
| The link book (links, door key, tickets' hashes, visits) | Everything above in one place |

## Who attacks

**Anyone on the network (Wi-Fi, a café, a VPN).** They can watch, delay, drop, replay and change bytes, and
they can open connections to the port.

- Reading: every byte after the first handshake message is encrypted with keys from an ephemeral
  Diffie-Hellman exchange. A recorded session stays unreadable even if a seed or a door key leaks later
  (forward secrecy).
- Changing or replaying: each message is authenticated, and a counter inside the cipher refuses a replay.
  A replayed handshake message gets an answer that the attacker cannot finish.
- Impersonating the host: the guest knows the host's static public key from the invite or the link, and
  the handshake only completes with the host that holds the matching private key.
- Strangers: a connection that does not know the door key fails to produce the first valid message and is
  closed. It learns nothing about the device.
- Flooding: at most 32 connections, 10 seconds to finish the handshake, a rate limit of frames per
  connection, and a 4 MiB frame limit.

**The Hop operator (and anyone who watches the Hop).** The Hop splices bytes. It never holds a seed, a
door key or a session key.

- It sees the room (the host's public Hop key), the gate (a public key every guest derives from the door
  key), both IP addresses, timing and volume. It cannot read, change or forge what flows, for the same
  reason a network attacker cannot.
- It can refuse service, delay, or splice nobody. The apps then use the other routes.
- It cannot take over a room: waiting as the host needs a signature with the host's Hop key. A guest cannot
  wait as host, because the gate key only signs for guests.

**Someone who stole an invite (a photo of the code).** The code holds the host's public keys, the door key
and the invite key.

- With the door key and the invite key they can link as a new peer, until the invite expires (15 minutes
  after the code was last shown) or the host shows a new code. A new code replaces the old invite at once.
- This is the weak point by design: a code is a bearer secret. It is shown on a screen the owner controls
  and it expires. The host sees a new link as soon as it is made and can forget it.
- "Forget everyone" makes a new door key. Every older code and link stops working.

**Someone who stole the link book (a backup, a copied file).** The book holds the seed, so a thief has the
device's identity and can connect as that device to every linked device until the owner forgets it there.

- Tickets are stored as hashes, so a stolen book does not hold working tickets of Imps that are away.
- The book is kept in the system's secure store (the Keychain on Apple), readable only on this device and
  only after the first unlock. A stolen backup of the device does not move it to another device.
- Cure: forget the device on the other devices. Its links die and its Imps come home.

**A lost or stolen device.** Same as the stolen book while it is unlocked. Forgetting it on another device
ends the link, takes back its Imps (the ticket dies) and, with "forget everyone", changes the door key.
An Imp's brain and keys were never on the other device, so they cannot be taken from it.

**A linked device that turns hostile.** It is a peer. It can send any message a peer may send, so it can
throw Imps, ask what a visiting Imp may be asked and see what is on screens. It cannot act for an Imp it
does not hold: the home answers an Imp's requests only from its current holder. Devices marked as not
trusted get answers without tools and only the files inside the Imp's own folder.

## What each construction defends

| Construction | Defends against |
|---|---|
| Noise `IKpsk2` with `Noise_IKpsk2_25519_ChaChaPoly_BLAKE2s` | Reading and changing traffic, impersonating the host, replays, loss of forward secrecy, mixing the identity of a guest with another's |
| Pinned static key of the host (from the code, the link or an Imp's card) | A man in the middle who does not have the host's private key |
| Pre-shared key derived from the door key | Strangers and scanners opening sessions. A device that does not know the door key cannot finish the handshake |
| Join proof: HMAC-SHA256 with the invite key over the Noise handshake hash | A device that has a stolen door key but no fresh invite becoming a peer. A proof is only good on the connection it was made on and cannot be relayed |
| Peers pinned by static key in the book | A device taking the id of a linked device |
| Tickets (32 random bytes, stored as a domain-separated SHA-256) and rotation on every claim | A holder that lost an Imp acting for it, a stolen book giving away tickets |
| Ed25519 proofs at the Hop over a fresh nonce | Hijacking a room, joining a room without the door key |
| Strict parsing and limits in the core | A hostile peer crashing a device or filling its memory: sizes, counts and texts are checked in Rust before anything else sees them |

## Why Noise, and why this pattern

The first design ran TLS 1.2 with a pre-shared key suite (`ECDHE_PSK_WITH_CHACHA20_POLY1305`) through
Apple's Network framework, then added its own Ed25519 proofs bound to a TLS exporter value. It was sound on
paper, but:

- Only Apple's stack offers that suite in a usable way. rustls, Android's TLS and Windows' TLS do not. The
  link has to run on every platform from one core.
- The proofs, the exporter label and the way they were joined were Imp's own construction.
- A host behind the Hop had to forward bytes to its own loopback listener, because the system TLS cannot be
  the server on an outbound connection.

Noise is a framework made for this: two parties that know each other's keys, over any byte stream. Using
`snow` (a maintained, pure Rust implementation, with no unsafe code of its own, 0.10.0) gives one
implementation for every platform and no TLS stack in the apps.

- **`IK`**: the guest knows the host's static key before it connects, because the code and the cards carry
  it. The guest's static key travels encrypted, so a watcher does not learn which device is calling.
- **`psk2`**: the pre-shared key (derived from the door key with HMAC-SHA256 and a label) goes in at the end
  of the second message. A guest without it cannot read the reply or send a valid first message.
- **X25519, ChaCha20-Poly1305, BLAKE2s**: the pattern's usual fast choices, with no hardware assumptions.
- **Rejected: `XX`.** Neither side knows the other's key in advance. Imp does, and `XX` would need extra
  checks to pin keys, which is what `IK` gives for free.
- **Rejected: TLS 1.3 with pinned raw public keys.** TLS 1.3 has no PSK-and-pinned-key mode in the stacks the
  apps could use. It would again depend on each platform's TLS.
- **Rejected: keeping the custom proofs inside Noise.** Noise already authenticates both static keys. The
  host's `welcome` and the guest's `hello` proofs are not needed. Only the join proof stays, because it
  proves something Noise does not: that the guest holds a fresh invite.

### Keys

One 32-byte secret seed per device is stored. Two keys come from it, each with its own HMAC-SHA256 label:

- the Noise static key (X25519), which the link pins, and
- the Hop signing key (Ed25519), which names the device's room at the Hop.

They are two keys because a key used for key agreement should not also sign, and because a flaw in one
primitive then cannot reach the other. The price is that a device card carries two public keys. The seed is
the only secret kept.

### No version number

Nothing on the wire says "version". A change that old devices would misread changes the Noise prologue and
the protocol labels, so an old device fails the handshake cleanly and the app asks you to update both devices. The Hop and the apps are released together for the same reason.

## Out of scope

- A device that is already compromised (malware that can read the app's memory or the unlocked secure
  store).
- Traffic analysis: the Hop operator and a network watcher can see that two addresses talk, when, and how
  much.
- Denial of service by a network attacker who drops packets, and by the Hop operator.
- Protecting a code that someone photographed within its 15 minutes. Show it to the people you mean.
- Side channels of the cryptography libraries and the hardware.
- Post-quantum attackers. A recorded session could be read if X25519 is ever broken. Noise has a path for
  this (hybrid forward secrecy), and the pattern name would change with it.
