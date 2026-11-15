# Shared test vectors

These language-neutral JSON files pin behaviour that every Imp client must share. Each client reads
the same files in its own tests and must get the same answers. Today the Rust core and the Swift app
read them. A client in another language would do the same.

The written contract is in `spec/PROTOCOL.md`, `docs/connecting/link.md` and `docs/concepts/models.md`.
These files are its examples and its test.

## Files

| file | what it holds | read by | a new client does |
|------|---------------|---------|-------------------|
| `link-messages.json` | Frame bodies of the device link. `valid`: one or more per message. `unknown`: well-formed but not understood, so ignored. `malformed`: not a valid message, also ignored. `unsound`: decodes but breaks a size limit, so the node drops it. | `engine/tests/link_vectors.rs` | Decodes every `valid` vector, encodes it again and compares parsed JSON. A vector with `reencodes` must encode to that value instead. Treats the other three groups as described. |
| `link-invites.json` | Pairing codes (`implink://join?...`). `valid`: a `url`, what it holds (`expect`) and the text written back (`canonical`). `invalid`: codes every client must refuse. | `engine/tests/link_vectors.rs` | Reads each `valid` code into the `expect` values, writes it back to `canonical`, and refuses every `invalid` one. |
| `bridge-messages.json` | Messages between the Mac app and the browser extension. `outbound`: app to extension. `inbound`: extension to app. `invalid`: inbound messages to reject. | `ProtocolVectorTests` (Swift) | Builds each `outbound` message and compares it. Decodes each `inbound` message and compares it with `expect` (defaults included). Rejects `invalid`. Only needed by a client that talks to the extension. |
| `retry-policy.json` | `delays`: a policy and a retry number, with the wait in seconds. `limits`: stored request limits, the clamped values and the resulting policy. `errors`: an HTTP status, a transport failure or a cancellation, and whether it is retried. | `engine/src/retry.rs` (unit tests), `RetryPolicyVectorTests` (Swift) | Builds the policy from the fields and checks every case. Clamping rules: retries and delay at least 0, multiplier at least 1, `maxDelay` 60 unless given. |
| `tool-filtering.json` | `ids`: how tool ids are built (`own.<group>.<tool>`, `mcp.<server>.<tool>`). `cases`: which tools are offered when groups or tools are switched off. | `engine/src/tools.rs` (unit tests), `ToolRegistryTests` (Swift) | Computes ids and the offered list for every case. |
| `workspace-refs.json` | Workspace path normalisation, path checks, `imp-file://` references and SHA-256 checksums. Groups: `normalize`, `paths`, `refs`, `checksums`, with a shared `owner` and `root`. | `engine/src/workspace.rs` (unit tests), `WorkspaceReferenceTests` (Swift) | Resolves and validates every path and reference the same way. `null` means rejected. |
| `server-addresses.json` | The Den address (a URL) and the Hop address (`host:port`) a person types. Groups: `den` and `hop`, each with an `input`, the kept `address` and an `error` sentence or `null`. | `engine/src/servers.rs` (unit tests) | Gives the same address, or the same error sentence, for every input. Empty input is no server, with no error. |
| `kits/*.json` | Eight whole kits (Imps, triggers, tools, animations) that must parse. | `DenInstallTests`, `ServerLiveTests` (Swift) | Parses each kit and keeps what it can express. |

The Swift tests are in `apple/Tests/ImpKitTests`. `ServerAddressesTests` does not read
`server-addresses.json`. It covers the Swift side of the same checks, and the vectors run in the core.

`ProtocolVectorTests` (Swift) reads only `bridge-messages.json` now. The link vectors are checked by the core.

`ServerLiveTests` publishes the kits to a real Den. It runs only when `IMP_SERVER` is set.

## Not in a file here

The Hop handshake bytes, keys and signatures are not stored here. They are pinned by the tests in
`engine/src/link/hop.rs`, which the Hop relay and every client use, and by the relay's tests in `server/hop`.

## Rules for vectors

- Compare parsed values, never text. Key order and number spelling (`0.4` or `0.40000000000000002`)
  are not part of the contract.
- Binary values are base64. Dates in link messages are seconds since 1970. UUIDs are text.
- Add a vector in the same change that adds the message or rule. Its name says what it shows.
- Every `LinkMessage` case needs a `valid` vector. `engine/tests/link_vectors.rs` fails when one is missing.
- The files hold no secrets. Keys and proofs in them are made-up patterns.
- Do not add a version field to `link-messages.json`. The core test checks that none exists.
