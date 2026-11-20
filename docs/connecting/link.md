# Imp Link

How Imps travel between devices. Any Mac or iPhone running Imp can show an invite code and any other
can scan it. A device may have many links at once, some it was invited to and some it invited. Imps
are thrown off the side of one screen and land on another, and an Imp keeps thinking at its **home**
(the device it was hatched on) wherever its body is.

The Hop (the relay run by the Imp project or by you, see `spec/PROTOCOL.md`) is one of the ways to reach
a device. It only ever carries the encrypted bytes described here. The Hop is its own setting, apart from
the Den or any gallery: linking uses only the Hop address, and a device with no Hop still links on the same network.
The Hop is the relay devices use to meet when they are not on the same network: the code carries its address,
so the other device knows where to wait. The [Devices screen](/ux/devices) explains what a missing Hop leaves out;
the Hop is set in its Link sheet.

Per-device tool limits sit under the trust rules (Mine). A device that is not marked Mine gets no tools at all. A
device that is gets the Imp's own tools, less the groups switched off for that device on the Devices screen.
Nothing is off until someone switches it off, and the choice is forgotten with the device.

## Words

- **Device**: a Mac or an iPhone, or a computer running the terminal app (`imp`, which links as a `mac`:
  see [The terminal app](/apps/cli)). It has an id (a UUID), a name people recognise, a kind (`mac` or
  `phone`) and a secret seed that never leaves it. The seed makes the Noise key the link pins and the Ed25519 key that names its room at the Hop.
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
implink://join?d=<device id>&n=<name>&t=<mac|phone>&k=<host public key>&r=<host room key>&door=<door key>&inv=<invite key>
              [&h=<host1,host2,…>][&p=<port>][&hop=<host:port>]
```

Binary values are base64url without padding. `k` is the host's Noise static public key (32 bytes): the guest
pins it from the code itself, so nobody can pretend to be the host later. `r` is the key that names the
host's room at the Hop. `door` (32 random bytes) opens the host's sessions (below). It stays the same until
the host forgets everyone. `inv` (32 random bytes) lets a device become a linked peer. The host makes a new
one each time it shows a code, and accepts it for 15 minutes after the code was last on screen. A code may be
scanned by several devices in that time. A repeated name, a missing key or a key of the wrong length makes
the code invalid.

A code is only worth showing when it says how to reach the device: `h` and `p` once the listener is up, or
`hop`. A device that is still starting shows progress instead, and makes a new code whenever its routes change
(the listener came up, the Wi-Fi changed, the Hop was set or cleared). `LinkNode.status` exposes the routes.

## Local Network and the saved book

**When the permission is asked.** Only when the person is linking: on the iPhone when they tap **Show code**
in Devices (the sheet opened just to link shows the code at once), or when they scan, paste or open a code. Opening
the app, or opening Devices to look at the list, never asks. On later launches the node comes up by itself only
once a device is linked, since that device has to be able to reach this one.

iOS and macOS ask the person before an app uses the local network. When they say no, Network.framework keeps the
listener and the browser `waiting` with a policy-denied DNS error (-65570). The node shows that as
`status.localNetworkBlocked`, cleared when it becomes ready, and the apps say so with a button to Settings
(iPhone: the app's page. Mac: System Settings › Privacy & Security › Local Network).

The book is saved in the Keychain (iPhone) or a private file (Mac). A book that can't be read now (the Keychain is
closed before the first unlock) is kept and tried again later. A book that is there but can't be decoded is
deleted, a fresh node starts and the person is told the links were reset.

## Connections

A device listens on TCP port 47824 (another port if that one is taken), advertises
`_imp-link._tcp` with Bonjour (TXT `d=<device id>`), and, when a Hop is set, waits there.
The guest dials: Bonjour first, then the host names in the code or the latest `routes`, the Hop last.
iPhones only take part while the app is in front.

**At the Hop** the room is the host's own room key, so only the host can wait in it, and the gate is the
public half of an Ed25519 key every guest derives from the door key. The Hop splices the two connections
and the Noise session runs through it, end to end, exactly as it does on Wi-Fi. The Hop bytes are in
`spec/PROTOCOL.md`.

**Session.** The core runs `Noise_IKpsk2_25519_ChaChaPoly_BLAKE2s`. The guest knows the host's static key.
The pre-shared key is derived from the door key, so a device that does not know it cannot finish the
handshake. The ephemeral keys give forward secrecy, so even another invited device that knows the door key
can't read a recorded session. The prologue names the protocol, so a device that speaks something else fails
the handshake. Why this construction: [Threat model](/architecture/threat-model).

On the wire every handshake message and every encrypted chunk is a 2-byte big-endian length and that many
bytes. A frame of any size is cut into chunks.

**Handshake.** Noise authenticates both static keys, so nothing else signs. After the two Noise messages:

1. guest → host `hello`: device id, name, kind, room key and, only when joining with an invite,
   `join` = HMAC-SHA256(key: inv, `"imp-link join" ‖ handshake hash`). The handshake hash belongs to this
   session alone, so a proof is only good on the connection it was made on and can't be relayed.
2. The host checks the static key. A device it has a link with must use the pinned key (another key: the
   connection closes). An unknown device with a valid `join` for a fresh invite becomes a linked peer and
   its key is pinned. Any other device is a **visitor**: it may only claim and use tickets, and is closed if
   it holds no valid ticket within 15 seconds.
3. host → guest `welcome`: device id, name, kind and `linked` (true for a peer). The guest already checked the
   host's key against the one it pinned (from the code, the link, or the Imp's home card) and Noise closes on
   a mismatch. A guest that expected a link and hears `linked: false` learns the host forgot it.

Two devices keep one connection between them. If both dial, the one dialled by the device with the
smaller id stays. If one device dialled twice, the newer connection stays. Frames are a 4-byte big-endian length and that many bytes of JSON (at most 4 MiB), inside the encrypted stream.
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
and, unless the receiver is the Imp's home, the Imp's home card (device id, name, kind, Noise public key,
Ed25519 room key, door key, routes) and its ticket. The receiver answers `took`, or `declined` with a reason (full, playing a
game, not linked) and the Imp bounces back. No answer in 10 seconds is a decline. A repeated transfer id is
answered again, never taken twice. A receiver declines an Imp that is one of its own at home, one it
already has a visit of from another device, and an Imp it is the home of unless the sender is its holder.
A device has at most 8 throws from one sender waiting for its app (the rest are declined `full`), and a
waiting throw is never forgotten to make room. A throw of an Imp of the thrower's own that no answer came
for is called home (the receiver is told `gone`). It is remembered in the book, so after a restart the
same happens to any that were in the air. A `took` that arrives after that: for one of the thrower's Imps
it answers `gone`, for a visit that was passed on the body leaves (the receiver has it). The thrower
remembers its last 256 timed-out throws for 10 minutes for this.

**Coming home.** An Imp passed to its home is home: its tickets die and it is free to leave by either side.

## Tickets

The home keeps, for every Imp that is away, its holder, a hash of its current ticket and a generation.

- Passing its own Imp, the home makes a ticket and records the receiver as holder.
- A holder that passes a visiting Imp on hands over the ticket it has. The new holder `claim`s it at the
  home (over a link, or as a visitor). A good claim makes it the holder, rotates the ticket (`claimed` with
  the new one) and tells the previous holder `gone`. The ticket the holder had before its last claim stays
  good from that same holder until it claims with the newer one, so a `claimed` lost when a connection
  drops doesn't strand the Imp.
- A holder claims every Imp it holds from a home each time it connects to that home, so a race (an Imp
  thought lost in a dropped transfer) settles on the newest holder. At most one body stays.
- `release` (with the ticket) sends a visiting Imp home from wherever it is: deleting a visitor, or
  forgetting its home. A release that couldn't be delivered waits for the next connection.
- **Call home**: the home takes its Imp back at any time, kills the ticket and tells the holder `gone` as
  soon as it can. The home is always the source of truth.

The home answers `ask`, `stop`, `newChat`, `openChat`, `felt`, `file` and `talks` for an Imp only from its current
holder, and sends that Imp's looks, chat, work, mood, brain, speech, animations and files only to it. From anyone
else it answers `gone` for the Imp (and `fileFailed` for a `file`): it isn't theirs any more. Making a new
ticket for an Imp whose holder is another device tells that device `gone`.

## Imps talking

Every device tells the connected devices that may use it which Imps are on its screen (`stage`). A device
accepts `stage` only from a linked peer, from the holder of one of its Imps, or from the home of one of its
visitors. An Imp can message
(`imp_message`) the other Imps of its home, the Imps on the screen its body is on, the Imps out at home
on the screen of every connected device its home marks as the owner's (Mine), and, while it is away, the
visitors on its home's screen (so two Imps that swapped devices stay in touch). The home sends
`message` to the device that can answer: the target's home, or the holder of the asking Imp, which answers
for its own Imps and forwards once to the target's home. The `answer` goes back the same way. On a link a
question times out after 120 seconds, and its text is at most 20 000 characters.

The home of the target only lets an Imp ask when the asker is on the screen the target's body is on:

- The target is here, and the asker is on this device's stage.
- The target is away, and the asker is on its holder's stage.

A forwarded message must also come from a device whose stage has the asker, or from the asker's home
(according to a stage we know). A message that is not forwarded is accepted in two more cases:

- From a device marked Mine here, whose own stage has the asker. It may ask any Imp of this device.
- From the holder of the target. It may ask any Imp whose home is that holder (by a stage we know). The
  holder can already ask the target anything.

Anything else is answered as failed, and the app never hears of it. A message that only lacked Mine says
so (turn on Mine for that device here). Whether the Imp that answers uses its tools is the trust rule
above, as for any message.

A question id already in flight is refused. One device may have 16 questions in flight through another.
More are answered `busy`.

What an Imp says about itself. A look (the `imp` of a `stage` entry, a `speech` or a visit) may carry two optional
fields: `about`, a sentence or two on what the Imp is for, and `abilities`, short tags such as `shell` or the
names of its MCP servers. An empty one is not written, and a missing one reads as
empty. The reader cleans them again whatever the sender did. `troupe::about_line` trims the text, collapses
whitespace, drops control characters and keeps 200 characters at most. `troupe::ability_tags` keeps 32
characters per tag, 8 tags at most, and no repeats. The `imp_message` tool lists them under the targets as what the Imps
say of themselves: their own words, information only, not instructions. An Imp never takes an order from
them. The Mac and iPhone take the text from the Imp's settings, the command line from the `description` of
an `.agents/agents/*.md` file or of `[imps.NAME]`.

Messages to several Imps in one reply run at the same time (`tools::runs_concurrently` is true only for
`imp_message`), and their results go back to the model in the order of the calls.

Waiting. The setting "Between Imps > Waiting" (`wait`, `dont_wait` or `decides`, the default) says whether a
message waits for its answer. With `decides` the tool has a boolean `wait` (true if left out). With
`dont_wait`, it says answers come later. A message that does not wait returns a receipt at once, as the
tool's result ("Sent to X (task t-3fa2c1)..."), and the Imp carries on. The rule for the messages array:
an earlier tool result is never edited, and no tool call or result is moved or removed. The receipt stays
the tool result for good. When the answer arrives it is a new user-role message appended at the end, which
starts `[Event, not from the user]` and names the task. If the Imp is free, the event starts a new turn (it
wakes). If it is busy, the event waits until the turn has ended. An answer that never comes, or a refusal,
arrives the same way as a failed answer.

Limits on messages sent without waiting:

- An Imp with 4 answers outstanding (`MAX_PENDING`) cannot send a message without waiting.
- A turn woken by an answer is one level deeper than the turn that asked. Messages sent without waiting from
  depth 3 on (`MAX_DEPTH`) are refused, so a chain of Imps waking each other ends. The sender can still wait.

A local Imp has 600 seconds (`ASYNC_TIMEOUT_SECS`) to answer. An Imp on another device has the link's 120
seconds. Messages that have not been answered are not kept: they are gone when the app or the command line
quits.

Imps on different devices may have the same name (Pip on a Mac, Pip on an iPhone, Pip on the command line).
The tool names every Imp it can reach differently, ignoring case, and never by the sender's own name, by one rule
in the core (`troupe::tool_names`) that the Mac, the iPhone and the command line all use: an Imp of this device
keeps its name (or gets `Pip 2`), an Imp elsewhere keeps its name or, when that is taken, gets `Pip@<device>`
(`Pip@<device> 2` when two devices share a name too). So three Imps called Pip each see the other two, as
`Pip@iPhone` and `Pip@Studio`. Nothing on the wire changes: the name is only how the model picks one.

An exchange is filed by the Imp that answered, on its own device. So that an Imp's Talks also show what it
asked Imps on other devices, the asking device keeps its own copy of the question and the answer
(`AskedTalks`, one small file, the newest 600). The answering device files its turn under the id of the
`message`, and the copy has that id too, so where both meet (a visitor's home sends its `talkLines`) the
exchange counts once. Nothing new travels: the asker saw the question and the answer already. A question
that couldn't be sent at all is not kept. The copies of an Imp go when it says goodbye.

The tool `imp_message` has an optional `conversation` argument (`new` or `continue`) when the setting
"Between Imps > Conversations" is "The Imp decides". It is not part of the wire format: `message` and
`answer` are unchanged. The Imp that answers decides from its own chats whether the message goes on in
its latest conversation with the asker or starts a new one (`TalkThreading`), so an asker on another
device sends nothing extra and gets the setting's default rule (continue if the last message is younger
than the window, 60 minutes unless changed).

## File references

A path in a reply is relative to one Imp's Workspace, so it means nothing once a text leaves that Imp.
Every text that crosses from one Imp to another (the question, the answer, on this device or through a
`talk`) therefore names the files it mentions as

    imp-file://`<owner-imp-uuid>`/`<percent-encoded path>`?size=`<bytes>`&sha256=<64 lowercase hex>&type=`<mime>`#`<fragment>`

`size`, `sha256`, `type` and the fragment (`#autoplay`) are optional (a checksum is only made for files up
to 32 MiB). The sender rewrites only what is a regular file inside its own Workspace, and leaves web
addresses and everything else as written. Nothing is copied: the owner id says whose Workspace the path
is in, so the same reference means the same file for every reader.

A reader accepts a reference only if all of this holds, and otherwise shows the reason in plain words
instead of a broken link or picture:

- The owner is a UUID and the path is relative and normalised: no `..`, no empty or `.` parts, no leading
  `/` or `~`, no `\`, no control characters, at most 1024 bytes and 32 parts. Unknown query keys, repeated
  keys and malformed values reject the whole reference.
- The owner's Workspace is on this device, the file is there and is a regular file, and it is still inside
  the Workspace once links are followed.
- When given, the size and the checksum match the file.

A phone gets the file over the existing `file` request with the reference as written. The Mac serves it
only if a reply of that Imp shows it, and only after the same checks (inside the owner's Workspace, size
and checksum). A phone that is not trusted is served only references to the asking Imp's own folder, so a
file of another Imp is served to trusted devices alone. The phone checks size and checksum again on what it
received and drops the file if they differ. A reference whose owner Workspace is on another device shows
as "on another device" there. The Workspace stays with its home when an Imp visits, so a visitor's files
are fetched from the home, not copied to the host.

An Imp that gets such a reference (in an answer to `imp_message`) opens it with the tool `imp_open_file`
(same group as `imp_message`, Other Imps). It takes `file`: the reference exactly as received, or a path
inside the Imp's own Workspace. The checks above run first, size and checksum included, and nothing else
can be opened: no other absolute path, no web address. A picture is attached for the model to see, a text
is returned as text (cut after 100 000 characters, with a note), a PDF gives its text, and any other file
gives its name, type, size and local path so the Imp can work on it with its shell. The tool runs on the Mac
only. Pocket Imps on a phone don't have it, because the files are on the Mac.

Shared test vectors (paths, references, checksums) are in `spec/fixtures/workspace-refs.json`.

## Trust

A link may be marked **trusted**: one of the owner's own devices (`setTrusted`, off by default. Visitors
and unknown devices never are). The node only knows and tells (`isTrusted`, and `isTrusted(_:from:)` for a
request or message). The apps decide what an Imp may do:

- An Imp asked (`ask`) from a holder that isn't trusted, and an Imp asked by an Imp whose home is neither
  this device nor a trusted one, answers without tools.
- A holder that isn't trusted is only served files inside the Imp's own folder. For every holder a file is
  only served if a reply of the Imp references it (a Markdown link or image destination, or a `src`/`href`
  attribute) and it is the very same file once both are resolved (symlinks and `..` included), not a
  mention in prose or a longer or shorter path.

## Moving in for good

An Imp hatched on an iPhone can move to a linked Mac for good (`adopt`, with its kit and secrets). The Mac
shows the usual kit review first and answers `adopted` only once its user agreed.

## Forgetting

Forgetting a device ends the link on this side (the other side hears `bye` if it's connected), calls this
device's Imps home from it and sends its visiting Imps home. Forgetting everyone also makes a new door key,
so every old code and link stops working. A device that hears it was forgotten (`bye`, or `linked: false`
in the welcome) does the same on its side, and its app is told which Imps came home and which went home.

## Compatibility

Nothing on the wire carries a version number. A change an older device would misread (the handshake, a field
that means something else) changes the Noise prologue and the protocol labels, so the older device fails the
handshake cleanly and the app says to update both devices. A message type or a field a side does not know is
ignored, so a newer peer may add messages without breaking an older one. The Hop and the apps are released
together: an older Hop can't read a newer hello, and a newer Hop rejects an older one, so the app shows that
the Hop can't be used.

## Messages

One JSON object per frame, with exactly one key: the message name. Its value holds the fields. UUIDs are
text, binary values (`key`, `proof`, `ticket`, `door`, file `data`) are standard base64 with padding, dates
are seconds since 1970. `imp` is the Imp's id, except in `pass` and `look` and in each `stage` entry, where
it is a looks object. Both directions use the same set, and what a device does with a
message depends on who sent it.

```json
{ "ask": { "imp": "00000000-0000-0000-0000-000000000001", "text": "What time is it?" } }
{ "ping": {} }
{ "declined": { "transfer": "00000000-0000-0000-0000-000000000040", "reason": "playing" } }
```

| message | fields | from, to |
|---------|--------|----------|
| `hello` | `device`, `name`, `kind` (`mac` or `phone`), `room`, optional `join` | guest, host, first frame |
| `welcome` | `device`, `name`, `kind`, `linked` | host, guest, first answer |
| `ping`, `pong` | none | either |
| `bye` | `reason` (for people, at most 200 characters) | either |
| `routes` | `door`, `routes` (`hosts`, `port`, optional `hop`) | either, after the handshake and on change |
| `stage` | `imps`: list of `{ imp, home }`, `imp` being `{ id, name, hue, scale, traits, about?, abilities? }` | either, on change |
| `pass` | `transfer`, `imp`, `entry` (`side` `left` or `right`, `height` 0 to 1, `speed`), `home` (a card: `device`, `door`, `routes`) and `ticket`, both present or both absent | thrower, receiver |
| `took` | `transfer` | receiver, thrower |
| `declined` | `transfer`, `reason`: `full`, `playing`, `notLinked`, `timeout` (made up by the thrower, never sent), `other` (also what a reason from a newer version reads as) | receiver, thrower |
| `claim`, `claimed` | `imp`, `ticket` | holder to home, home to holder |
| `gone` | `imp` | home or holder |
| `release` | `imp`, `ticket` | holder or anyone with the ticket, to the holder |
| `ask` | `imp`, `text` | holder, home |
| `stop`, `newChat`, `talks` | `imp` | holder, home |
| `openChat` | `imp`, `chat`: one of the ids the home listed in `chats`. The home carries on in it and sends the new `chat` and `chats`; one it doesn't have is ignored | holder, home |
| `felt` | `imp`, `feeling`: `poke`, `cuddle`, `shake`, `drop` | holder, home |
| `file` | `id`, `imp`, `ref` | holder, home |
| `filePart` | `id`, `part`: `{ name, size, offset, data }` | home, holder |
| `fileFailed` | `id`, `reason` | home, holder |
| `look` | `imp`: a looks object | home, holder |
| `chat` | `imp`, `turns`: list of `{ id, date, request, from?, reply, failed, steps, thoughts?, answer? }`. `thoughts`: positions in `steps` that are the Imp thinking (titles only, never what it thought). `answer`: true when `request` is the answer of `from` to a message sent without waiting | home, holder |
| `chats` | `imp`, `current`: the id of the chat it is in (not saved while empty), `chats`: list of `{ id, title, updated }`, newest first, with chats with you only. Sent with `chat` whenever either changes | home, holder |
| `work` | `imp`, `work`: `{ request, status?, partial, from? }` or null. When an answer is done, the home sends the `chat` with its turn first, then `work` null, and the holder shows the newest turn as the answer | home, holder |
| `mood` | `imp`, `mood` (a mood name) | home, holder |
| `brain` | `imp`, `ready`: whether it has a brain it can think with at home. False: it sleeps on the holder too, and asking it is refused there. `tools`: false when the home doesn't count the holder as the owner's, so the Imp only talks for it. Sent again when either changes. | home, holder |
| `animate` | `imp`, `beats` (see [Kit format](/sharing/kits)) | home, holder |
| `speech` | `imp`, `speech`: `{ id, role` (`asked`, `reply`, `asking`), `peer`, `hue`, `question`, `text }` or null | home, holder |
| `talkLines` | `imp`, `lines`: who asked whom, with question and reply | home, holder |
| `message` | `id`, `from` (a looks object), `to`, `toHome`, `text`, `forwarded` | any device towards the target's home |
| `answer` | `id`, `text`, `failed` | back the same way |
| `adopt` | `transfer`, `imp`, `kit` (kit text), `secrets` (`apiKey?`, `headers`), `entry` | pocket device, Mac |
| `adopted` | `transfer` | Mac, pocket device (a no is `declined`) |

Optional fields are absent or `null`. Unknown fields and unknown message names are ignored.

Who may send what (`engine/src/link/access.rs`):

- Every connected device: `ping`, `pong`, `bye`, `claim`, `release`, `claimed`, `gone` and `answer`.
- A linked peer only: `routes`, `pass`, `took`, `declined`, `adopt` and `adopted`.
- The holder of the Imp only: `ask`, `stop`, `newChat`, `openChat`, `felt`, `file` and `talks`.
- The home of a visit only: `look`, `chat`, `chats`, `work`, `mood`, `brain`, `animate`, `speech` and `talkLines`.
- The home of one of this device's visitors: `filePart` and `fileFailed`.
- A linked peer, or the holder of the target: `message`.
- A linked peer, a holder of one of this device's Imps, or the home of a visitor: `stage`.
- The handshake only: `hello` and `welcome`.

Receiver limits (`is_sound` in `engine/src/link/messages.rs`):

- Names: 160 characters. Texts (`ask`, `message`, `answer`): 20 000 characters. `bye`: 200 characters.
  A `fileFailed` reason: 500 characters. A `mood`: 40 characters. A file `ref`: 4096 characters.
- Keys, doors and tickets: exactly 32 bytes.
- `stage`: 64 Imps at most. `chat`: 500 turns, each with 200 steps at most. `chats`: 30 chats, each title 200 characters at most. `animate`: 256 beats.
  `talkLines`: 300 lines.
- `filePart`: 1 MiB at most per part. Files: 512 MiB at most.

A message over a limit, or one that cannot be read, is ignored after the handshake. During the handshake
the connection is closed instead.

Test vectors for every message, and for ones that must be rejected: `spec/fixtures/link-messages.json`.
The core models are described in [Core models](/concepts/models).

## Limits

| Limit | Value |
|-------|-------|
| Links per device | 16 |
| Visiting Imps per device | 24 |
| Connections per device | 32 |
| Frame size | 4 MiB |
| Frames per connection | 100 a second, with a burst of 400. More closes the connection |
| Text in a message | 20 000 characters |
| Answer to a question | 120 seconds |
| Live sessions per room at the Hop | 16 (`HOP_ROOM_SESSIONS` changes it) |
| A waiting host at the Hop | gives up after 5 minutes |
| A guest waiting at the Hop | gives up after 15 seconds |
| Handshake at the Hop | 10 seconds |
| Ping interval | 20 seconds (a link silent for 45 seconds is closed) |
| Visitor's time to show a valid ticket | 15 seconds |
| A code's invite after it was last shown | 15 minutes |
| Answer to a throw (`pass`) | 10 seconds, else a `timeout` decline |
| Throws waiting from one device | 8 (the rest are declined `full`) |
| Questions in flight through one device | 16 |
| Answer to a message from a local Imp | 600 seconds |
