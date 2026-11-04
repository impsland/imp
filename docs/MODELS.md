# Core models

What a new client (Android, Windows, Linux, a server) needs to read and write to work with Imp and
with other Imps. The Swift types in `Sources/ImpKit` are the reference. This page names the shapes
and gives JSON examples. The wire protocols are in [`LINK.md`](LINK.md) (devices) and
[`../server/PROTOCOL.md`](../server/PROTOCOL.md) (Den and Hop). The kit file format is in
[`KITS.md`](KITS.md). Tests that pin the shapes are listed in
[`../Tests/Fixtures/README.md`](../Tests/Fixtures/README.md).

General rules for every JSON in Imp:

- Readers ignore keys they do not know and take a default for a missing optional key.
- UUIDs are upper or lower case hyphenated text. Binary values (keys, tickets, file bytes) are standard
  base64 with padding on the device link, and base64url without padding inside `implink://` addresses.
- Device link messages write dates as seconds since 1970 (a number). Chat files and transcripts use
  ISO 8601 text.
- Numbers are doubles unless a count or an id. Compare parsed values, never text, because key order
  and number spelling are not part of any contract.

## Versions

| thing | version | where it lives | meaning |
|-------|---------|----------------|---------|
| Device link protocol | `2` | `LinkProtocol.version`, `hello` and `welcome`, the invite `v=2` | A side ignores message types it does not know, so a newer peer can add some. |
| Hop handshake | `2` | byte 7 of the hello, `imp-hop/2` proof tag | Changes the handshake bytes. |
| Kit format | `1` to `3` | `"imp"` in a kit | Oldest reader that understands the kit. Writers use the lowest that fits. |
| Den API | `v1` | the `/v1/` path | Added fields are not a new version. |
| Browser bridge | hello `version` (default 1) | extension `hello` | Informational. Unknown messages are ignored. |

## Imp profile (as shared in a kit, `KitImp`)

The shape another person receives when you export an Imp, and the one a new client should store too.
Secrets are never in it (a service is named and given a base URL, the key stays on the owner's device).

```json
{
  "name": "Dawn",
  "hue": 0.1,
  "favoriteHue": 0.62,
  "scale": 1.0,
  "personality": "You are Dawn, a tiny, cheerful morning Imp…",
  "brain": { "model": "gpt-4o-mini", "service": { "name": "OpenAI", "baseURL": "https://api.openai.com/v1" } },
  "shell": false,
  "tools": { "body": true, "senses": true, "setup": false, "troupe": false, "computer": false },
  "toolsOff": ["own.den.den_search"],
  "exchangesSent": 20,
  "sendsToolCalls": true,
  "mcpServers": ["Memory", "Time"],
  "traits": { "lids": 0.2, "slant": -0.5, "eyes": 0.1, "squint": 0, "horns": 10, "blush": 0.3, "tilt": 2, "tempo": 1.2 },
  "triggers": [ { "name": "Plan my morning", "when": { "kind": "wake" }, "do": "ask", "prompt": "…" } ]
}
```

- `hue` is the skin colour from 0 to 1 (red is 0). `scale` is the size, 1 is normal.
- `traits` are the character of the face, each clamped to a range: `lids` 0 to 0.6, `slant` -1 to 1,
  `eyes` -0.4 to 0.4, `squint` -1 to 1, `horns` -30 to 30, `blush` 0 to 1, `tilt` -12 to 12, `tempo`
  0.6 to 1.6. Missing means the neutral value (all 0, `tempo` 1).
- `tools` switches whole groups (`body`, `senses`, `setup`, `troupe`, `computer`). `toolsOff` lists single
  tool ids (see below). `mcpServers` names servers defined in the kit's own `mcpServers` object.
- On the device link the same Imp's looks travel as `LinkImp`: `{ "id", "name", "hue", "scale",
  "traits" }` and nothing else.

## Brain configuration (non-secret parts)

A **service** is an OpenAI compatible endpoint. A **brain** picks a service and a model.

```json
{ "id": "6F1C2E7A-0B52-4C58-9C6B-3C1E8A5D2F10", "name": "OpenAI", "baseURL": "https://api.openai.com/v1", "model": "gpt-4o-mini" }
```

```json
{ "service": "6F1C2E7A-0B52-4C58-9C6B-3C1E8A5D2F10", "model": "gpt-4o-mini" }
```

- `Service.model` is the default model of the service (optional). `Brain.service` is the service id,
  `Brain.model` the model name. An Imp without a brain uses the default brain of the app, except a
  brain saved with `"unchosen": true` (`Brain.notChosen`): a pocket Imp that moved to a Mac with no
  brain. It has no service at all and sleeps until one is picked.
- Whether an Imp can think is one rule on every device (`Wakefulness`): at home its own brain decides,
  and a visitor is awake only while its home is connected and says it has a brain (`brain` in
  `docs/LINK.md`). An Imp that can't think sleeps whatever it is doing, and asking it is refused at once.
- API keys and header values live in the platform's secure storage (Keychain on Apple systems), never
  in these objects and never in a kit. When a pocket Imp moves to a Mac they travel apart as
  `LinkSecrets` inside `adopt`.
- In a kit a brain names its service by value (`{ "name", "baseURL" }`) because ids mean nothing on
  another device.
- Request limits (`RequestLimits`): `timeoutSeconds` (5 to 3600, default 120), `retries` (0 to 10, 3),
  `retryDelaySeconds` (0 to 60, 1), `backoff` (1 to 10, 2). Retry delay and which errors are retried
  are pinned by `Tests/Fixtures/retry-policy.json`.

## Tool entry ids

Every tool an Imp may call has an id, so a group or a single tool can be switched off.

| tool | id | group id |
|------|----|----------|
| built in | `own.<group>.<tool>`, for example `own.body.imp_speak` | `own.<group>` |
| of an MCP server | `mcp.<server>.<tool>`, for example `mcp.files.read_file` | `mcp.<server>` |

`<server>` is the server's name with every character outside letters, digits, underscore and hyphen
turned into an underscore (`My Speech!` becomes `My_Speech_`). The group id is the id without its last
part. A tool is offered when neither its group id nor its own id is switched off. A tool without an id
is never switched off. Calling a tool that is not offered is refused. Vectors:
`Tests/Fixtures/tool-filtering.json`.

## Trigger

A trigger makes an Imp act on its own. In kits and in the `imp_add_trigger` tool arguments:

```json
{
  "name": "Plan my morning",
  "when": { "kind": "wake" },
  "only_if": [ { "kind": "hours", "text": "05:30-11:00" } ],
  "do": "ask",
  "prompt": "Good morning. Check your memory for my goals…"
}
```

- `when` is what starts it: `{ "kind": "wake" }`, `{ "kind": "time", "text": "17:30" }` and the other
  kinds listed by the `imp_add_trigger` tool. `only_if` is a list of conditions that must all hold.
- `do` is the action (`ask` sends `prompt` to the Imp as if typed).
- A kit that holds only triggers is a valid kit of kind `trigger` on the Den.

## Chat turn

One request and its reply, as stored in a chat file (`ChatTurn`):

```json
{
  "id": "0D3A55C8-6C2A-4E0B-8F71-6E4A9D0C1B22",
  "date": "2025-10-09T08:53:20Z",
  "request": "What time is it?",
  "reply": "It is 8:53.",
  "failed": false,
  "via": "typed",
  "steps": [
    { "id": "A1B2C3D4-0000-4000-8000-000000000001", "icon": "clock", "title": "Check the time",
      "request": "{}", "response": "08:53", "failed": false }
  ]
}
```

- `via` (optional) is `typed`, `spoken`, `shortcut`, `recap` or `imp`. A turn asked by another Imp also
  carries a `sender` `{ "id", "name", "hue" }`. Other optional keys exist and are ignored when unknown.
- Over the device link a turn is shortened to `LinkTurn`: `{ "id", "date" (seconds since 1970),
  "request", "from" (the asking Imp's name, optional), "reply", "failed", "steps" (titles only) }`.

## Workspace reference

A path in an Imp's reply is relative to that Imp's Workspace folder. Text that leaves the Imp names
files as:

```
imp-file://<owner-imp-uuid>/<percent-encoded path>?size=<bytes>&sha256=<64 lowercase hex>&type=<mime>#autoplay
```

Rules (what is accepted, what is rejected, how checksums apply) are in the File references section of
[`LINK.md`](LINK.md). Vectors for paths, references and checksums: `Tests/Fixtures/workspace-refs.json`.

## Link message envelope

Every device link message is one JSON object with exactly one key, the message name, whose value is an
object holding the fields (an empty object when there are none). It travels in a frame of a 4-byte
big-endian length followed by that JSON, at most 4 MiB.

```json
{ "ask": { "imp": "00000000-0000-0000-0000-000000000001", "text": "What time is it?" } }
```

```json
{ "ping": {} }
```

- A frame the reader cannot decode (an unknown name, an object with two names, a missing or malformed
  field) is ignored and never answered with an error. Before the handshake is done it closes the
  connection instead.
- Fields that are optional in the Swift enum (`join`, `home`, `ticket`, `work`, `speech`, `from`) are
  absent or `null`.
- Messages with a size or count over a limit decode but are dropped (`LinkMessage.isSound`). Every
  limit is in `LINK.md` and `LinkProtocol`.
- One vector for every message, a few that must be rejected: `Tests/Fixtures/link-messages.json`.

## Browser bridge

The Mac app runs a WebSocket server on `127.0.0.1:47823` for the browser extension. Only connections
whose `Origin` starts with `chrome-extension://`, `moz-extension://` or `safari-web-extension://` are
accepted. Each WebSocket text message is one JSON object with a `type`.

Extension to app:

```json
{ "type": "hello", "browser": "Chrome", "version": 3 }
{ "type": "page", "url": "https://example.com/", "title": "Example" }
{ "type": "located", "id": "q1", "rect": { "x": 10, "y": 20, "width": 100, "height": 30 } }
{ "type": "text", "id": "q2", "text": "Hello page" }
{ "type": "pong" }
```

App to extension:

```json
{ "type": "locate", "id": "q1", "query": "Sign in" }
{ "type": "text", "id": "q2", "limit": 4000 }
{ "type": "troupe", "imps": [ { "name": "Pip", "hue": 0.55, "scale": 1, "traits": {}, "mood": "idle",
                                "away": true, "status": "idle", "device": "iPhone" } ] }
```

- `rect` is in screen points with the origin at the top left of the primary display. `located` without
  `rect` means not found. `id` pairs an answer with its request.
- `status` is `working`, `idle` or `asleep`. An Imp that is away is still run by this Mac, so being away
  never means asleep by itself.
- Missing `browser` reads as `Browser`, missing `version` as `1`, missing `title` or `text` as an empty
  string. An unknown `type`, or a message without its required fields (`url`, `id`), is rejected.
- Vectors: `Tests/Fixtures/bridge-messages.json`.
