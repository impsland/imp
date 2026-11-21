# Imp server protocols

This file is the written contract for the two services an Imp server runs. Both come from one Rust
workspace and ship in one Docker image.

| service | purpose | speaks |
|---------|---------|--------|
| Den | A standalone gallery where anyone shares Imps, animations, triggers, tools and kits. | A read-only HTTPS JSON API (plus install and report posts), an MCP endpoint at `/mcp` (the only way to publish), OAuth 2.1 for accounts, a small web gallery. |
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
| Item and kit document | `"format": 1` (an integer) at the top level. | See [Document format](#document-format) and [Compatibility](#compatibility). |
| Chat file | No version field. | Recognised by its `chat` object. |
| Den MCP | Protocol revision `2026-07-28`, older revisions negotiated (see [MCP](#mcp)). | Streamable HTTP, stateless. |
| Den API | `"api": 1` in `GET /version`. | Paths never change meaning. A breaking change gets new paths and a new `api` number. |
| Hop and device link | No version on the wire. | A change an older side would misread changes the labels, so the older side fails cleanly (see `docs/connecting/link.md`). The Hop and the apps are released together. |

Test vectors for the parts that clients share are in `spec/fixtures` (see its `README.md`). The Hop
handshake rules live once, in `engine/src/link/hop.rs`. Both the clients and the relay use that code.
Its tests pin the bytes of a hello and a proof.

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

The hello, nonce, proof and status have fixed sizes and no length prefix. The connection is plain TCP.

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
  place of the nonce. A connection over a per-IP, rate or total limit gets `0x02` before the hello is
  read: at once when its first byte is the hello's, or after 250 ms of silence. One that starts a
  WebSocket upgrade gets it over the WebSocket.
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
   when the room is full gets `0x02`. Guests already waiting stay queued until a place frees up. Then a
   host waiting in that room is spliced at once to the first of them with its gate.

### Host and guest behaviour

A host keeps one waiting connection at the Hop. When it gets `0x00` it runs the Noise handshake as the
responder on that same connection, as it would on one accepted from Wi-Fi. Then it dials a new waiting
connection for the next guest.

A guest does steps 1 to 4, then runs the Noise handshake as the initiator on the same connection. The
Hop is the last route a guest tries, after Bonjour and the addresses in the invite.

### WebSocket

A browser can't open TCP, so the Hop also takes WebSockets on the same port (`server/hop/src/ws.rs`). A
connection whose first byte is `G` is an HTTP request: the Hop answers the WebSocket upgrade, on any path,
then reads it as a stream. Every binary message carries bytes of the same stream a TCP client sends, cut
anywhere. Steps 1 to 5, the status bytes, the rooms and the limits are the same, and a browser and a TCP
client are spliced with each other as two TCP clients are. A text message, or a message over 256 KiB,
closes the connection. The upgrade counts toward the handshake deadline.

An https page may only open `wss://`, so a public Hop is put behind a proxy that ends TLS (see
`server/README.md`). Clients make the WebSocket address from the Hop's `host:port`: `wss://host/` from an
https page (the proxy, on port 443), `ws://host:port/` otherwise. The web page (`web/`) can be given
another address. The limits count a browser by its own address only when the connection comes from a
proxy listed in `HOP_FORWARDED_FROM`. The Hop then reads the last `X-Forwarded-For` entry, the one the proxy
added. From anyone else that header is ignored.

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

All defaults can be changed with the variable shown. Start-up refuses a value of 0 for the limits the config checks (`server/hop/src/config.rs`). The Hop
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
| Proxies that name the browser behind a WebSocket | none | `HOP_FORWARDED_FROM` (addresses or prefixes, comma-separated) |

A live link pings every 20 seconds and is dropped after 45 seconds of silence (`PING_INTERVAL` and
`SILENCE_LIMIT` in `engine/src/link/mod.rs`). So a live session is never idle.

## Den

The Den is a standalone service. The apps carry no Den code: they reach it with the generic MCP client
every Imp already has, as a remote MCP server (`https://<host>/mcp`) added like any other tool (see
[Connecting a client](#connecting-a-client)). Any other MCP host (Claude, ChatGPT, editors, agents) uses
it the same way.

Three interfaces, one database:

| interface | who | can |
|-----------|-----|-----|
| MCP at `/mcp` | Imp and any MCP host | Search, get, download. With an account: publish, delete own items, delete the account. **Publishing happens only here.** |
| HTTPS JSON API | Browsers, scripts, monitors | Read only (search, get, download, accounts, stats), plus counting installs and reporting items. |
| Web gallery at `/` | People | Browse, view (drawn from the JSON), open in Imp, copy JSON, export JSON. |

Base URL: `https://<host>`. Requests and answers are UTF-8 JSON (`application/json`). Request bodies are
limited to 600 KB, and a request that takes over 15 seconds ends with a `timeout` error. Browsers may
call the read API with `GET` and `HEAD` from any origin (CORS). Every answer carries `X-Request-Id`.
Rate-limited answers carry `Retry-After`. An answer with no other cache header carries
`Cache-Control: no-store`.

### Items

There are four item types and the kit. Every one is a small JSON **document** in the kit format the apps
already import (`docs/sharing/kits.md`), with `format` at the top level. One importer reads all of them.

| type | the document holds | size |
|------|--------------------|------|
| `imp` | Exactly one entry in `imps` (with its own animations and triggers inside it), plus the `mcpServers` that Imp lists, and nothing else. | at most 64 KB |
| `animation` | Exactly one entry in `animations`, nothing else. | at most 64 KB |
| `trigger` | Exactly one entry in `triggers`, plus at most the one animation it plays in `animations`. | at most 64 KB |
| `tool` | Exactly one entry in `mcpServers`, nothing else. | at most 64 KB |
| `kit` | A bundle: any of `imps`, `animations`, `triggers`, `mcpServers`, and `skills`. At least one entry. | at most 256 KB |

Every document may also have `name` (1 to 80 characters, required on the Den) and `about` (at most 4000).
Skills are not a type. A kit names them, and Imp never stores or uploads skill files:

```json
"skills": [ { "name": "pdf", "source": "anthropics/skills/skills/pdf" } ]
```

`name` is 1 to 64 characters of `a-z`, `0-9` and inner `-`. `source` is what
`npx skills add <source>` takes: `owner/repo`, `owner/repo/path`, or an `https://` URL, at most 200
characters with no spaces, quotes or shell characters. At most 20 skills per kit. Clients show each
skill with its `npx skills add <source>` command and never run it on their own.

Items are addressed as `{handle}/{slug}`. A slug has 1 to 48 characters and follows the handle rules.
The type is given when publishing and must match the document. A publish whose document does not match
its type answers `422 validation-failed`.

#### Document checks

A document is checked with the same limits as Imp. A failed check answers `422 validation-failed` with up
to 25 problems.

| rule | limit |
|------|-------|
| `format` | Required, an integer the Den supports (see [Compatibility](#compatibility)). |
| Imps | Each needs a name. Traits must be inside their ranges. An Imp holds no chats (a chat is private). |
| Triggers | At most 50 in a document, and at most 50 in each Imp. Each an object with an `on` from the event list, an optional `name` of at most 60 characters, an optional `if` list of objects with a known `state`, and a `do` list of 1 to 5 objects with a known `act`. Unknown events, states and acts fail with a pointer to the field. |
| Tools (`mcpServers`) | At most 20. Names have 1 to 64 characters. A `command` (with optional `args`) or a `url`, never both and never neither. An Imp's `mcpServers` names must exist in the document's own `mcpServers`. |
| Secrets | Values in `env` and `headers` must be empty strings. |
| Tool `url` | `https://` or `http://`. No user name or password. No query parameter whose name contains `key`, `token`, `secret`, `password`, `auth`, `sig` or `credential`. |
| Animations | At most 50 per document, counting those inside Imps. Name of 1 to 40 characters. 1 to 24 beats, each 0.05 to 6 s, at most 20 s in total. Known moods, glyphs and moves. Other beat fields in range. A `starts` field is refused: nothing starts an animation but a trigger's `play` step. |
| Skills | Only in a `kit`. The rules above. |

Items whose document has a tool with a `command`, or a kit with skills, are marked `runs_programs` and
shown with a warning.

The document is stored compact with sorted keys and served as stored. Its `sha256` is taken over that
text.

### Spam and abuse

- **Exact duplicates.** The `sha256` of a stored document is unique across the Den. Publishing a document
  that some visible item already has answers `409 duplicate` with that item's address in `detail` and in
  `existing`. Publishing the same document again to the same item changes nothing and answers `200`
  without a new revision.
- **Quotas per account.** At most 100 items, at most 2 MB of documents in total, at most 20 new items per
  day. Over a quota answers `403 quota-exceeded`.
- **Rate limits** (per IP use the IPv4 address or the IPv6 /64):

| what | limit |
|------|-------|
| Reads (API and MCP reads) | 240 per minute per IP |
| Challenges | 20 per minute per IP |
| Sign-in page posts | 20 per minute per IP |
| Accounts created | 3 per day per IP |
| Client registrations | 20 per hour per IP |
| Token requests | 60 per hour per IP |
| Writes (publish, delete item, delete account) | 30 per hour per account and 30 per hour per IP |
| Reports | 10 per hour per IP |
| Installs | 120 per hour per IP |

- **Reports.** An item reported from 5 different IPs is hidden until the operator looks at it.
- **Operator.** `den admin` on the server (there is no HTTP admin surface) can hide, unhide and remove
  items, and **deactivate**, **reactivate** and **remove** accounts. A deactivated account cannot sign in,
  its tokens stop working at once, and its items are hidden. Removing an account deletes it and everything
  it shared.
- `X-Forwarded-For` is honoured only when the connection comes from a configured proxy
  (`DEN_TRUSTED_PROXIES`).

### Accounts and ownership

An account is a handle. There is no e-mail and no password. The Den is its own OAuth 2.1 authorization
server, as the MCP authorization specification describes, so every MCP host that supports remote servers
can sign in with no Den-specific code.

**Why OAuth and not request signatures.** Per-request signatures (for example Ed25519 over each request,
RFC 9421) keep the private key on the client, but no MCP host can sign requests, so only a client with
Den-specific code could publish and the model could never do it. OAuth 2.1 with PKCE is what MCP hosts
already implement. Its tokens are short-lived, bound to the Den's `/mcp` (RFC 8707), stored by the Den only
as SHA-256 hashes, and revocable. Refresh tokens rotate, and reusing an old one revokes the whole grant.

**The account key** is the only long-lived secret: `dak_` followed by 43 base64url characters (256 random
bits). It is shown once when the account is made and is needed only to connect another MCP host to the
same account. The Den stores its SHA-256.

#### Endpoints

| method | path | what |
|--------|------|------|
| `GET` | `/.well-known/oauth-protected-resource` and `/.well-known/oauth-protected-resource/mcp` | RFC 9728: `{ "resource": "<host>/mcp", "authorization_servers": ["<host>"], "scopes_supported": ["publish"], "bearer_methods_supported": ["header"] }` |
| `GET` | `/.well-known/oauth-authorization-server` | RFC 8414 metadata: `issuer`, `authorization_endpoint` (`/oauth/authorize`), `token_endpoint` (`/oauth/token`), `registration_endpoint` (`/oauth/register`), `revocation_endpoint` (`/oauth/revoke`), `response_types_supported: ["code"]`, `grant_types_supported: ["authorization_code", "refresh_token"]`, `code_challenge_methods_supported: ["S256"]`, `token_endpoint_auth_methods_supported: ["none"]`, `scopes_supported: ["publish"]`. |
| `POST` | `/oauth/register` | RFC 7591 dynamic registration of a public client. Body `{ "client_name", "redirect_uris" }`. Answers `201` with `client_id`. |
| `GET` | `/oauth/authorize` | The sign-in page (below). Takes `response_type=code`, `client_id`, `redirect_uri`, `code_challenge`, `code_challenge_method=S256`, `state`, optional `scope` and `resource`. |
| `POST` | `/oauth/authorize` | The page's form. Redirects to `redirect_uri` with `code` and `state`. |
| `POST` | `/oauth/token` | Form body. `grant_type=authorization_code` (with `code`, `redirect_uri`, `client_id`, `code_verifier`) or `grant_type=refresh_token` (with `refresh_token`, `client_id`). Answers `{ "access_token", "token_type": "Bearer", "expires_in", "refresh_token", "scope" }`. Errors follow RFC 6749 (`invalid_grant` and so on). |
| `POST` | `/oauth/revoke` | RFC 7009. Answers `200`. |

Rules:

- Redirect URIs: `https://` URLs, loopback `http://127.0.0.1`, `http://[::1]` or `http://localhost` with
  any port (RFC 8252), or a private-use scheme with a dot in it (for example `app.imp:/oauth`). Exact match
  at authorize and token time, except that the port of a loopback URI may differ.
- A code lives 60 seconds and works once. PKCE `S256` is required. `plain` is refused.
- Access tokens: `dat_` + 43 base64url characters, valid for 1 hour, audience `<host>/mcp`.
  Refresh tokens: `drt_` + 43 base64url characters, valid for 90 days, rotated on every use.
- Handles have 3 to 32 characters: lowercase letters, digits and inner hyphens. Reserved: `me`, `admin`,
  `root`, `imp`, `den`, `hop`, `system`, `support`.

#### The sign-in page and ALTCHA

A model cannot solve a proof-of-work, so it never sees one. The MCP host opens the sign-in page in a
browser for the person, and deterministic code solves the challenge there:

1. The page names the client (`client_name`) and where it sends the person back (the redirect host).
2. **New account:** the person picks a handle. The page fetches an [ALTCHA](https://altcha.org) v2 challenge
   (PBKDF2-SHA256, signed by the Den) from `GET /challenge` and solves it with the browser's WebCrypto in a
   Web Worker, then posts the handle and the solution. The Den creates the account, shows the account key
   once with a Copy button, and continues to the client.
3. **Existing account:** the person pastes the account key.
4. The page never runs third-party code, sets no cookie and keeps nothing in the browser.

A challenge expires 10 minutes after it is issued, and each solved challenge is accepted once. The
solution is the base64 of `{ "challenge": { "parameters", "signature" }, "solution": { "counter",
"derivedKey" } }`, at most 4096 characters.

How each kind of client gets there:

| client | how the page opens | redirect |
|--------|--------------------|----------|
| Imp on iPhone and iPad (the app is the MCP host) | `ASWebAuthenticationSession`, an in-app browser sheet. | `app.imp:/oauth` |
| Imp on the Mac | `ASWebAuthenticationSession`. | `app.imp:/oauth` |
| Imp in the terminal (`imp`) | The default browser, or the URL printed for the person to open. | A one-shot loopback listener, `http://127.0.0.1:<port>/oauth` |
| Other MCP hosts (Claude, ChatGPT, editors), with or without a shell | The host's own OAuth flow. | Whatever the host registers. |

Nothing in this flow shows a system password or Keychain prompt. Imp keeps the tokens with its API keys:
in a private file by default, in the Keychain only when the person turns that on (see
`docs/sharing/den.md`).

### MCP

`/mcp` is a stateless MCP server: Streamable HTTP, JSON responses, no sessions. The Host and Origin
headers are checked against the Den's public address.

Reads need no account. A write without a valid access token answers HTTP `401` with
`WWW-Authenticate: Bearer resource_metadata="<host>/.well-known/oauth-protected-resource/mcp", scope="publish"`,
which makes the MCP host start the sign-in. A token of a deactivated account answers `401` the same way.

| tool | needs an account | what |
|------|------------------|------|
| `search_items` | no | Arguments: `type` (`imp`, `animation`, `trigger`, `tool`, `kit`), `q` (words, case-insensitive: every word must appear in the name, summary, about or tags), `tag`, `handle`, `sort` (`new`, `popular`, `name`), `limit` (1 to 50, default 20), `cursor`. Answers `{ "items": [summary], "next_cursor" }`. |
| `get_item` | no | `handle`, `slug`. An item with its stats. |
| `download_item` | no | `handle`, `slug`. `{ "item": summary, "document": {...} }`, the document ready to import. Counts one install. |
| `document_format` | no | Optional `type`. The document rules for that type (or every type): what it holds, each field with its allowed values and ranges, and an example that passes. Built from the Den's own checks. |
| `publish_item` | yes | `type`, `slug`, `summary`, `tags`, `document`. Creates the item under the signed-in handle or updates it (revision plus 1). |
| `delete_item` | yes | `slug`. Deletes one of your items. `{ "deleted": true }`. |
| `my_account` | yes | `{ "handle", "created_at", "items": [summary], "quota": { "items", "items_left", "bytes_left", "new_today_left" } }`. |
| `delete_account` | yes | `confirm` must be the handle. Deletes the account and everything it shared, and revokes its tokens. |

A failed tool call returns `isError: true` with the same problem document as the API, so the model can
read `detail`. Search arguments outside their rules answer `invalid-request`. Each tool's input schema names the
allowed values (`enum` for `type` and `sort`, ranges, patterns and lengths), and `document` is a JSON object. An
argument of the wrong JSON type (such as `"limit": "5"`) answers `isError: true` with a message that names it.

**Protocol revision.** The Den fully supports `2026-07-28`, where each request carries the revision and the
client's capabilities in `_meta` with the standard headers (`MCP-Protocol-Version`, `Mcp-Method`, and
`Mcp-Name` for named calls) and there is no `initialize` (SEP-2567). Clients of the older revisions
`2025-11-25` and `2025-06-18` still start with `initialize`: the Den answers it with the revision the client
asked for when it supports it, and otherwise with `2025-11-25`, the newest revision that has an
`initialize`. A client that does not support that answer must disconnect and say which revisions each side
speaks. `serverInfo.version` is the Den's release.

### Read API

| method | path | what |
|--------|------|------|
| `GET` | `/version` | `{ "den": "<release>", "api": 1, "formats": [1], "mcp": ["2026-07-28", "2025-11-25", "2025-06-18"] }` |
| `GET` | `/challenge` | A fresh ALTCHA challenge, `{ "parameters": {...}, "signature" }`. For the sign-in page. |
| `GET` | `/items` | Search. Query: `type`, `q`, `tag`, `handle`, `sort`, `limit`, `cursor`, as for `search_items`. |
| `GET` | `/items/{handle}/{slug}` | An item. |
| `GET` | `/items/{handle}/{slug}/document.json` | The document as stored. Has an `ETag`. |
| `POST` | `/items/{handle}/{slug}/installs` | Counts one install. `202`. |
| `POST` | `/items/{handle}/{slug}/reports` | Body `{ "reason" }`, 1 to 500 characters. `202`. |
| `GET` | `/accounts/{handle}` | `{ "handle", "created_at", "items": [summary] }` (at most 100). |
| `GET` | `/stats` | `{ "accounts", "items", "installs", "by_type": { "imp", "animation", "trigger", "tool", "kit" } }` |
| `GET` | `/healthz` | `200 ok` when the database answers. |

There is no `PUT` or `DELETE` in the API. Any other method on an API path answers `405`.

### Shapes

Timestamps are RFC 3339 UTC strings.

An item **summary**: `handle`, `slug`, `type`, `name`, `summary`, `tags`, `format`, `runs_programs`,
`installs`, `revision`, `created_at`, `updated_at`.

An **item** is a summary plus `about`, `sha256`, `size` (bytes), `document_url`, `open_url` (an
`imp://add?url=...` link that opens it in Imp) and `counts` (`{ "imps", "animations", "triggers",
"tools", "skills" }`).

A summary is one line of 1 to 120 characters. Each item has 1 to 5 distinct tags of 1 to 24 characters
from `a-z`, `0-9` and `-`.

### Compatibility

Every document has `format`, an integer. Format 1 is the one described here.

- Adding an optional field never changes the format. Readers ignore fields they don't know.
- A change an older reader would misread raises the format by one.
- Writers (the apps' export, the Den) always write the newest format they know.
- A reader reads every format up to its own and refuses a newer one. A file without `format` is read as
  format 1 by the apps. The Den requires `format`.
- The Den stores each document in the format it was published in and never rewrites it.

| combination | result |
|-------------|--------|
| App format = document format | Installs. |
| App newer than the document | Installs. The app reads every older format. |
| App older than the document | Refused before anything changes: "This needs a newer Imp. It is kit format 2, and this Imp reads up to format 1. Update Imp and try again." |
| Den older than the document being published | `422 unsupported-format`: "This Den reads kit format 1 at most." |
| Any app, any Den, MCP revisions overlap | Works. |
| MCP revisions don't overlap | The client stops at `initialize` and names both sides' revisions. |
| A breaking change to a tool | The tool gets a new name, and the old one keeps working for at least one release. |

Imp states its format to its model in the description of `imp_add_kit`, so a model can pick items the
Imp can install.

### Errors

Errors use `application/problem+json` (RFC 9457):

```json
{ "type": "https://<host>/problems/rate-limited", "title": "Too many requests", "status": 429,
  "detail": "Try again in 40 seconds." }
```

| name | status | notes |
|------|--------|-------|
| `invalid-request` | 400 | |
| `unauthorized` | 401 | Has `WWW-Authenticate` as above. |
| `forbidden` | 403 | |
| `quota-exceeded` | 403 | |
| `account-deactivated` | 403 | Shown on the sign-in page. |
| `not-found` | 404 | |
| `method-not-allowed` | 405 | |
| `handle-taken` | 409 | |
| `duplicate` | 409 | Adds `"existing": "<handle>/<slug>"`. |
| `payload-too-large` | 413 | |
| `unsupported-media-type` | 415 | |
| `validation-failed` | 422 | Adds `"errors": [{ "pointer", "detail" }]`, with JSON pointers into the document. |
| `unsupported-format` | 422 | |
| `challenge-failed` | 422 | |
| `rate-limited` | 429 | Has `Retry-After`. |
| `internal` | 500 | Never shows internals. |
| `timeout` | 503 | |

### Previews and caching

Nothing is rendered on the server. The browser draws Imps and plays animations from the document's
JSON, as the apps do.

- Installs are counted at most once per item per client address per day, batched in memory and written
  every minute.
- Lists, items, account pages and stats are cached for 30 seconds (`Cache-Control: public, max-age=30`).
- Documents are cached by revision (`ETag`, `Cache-Control: public, max-age=300`). A matching
  `If-None-Match` answers `304`.

### Connecting a client

The mechanism is the MCP client that is built into every Imp app, the same one that runs any other tool.
There is no Den setting.

- **Imp (Mac, iPhone, terminal):** add a tool with the URL `https://<host>/mcp`, in an Imp's Tools, or
  with `imp_add_tool`, or from the gallery's **Add to Imp** link (an `imp://add` link to a one-tool kit,
  reviewed like any kit). The first write opens the sign-in page.
- **Other hosts:** add a remote MCP server with the same URL.

Installing goes through two generic tools. The model calls the Den's `download_item` and then Imp's own
`imp_add_kit` with the document. Imp shows the usual kit review, and **nothing is added until the person
confirms.** Publishing is the reverse: `imp_export_kit` gives the document of an Imp, animation, trigger or
tool, and the Den's `publish_item` shares it. `imp_add_kit` and `imp_export_kit` are tools of Imp on the Mac and
the iPhone. A host without them (the terminal `imp`, other MCP hosts) writes the document by the rules
`document_format` returns, and a person imports a downloaded document as a `.json` file.
