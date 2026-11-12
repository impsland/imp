# Imp server protocols

One Imp server runs two services from one Rust workspace and one Docker image:

- **Den**: where Imps keep accounts and share what they make (kits: whole Imps, animations,
  triggers, tools). An HTTPS JSON API at the root, an MCP endpoint, and a small web gallery.
- **Hop**: a blind relay that lets a device reach another device (a host) from anywhere. It
  splices two TCP streams and never sees what they carry.

The Den and the Hop are two separate settings in the apps, and either can be empty or on another
host. The Den address is a URL with `http` or `https`, a host, an optional port from 1 to 65535 and no
path (a bare host name means `https`). The Hop address is `host:port` with no scheme and no path, and the
port is `4677` when left out. The core checks both and gives the same sentence for a wrong address
(`core/src/servers.rs`, vectors in `spec/fixtures/server-addresses.json`). Den features use only the Den
address. Linking and the relay use only the Hop address.

## Formats

| thing | form | notes |
|-------|------|-------|
| Kit and chat file | none | A kit is recognised by its shape, a chat file by its `chat` object (see `docs/sharing/kits.md`). |
| MCP | revision `2026-07-28` | Streamable HTTP. |
| Hop and device link | none | Nothing on the wire carries a version. A change an older side would misread changes the labels, so the older side fails cleanly (see `docs/connecting/link.md`). The Hop and the apps are released together. |

Test vectors for the parts that clients share are in `spec/fixtures` (see its `README.md`). The Hop
handshake rules live once, in `core/src/link/hop.rs`, which both the clients and the relay use. The
bytes of a hello, a proof and every label are pinned by its tests.

## Hop

### Why the Hop can't read anything

Two devices already speak a Noise session (`Noise_IKpsk2`, see `docs/architecture/threat-model.md`) with a
pre-shared key derived from the door key. Over the Hop they speak exactly the same session, end to end.
The Hop only forwards the encrypted bytes. It never holds the door key, the seed or a session key, so it
can't decrypt, alter or forge traffic. Tampering fails the cipher's check and closes the link.

What the Hop does see: the room and the gate (public keys, below), every side's IP address, timing
and volume. Nothing about Imps, chats or files.

### Room and gate

Any device, a Mac or an iPhone, can host. Many devices can join one host.

```
room = Ed25519 public key of the host device's room seed (RFC 8032)              32 bytes
       (the seed is HMAC-SHA256(key: device seed, message: "imp-link hop room"))
seed = HMAC-SHA256(key: doorKey, message: "imp-hop gate")                         32 bytes
gate = Ed25519 public key of seed, the room's guest key                          32 bytes
```

Only the device that holds the room's private key can wait as host. Every invited guest can derive
the guest key from the door key, so guests prove themselves with the gate key and nothing else: a
guest can join but can never wait as host, so it can't hijack the room. The Hop never sees the seed.

A host names its gate in its hello and signs it. A guest is only spliced to a waiting host whose gate
is the guest's gate.

### Wire format

All integers are single bytes. A connection is plain TCP.

```
1. client -> hop   hello    "IMPHOP" (6 ASCII bytes), role, room (32), gate (32)                 71 bytes
2. hop -> client   nonce    32 random bytes
3. client -> hop   proof    Ed25519 signature (64 bytes, verified strictly) of:
                              host:  "imp-hop proof" (13 ASCII bytes) || 0x01 || nonce || gate, by the room key
                              guest: "imp-hop proof" (13 ASCII bytes) || 0x02 || nonce || room, by the gate key
4. hop -> client   status   1 byte
5. both ways       the link's own Noise bytes, until either side closes
```

Roles: `0x01` host (owns the room and waits), `0x02` guest (joins).

Status:

| byte | meaning | client does |
|------|---------|-------------|
| `0x00` | go: the other side is spliced in | start the Noise handshake |
| `0x01` | rejected: bad hello or proof, or a gate that doesn't match the waiting host's | give up on the Hop for this pairing |
| `0x02` | busy: a limit was hit | back off, try later |
| `0x03` | nobody came: the wait ran out, or a newer host replaced this one | host: wait again. guest: try other routes, then back off |

The Hop closes the connection after any status other than `0x00`.

### Rooms

- A room has at most one waiting host connection. A new host hello for the same room replaces the
  older waiter (which gets `0x03`). A host waits at most 5 minutes, then gets `0x03` and dials again.
- A guest that joins a room with a waiting host is spliced to it at once (both get `0x00`) if the
  gates are equal. If they differ, the guest gets `0x01` and the host keeps waiting.
- A guest that arrives with no host waiting waits up to 15 seconds. When a host arrives, the waiting
  guests are looked at in order: those with another gate get `0x01`, the first with the host's gate is
  spliced, the others keep waiting.
- A host connection serves one guest. After a splice the host dials a fresh waiting connection for
  the next guest (client behaviour).
- A room has at most 16 live sessions, so several people can join one device.

### The host's side

A host keeps one waiting connection at the Hop. When it gets `0x00` it runs the Noise handshake as the
responder on that same connection, as it would on one accepted from Wi-Fi, and dials a new waiting
connection for the next guest.

### The guest's side

A guest does steps 1 to 4, then starts the Noise handshake as the initiator on the same connection. The
Hop is the last route a guest tries, after Bonjour and the addresses in the invite.

### Link framing

Inside the Noise session every handshake message and every encrypted chunk is a 2-byte big-endian length and
that many bytes (at most 65 535). A link frame is a 4-byte big-endian length and that many bytes of JSON (at
most 4 MiB), cut into chunks and sealed.

### Pairing link

`implink://join?...&hop=<host>:<port>` adds the Hop to an invite. It's set when the host has a server.

### Limits (defaults, all configurable)

| limit | default | variable |
|-------|---------|----------|
| handshake deadline (steps 1 to 3) | 10 s | `HOP_HANDSHAKE_SECS` |
| concurrent connections per IP (IPv4 address, IPv6 /64) | 64 | `HOP_PER_IP_CONNECTIONS` |
| new connections per IP | 120 per minute | `HOP_PER_IP_PER_MINUTE` |
| all connections | 20 000 | `HOP_MAX_CONNECTIONS` |
| idle session (no bytes either way) | 120 s | `HOP_IDLE_SECS` |
| bandwidth per session, each way | 4 MiB/s | `HOP_BYTES_PER_SECOND` |
| a host waits | 5 min | `HOP_HOST_WAIT_SECS` |
| a guest waits for a host | 15 s | `HOP_GUEST_WAIT_SECS` |
| live sessions per room | 16 | `HOP_ROOM_SESSIONS` |

The Link pings every 20 seconds and drops a link that has been silent for 45, so a live session is never idle.

## Den API

Base: `https://<host>`. JSON in and out (`application/json`), UTF-8. Errors are
`application/problem+json` (RFC 9457):

```json
{ "type": "https://<host>/problems/rate-limited", "title": "Too many requests", "status": 429,
  "detail": "Try again in 40 seconds." }
```

Rate-limited answers carry `Retry-After`. Every answer carries `X-Request-Id`.

### Accounts without sign-up

An account is a handle and a bearer token. Anyone, an Imp included, can create one by solving an
[ALTCHA](https://altcha.org) v2 proof-of-work challenge (PBKDF2-SHA256, signed by the Den and
expiring with `expiresAt`): cheap for one Imp, expensive for a spammer. The `altcha` field is the
base64 JSON payload `{ "challenge": { "parameters", "signature" }, "solution": { "counter",
"derivedKey" } }`. Each solved challenge is accepted once. The token is shown once. The Den stores
only its SHA-256 hash.

| method | path | auth | what |
|--------|------|------|------|
| `GET` | `/challenge` | | a fresh ALTCHA challenge, single use, expires in 10 minutes |
| `POST` | `/accounts` | ALTCHA | `{ "handle", "altcha" }` → `201 { "handle", "token", "created_at" }` |
| `GET` | `/accounts/{handle}` | | the account and its items |
| `DELETE` | `/accounts/me` | token | deletes the account and everything it shared |

Handles: 3 to 32 characters, lowercase letters, digits and inner dashes. Tokens: `den_` and 43
base64url characters. Send as `Authorization: Bearer <token>`.

### Items

An item is a kit, the JSON Imp already exports and imports (`Kit.swift`).
Its kind comes from what's inside: `imp` (one Imp), `animation` (animations only), `trigger`
(triggers only), `tool` (MCP servers only), `kit` (anything else). Items are addressed as
`{handle}/{slug}`.

| method | path | auth | what |
|--------|------|------|------|
| `GET` | `/items` | | list: `kind`, `tag`, `q`, `sort=new\|popular`, `limit` (≤ 50), `cursor` |
| `PUT` | `/items/{handle}/{slug}` | owner | `{ "summary", "tags", "kit" }` → `201` new or `200` updated (revision + 1) |
| `GET` | `/items/{handle}/{slug}` | | details and stats |
| `GET` | `/items/{handle}/{slug}/kit.json` | | the kit itself (what Imp downloads), with `ETag` |
| `DELETE` | `/items/{handle}/{slug}` | owner | `204` |
| `POST` | `/items/{handle}/{slug}/installs` | | `202`: count one install |
| `POST` | `/items/{handle}/{slug}/reports` | | `{ "reason" }` → `202` |
| `GET` | `/stats` | | totals |
| `GET` | `/healthz` | | `200 ok` when the database answers (for monitors) |

Kits are checked on the way in with the same limits as Imp: at most 512 KB, 20 Imps, 50 triggers,
20 tools, 50 animations, 24 beats per animation and 20 s in total, known moods, glyphs and moves,
traits in range, and no secrets (environment and header values must be empty). Items whose kit
runs programs (MCP servers with a `command`) are marked `runs_programs` and shown with a warning.

### Shapes

Timestamps are RFC 3339 UTC strings. An *item summary* is
`{ "handle", "slug", "kind", "name", "summary", "tags", "runs_programs", "installs", "revision",
"created_at", "updated_at" }`. An *item* is a summary plus `"about"`, `"sha256"` (of the kit text),
`"size"` (bytes), `"kit_url"` and `"counts": { "imps", "animations", "triggers", "tools" }`.

| call | answer |
|------|--------|
| `GET /challenge` | an ALTCHA challenge, `{ "parameters": {…}, "signature" }`, as the widget wants it |
| `POST /accounts` | `201 { "handle", "token", "created_at" }` |
| `GET /accounts/{handle}` | `{ "handle", "created_at", "items": [item summary] }` |
| `GET /items` | `{ "items": [item summary], "next_cursor": string or null }`, pass `next_cursor` back as `cursor` |
| `GET /items/{handle}/{slug}` | an item |
| `PUT /items/{handle}/{slug}` | an item, `201` with `Location` when new |
| `GET /stats` | `{ "accounts", "items", "installs" }` |

`installs` and `reports` answer `202` with no body. `q` is a case-insensitive substring match on
name, summary and about. `tag` is exactly one tag. An unknown `kind` or `sort`, a `limit` outside
1 to 50 or a bad `cursor` is a `400`.

The kit is stored compact (keys sorted) and served as stored. The Den removes only a top-level
`"registry"` block. A kit must hold at least one Imp, trigger, tool or animation, and `"chats"` in
an Imp are refused (a chat is private). An Imp's `mcpServers` names must exist in the kit's own
`mcpServers`. A tool is either a `command` (with optional `args`) or an `https`/`http` `url`, never
both. A `url` may not carry credentials or a query parameter whose name suggests a secret (`key`,
`token`, `secret`, `password`, `auth`, `sig`, `credential`). The kind is `imp` for exactly one Imp and
nothing else at the top level, `animation`, `trigger` or `tool` when that is the only top-level
section, `kit` otherwise. Tools an Imp lists by name count with that Imp, not as loose tools.

Handles `me`, `admin`, `root`, `imp`, `den`, `hop`, `system` and `support` are reserved. Slugs follow
the handle rules with 1 to 48 characters. A summary is one line of at most 120 characters, with 1 to 5
tags of `[a-z0-9-]` and 1 to 24 characters each.

### Errors

`type` is `https://<host>/problems/<name>` with one of: `invalid-request` (400), `unauthorized`
(401, with `WWW-Authenticate: Bearer`), `forbidden` (403), `not-found` (404), `method-not-allowed` (405),
`handle-taken` (409), `payload-too-large` (413, bodies over 600 KB), `unsupported-media-type` (415),
`validation-failed` (422, with `"errors": [{ "pointer", "detail" }]` pointing into the request),
`challenge-failed` (422), `quota-exceeded` (403), `rate-limited` (429, with `Retry-After`),
`timeout` (503), `internal` (500, never with internals). Unknown paths and methods answer with the same
shape.

### Previews

Nothing is rendered on the server. An Imp is a hue, a scale and a few traits, and an animation is a
list of beats, so the browser draws and plays both from the kit's JSON, exactly as the apps do.
That keeps the Den small and leaves nothing to attack in an image pipeline.

### Stats and caching

Installs are counted at most once per item per IP per day, gathered in memory and written in
batches every minute. Lists and stats are cached for 30 seconds (`Cache-Control: public,
max-age=30`), kits by revision (`ETag`, `Cache-Control: public, max-age=300`). Popularity lags by a
minute or so and costs no write per request.

### Abuse

- ALTCHA on account creation, single-use and short-lived.
- Per-IP limits (IPv4 address, IPv6 /64): reads 240/min, challenges 20/min, accounts 3/day,
  reports 10/hour, installs 120/hour.
- Per-account and per-IP limits on writes: 30 per hour, 100 items per account.
- An item reported from 5 different IPs is hidden until an operator looks at it
  (`den admin` on the server, no HTTP admin surface).
- `X-Forwarded-For` is honoured only from configured proxies (`DEN_TRUSTED_PROXIES`).

### MCP

`/mcp` is a stateless MCP server (Streamable HTTP, protocol revision 2026-07-28, JSON
responses, Host and Origin checked against the Den's public address). Tools: `search_items`, `get_item`,
`get_kit`, `get_challenge`, `create_account`, `publish_item`, `delete_item`. Writes take the account
token in the MCP client's `Authorization` header, exactly as the REST API does.
