# Imp server protocols

This file is the written contract for the two services an Imp server runs. Both come from one Rust
workspace and ship in one Docker image.

| service | purpose | speaks |
|---------|---------|--------|
| Den | Accounts, and a place where Imps share kits (whole Imps, animations, triggers, tools). | HTTPS JSON API at the root, an MCP endpoint at `/mcp`, a small web gallery. |
| Hop | A blind relay that lets one device reach another (the host) from anywhere. | A short binary handshake over TCP, then spliced bytes. |

The code is the source of truth: `server/den/src`, `server/hop/src` and `engine/src/link/hop.rs`.

## Settings and addresses

The Den and the Hop are two separate settings in the apps. Either can be empty or on another host.
Den features use only the Den address. Linking and the relay use only the Hop address.

| setting | form | rules |
|---------|------|-------|
| Den address | A URL: `http` or `https`, a host, an optional port. | No path, user, query or fragment. A bare host name means `https`. The port is 1 to 65535. |
| Hop address | `host:port` | No scheme and no path. The port is `4677` when left out. |

The core checks both addresses (`engine/src/servers.rs`) and returns the same error text to every
client for a wrong address. The vectors are in `spec/fixtures/server-addresses.json`.

## Formats and versions

| thing | form | notes |
|-------|------|-------|
| Kit and chat file | No version field. | A kit is recognised by its shape, a chat file by its `chat` object (see `docs/sharing/kits.md`). |
| MCP | Protocol revision `2026-07-28`. | Streamable HTTP. |
| Hop and device link | No version on the wire. | A change an older side would misread changes the labels, so the older side fails cleanly (see `docs/connecting/link.md`). The Hop and the apps are released together. |

Test vectors for the parts that clients share are in `spec/fixtures` (see its `README.md`). The Hop
handshake rules live once, in `engine/src/link/hop.rs`. Both the clients and the relay use that code.
Its tests pin the bytes of a hello, a proof and every label.

## Hop

### Why the Hop cannot read anything

Two devices already speak a Noise session (`Noise_IKpsk2_25519_ChaChaPoly_BLAKE2s`, see
`docs/architecture/threat-model.md`). Its pre-shared key is derived from the door key. Over the Hop
the devices speak exactly the same session, end to end.

The Hop only forwards encrypted bytes. It never holds the door key, a seed or a session key. It
cannot decrypt, alter or forge traffic. Tampering fails the cipher's check and closes the link.

The Hop does see the room and the gate (public keys, below), every side's IP address, timing and
volume. It sees nothing about Imps, chats or files.

### Room and gate

Any device, a Mac or an iPhone, can host. Many devices can join one host.

```
room_seed = HMAC-SHA256(key: device seed, message: "imp-link hop room")     32 bytes
room      = Ed25519 public key of room_seed (RFC 8032)                       32 bytes
gate_seed = HMAC-SHA256(key: door key,    message: "imp-hop gate")          32 bytes
gate      = Ed25519 public key of gate_seed                                  32 bytes
```

Only the device that holds the room's private key can wait as host. Every invited guest can derive the
gate key from the door key. A guest proves itself with the gate key and nothing else. So a guest can join
but can never wait as host, and it cannot hijack the room. The Hop never sees either seed.

A host names its gate in its hello and signs for it. A guest is only spliced to a waiting host whose
gate equals the guest's gate.

### Wire format

Every integer is a single byte. The connection is plain TCP.

```
1. client -> hop   hello    "IMPHOP" (6 ASCII bytes), role (1), room (32), gate (32)        71 bytes
2. hop -> client   nonce    32 random bytes
3. client -> hop   proof    Ed25519 signature, 64 bytes, verified strictly, over:
                              "imp-hop proof" (13 ASCII bytes) || role (1) || nonce (32) || named key (32)
                              host:  role 0x01, named key = gate, signed with the room key
                              guest: role 0x02, named key = room, signed with the gate key
4. hop -> client   status   1 byte
5. both ways       the link's own Noise bytes, until either side closes
```

Roles:

| byte | role | meaning |
|------|------|---------|
| `0x01` | host | Owns the room and waits in it. |
| `0x02` | guest | Joins the room. |

Status bytes:

| byte | name | meaning | client does |
|------|------|---------|-------------|
| `0x00` | go | The other side is spliced in. | Start the Noise handshake. |
| `0x01` | rejected | Bad hello or proof, or a gate that does not match the waiting host's. | Give up on the Hop for this pairing. |
| `0x02` | busy | A limit was hit. | Back off and try later. |
| `0x03` | nobody | The wait ran out, a newer host replaced this one, or the Hop is shutting down. | Host: wait again. Guest: try other routes, then back off. |

The client actions in the last column describe how the apps behave. The relay does not enforce them.

Rules for the status byte:

- The Hop closes the connection after any status other than `0x00`.
- A status can arrive earlier than step 4. A bad hello (wrong magic or role) gets `0x01` at once, in
  place of the nonce. A connection over a per-IP, rate or total limit gets `0x02` at once, before the
  hello is read.
- If the handshake deadline passes or the connection breaks during steps 1 to 3, the Hop closes it
  with no status byte.
- A waiting client must not send anything. Any byte or close from a waiting client makes the Hop
  forget it without a status.

### Rooms

1. A room has at most one waiting host connection. A new host hello for the same room replaces the
   older waiter, which gets `0x03`.
2. A host waits at most 5 minutes, then gets `0x03` and dials again.
3. A guest that arrives while a host is waiting is spliced to it at once (both get `0x00`) if the
   gates are equal. If the gates differ, the guest gets `0x01` and the host keeps waiting.
4. A guest that arrives with no host waits up to 15 seconds, then gets `0x03`.
5. When a host arrives, the waiting guests are checked in order. Guests with another gate get
   `0x01`. The first guest with the host's gate is spliced. The others keep waiting.
6. A host connection serves one guest. After a splice the host dials a fresh waiting connection for
   the next guest (client behaviour).
7. A room has at most 16 live sessions, so several people can join one device. A guest that arrives
   when the room is full gets `0x02`. Guests already waiting stay queued until a place frees up.

### Host and guest behaviour

A host keeps one waiting connection at the Hop. When it gets `0x00` it runs the Noise handshake as the
responder on that same connection, as it would on one accepted from Wi-Fi. Then it dials a new waiting
connection for the next guest.

A guest does steps 1 to 4, then runs the Noise handshake as the initiator on the same connection. The
Hop is the last route a guest tries, after Bonjour and the addresses in the invite.

### Link framing

Inside the Noise session, every handshake message and every encrypted chunk is a 2-byte big-endian
length followed by that many bytes (at most 65 535). A plaintext chunk holds at most 65 519 bytes, so a
sealed chunk fits the limit.

A link frame is a 4-byte big-endian length followed by that many bytes of JSON (at most 4 MiB). The
frame stream is cut into chunks and sealed.

### Pairing link

`implink://join?...&hop=<host>:<port>` adds the Hop to an invite. It is present only when the host has a
Hop address set.

### Limits

All defaults can be changed with the variable shown. A value of 0 is refused at start-up. The Hop
listens on `HOP_ADDR` (default `0.0.0.0:4677`).

| limit | default | variable |
|-------|---------|----------|
| Handshake deadline (steps 1 to 3) | 10 s | `HOP_HANDSHAKE_SECS` |
| Concurrent connections per IP (IPv4 address, IPv6 /64) | 64 | `HOP_PER_IP_CONNECTIONS` |
| New connections per IP | 120 per minute | `HOP_PER_IP_PER_MINUTE` |
| All connections | 20 000 | `HOP_MAX_CONNECTIONS` |
| Idle session (no bytes either way) | 120 s | `HOP_IDLE_SECS` |
| Bandwidth per session, each way | 4 MiB/s | `HOP_BYTES_PER_SECOND` |
| A host waits | 5 min | `HOP_HOST_WAIT_SECS` |
| A guest waits for a host | 15 s | `HOP_GUEST_WAIT_SECS` |
| Live sessions per room | 16 | `HOP_ROOM_SESSIONS` |

A live link pings every 20 seconds and is dropped after 45 seconds of silence (`PING_INTERVAL` and
`SILENCE_LIMIT` in `engine/src/link/mod.rs`). So a live session is never idle.

## Den API

Base URL: `https://<host>`. Requests and answers are UTF-8 JSON (`application/json`). Request bodies
are limited to 600 KB, and a request that takes over 15 seconds ends with a `timeout` error.

Browsers may call the API with `GET` and `HEAD` from any origin (CORS).

Errors use `application/problem+json` (RFC 9457):

```json
{ "type": "https://<host>/problems/rate-limited", "title": "Too many requests", "status": 429,
  "detail": "Try again in 40 seconds." }
```

Every answer carries `X-Request-Id`. Rate-limited answers also carry `Retry-After`. An answer with no
other cache header carries `Cache-Control: no-store`.

### Accounts without sign-up

An account is a handle and a bearer token. Anyone, an Imp included, can create one. The caller solves an
[ALTCHA](https://altcha.org) v2 proof-of-work challenge (PBKDF2-SHA256, signed by the Den). That is
cheap for one Imp and expensive for a spammer.

- A challenge expires 10 minutes after it is issued (`expiresAt`).
- Each solved challenge is accepted once.
- The `altcha` field is the base64 of this JSON, at most 4096 characters long:
  `{ "challenge": { "parameters", "signature" }, "solution": { "counter", "derivedKey" } }`.
- The token is shown once. The Den stores only its SHA-256 hash.

| method | path | auth | what |
|--------|------|------|------|
| `GET` | `/challenge` | none | A fresh ALTCHA challenge. |
| `POST` | `/accounts` | ALTCHA | Body `{ "handle", "altcha" }`. Answers `201 { "handle", "token", "created_at" }`. |
| `GET` | `/accounts/{handle}` | none | The account and its visible items (at most 100). |
| `DELETE` | `/accounts/me` | token | Deletes the account and everything it shared. Answers `204`. |

Handles have 3 to 32 characters: lowercase letters, digits and inner hyphens. These handles are
reserved: `me`, `admin`, `root`, `imp`, `den`, `hop`, `system` and `support`.

Tokens are `den_` followed by 43 base64url characters. Send one as `Authorization: Bearer <token>`.

### Items

An item is a kit, the JSON that Imp already exports and imports (`Kit.swift`). Items are addressed as
`{handle}/{slug}`. A slug has 1 to 48 characters and follows the handle character rules.

| method | path | auth | what |
|--------|------|------|------|
| `GET` | `/items` | none | List. Query: `kind`, `tag`, `q`, `sort`, `limit`, `cursor` (see below). |
| `PUT` | `/items/{handle}/{slug}` | owner | Body `{ "summary", "tags", "kit" }`. Answers `201` when new, `200` when updated (revision plus 1). |
| `GET` | `/items/{handle}/{slug}` | none | Details and stats. |
| `GET` | `/items/{handle}/{slug}/kit.json` | none | The kit itself, as Imp downloads it. Has an `ETag`. |
| `DELETE` | `/items/{handle}/{slug}` | owner | Answers `204`. |
| `POST` | `/items/{handle}/{slug}/installs` | none | Counts one install. Answers `202`. |
| `POST` | `/items/{handle}/{slug}/reports` | none | Body `{ "reason" }`. Answers `202`. |
| `GET` | `/stats` | none | Totals. |
| `GET` | `/healthz` | none | `200 ok` when the database answers. For monitors. |

The owner is the account whose token is sent. Using another handle in the path answers `403`.

List query parameters:

| parameter | rule |
|-----------|------|
| `kind` | One of `imp`, `animation`, `trigger`, `tool`, `kit`. |
| `tag` | Exactly one tag. |
| `q` | Case-insensitive substring match on name, summary and about. At most 100 characters. |
| `sort` | `new` (default) or `popular`. |
| `limit` | 1 to 50. Default 20. |
| `cursor` | The `next_cursor` of the previous page. |

An unknown `kind` or `sort`, a `limit` outside 1 to 50, a bad `tag`, a long `q` or a bad `cursor`
answers `400`.

#### Kind

The kind comes from what is inside the kit. Tools that an Imp lists by name count with that Imp, not
as loose tools.

| kind | when |
|------|------|
| `imp` | Exactly one Imp and nothing else at the top level. |
| `animation` | Only top-level animations. |
| `trigger` | Only top-level triggers. |
| `tool` | Only loose tools (MCP servers no Imp lists). |
| `kit` | Anything else. |

#### Kit checks

A kit is checked on the way in with the same limits as Imp. A failed check answers
`422 validation-failed` with up to 25 problems.

| rule | limit |
|------|-------|
| Size, after compacting | At most 512 KB. |
| Kit `name` | Required, 1 to 80 characters. |
| `about` | Text of at most 4000 characters. |
| Content | At least one Imp, trigger, tool or animation. |
| Imps | At most 20. Each needs a name. |
| Triggers | At most 50 at the top level, and at most 50 in each Imp. |
| Tools (`mcpServers`) | At most 20. Names have 1 to 64 characters. |
| Animations | At most 50 per kit, counting those inside Imps. |
| One animation | Name of 1 to 40 characters. 1 to 24 beats. Each beat lasts 0.05 to 6 s. The total is at most 20 s. |
| Animation values | Known moods, glyphs and moves. Other beat fields must be in range. |
| Traits | Each trait must be inside its range. |
| Chats | An Imp must hold none. A chat is private. |
| Tool references | An Imp's `mcpServers` names must exist in the kit's own `mcpServers`. |
| Tool form | A `command` (with optional `args`) or a `url`, never both and never neither. |
| Secrets | Values in `env` and `headers` must be empty strings. |
| Tool `url` | Starts with `https://` or `http://`. No user name or password. No query parameter whose name contains `key`, `token`, `secret`, `password`, `auth`, `sig` or `credential`. |

Items whose kit has a tool with a `command` are marked `runs_programs` and shown with a warning.

The kit is stored compact with sorted keys and served as stored. The `ETag` is the kit's SHA-256 and
its revision. An account can share at most 100 items. A new item beyond that answers
`403 quota-exceeded`.

A summary is one line of 1 to 120 characters. Each item has 1 to 5 distinct tags. A tag has 1 to 24
characters from `a-z`, `0-9` and `-`.

### Shapes

Timestamps are RFC 3339 UTC strings.

An item summary has these fields:

`handle`, `slug`, `kind`, `name`, `summary`, `tags`, `runs_programs`, `installs`, `revision`,
`created_at`, `updated_at`.

An item is a summary plus `about`, `sha256` (of the kit text), `size` (bytes), `kit_url` and
`counts` (`{ "imps", "animations", "triggers", "tools" }`).

| call | answer |
|------|--------|
| `GET /challenge` | An ALTCHA challenge, `{ "parameters": {...}, "signature" }`, as the widget wants it. |
| `POST /accounts` | `201 { "handle", "token", "created_at" }` |
| `GET /accounts/{handle}` | `{ "handle", "created_at", "items": [item summary] }` |
| `GET /items` | `{ "items": [item summary], "next_cursor": string or null }`. Pass `next_cursor` back as `cursor`. |
| `GET /items/{handle}/{slug}` | An item. |
| `PUT /items/{handle}/{slug}` | An item. A new one also gets a `Location` header. |
| `GET /stats` | `{ "accounts", "items", "installs", "by_kind": { "imp", "animation", "trigger", "tool", "kit" } }` |

`installs` and `reports` answer `202` with no body. A report `reason` has 1 to 500 characters.

### Errors

The problem `type` is `https://<host>/problems/<name>`. Unknown paths and methods answer with the same
shape.

| name | status | notes |
|------|--------|-------|
| `invalid-request` | 400 | |
| `unauthorized` | 401 | Has `WWW-Authenticate: Bearer`. |
| `forbidden` | 403 | |
| `quota-exceeded` | 403 | |
| `not-found` | 404 | |
| `method-not-allowed` | 405 | |
| `handle-taken` | 409 | |
| `payload-too-large` | 413 | Body over 600 KB. |
| `unsupported-media-type` | 415 | |
| `validation-failed` | 422 | Adds `"errors": [{ "pointer", "detail" }]`, with JSON pointers into the request. |
| `challenge-failed` | 422 | |
| `rate-limited` | 429 | Has `Retry-After`. |
| `internal` | 500 | Never shows internals. |
| `timeout` | 503 | |

### Previews

Nothing is rendered on the server. An Imp is a hue, a scale and a few traits, and an animation is a
list of beats. So the browser draws and plays both from the kit's JSON, as the apps do. This keeps the
Den small and leaves no image pipeline to attack.

### Stats and caching

- Installs are counted at most once per item per client address per day. They are gathered in memory
  and written in batches every minute. Popularity lags by about a minute and costs no write per
  request.
- Lists, item details, account pages and stats are cached for 30 seconds (`Cache-Control: public,
  max-age=30`).
- Kits are cached by revision (`ETag`, `Cache-Control: public, max-age=300`). A matching
  `If-None-Match` answers `304`.

### Abuse limits

Per-IP limits use the IPv4 address or the IPv6 /64.

| what | limit |
|------|-------|
| Reads (lists, items, kits, accounts, stats and every token check) | 240 per minute per IP |
| Challenges | 20 per minute per IP |
| Account creation attempts | 20 per minute per IP |
| Accounts created | 3 per day per IP |
| Reports | 10 per hour per IP |
| Installs | 120 per hour per IP |
| Writes (publish, delete item, delete account) | 30 per hour per account and 30 per hour per IP |
| Items | 100 per account |

Other protections:

- ALTCHA on account creation, single use and short lived.
- An item reported from 5 different IPs is hidden until an operator looks at it. The operator uses
  `den admin` on the server. There is no HTTP admin surface.
- `X-Forwarded-For` is honoured only when the connection comes from a configured proxy
  (`DEN_TRUSTED_PROXIES`).

### MCP

`/mcp` is a stateless MCP server: Streamable HTTP, protocol revision `2026-07-28`, JSON responses, no
sessions. The Host and Origin headers are checked against the Den's public address.

| tool | what |
|------|------|
| `search_items` | Same as `GET /items`. |
| `get_item` | Same as `GET /items/{handle}/{slug}`. |
| `get_kit` | The kit JSON of an item. |
| `get_challenge` | A challenge, plus instructions to solve it. |
| `create_account` | Same as `POST /accounts`. |
| `publish_item` | Same as `PUT /items/{handle}/{slug}`. Takes `handle`, `slug`, `summary`, `tags` and `kit`. |
| `delete_item` | Same as `DELETE /items/{handle}/{slug}`. Returns `{ "deleted": true }`. |

Writes take the account token in the MCP client's `Authorization` header, exactly as the REST API
does. A failed tool call returns the same problem document as the REST API.
