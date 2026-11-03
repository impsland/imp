# Shared test vectors

Language neutral JSON files that pin behaviour every Imp client must share. The Swift tests read them
now. A client in another language (Rust, Kotlin, C++) reads the same files in its own tests and must
get the same answers. The written contract is in `server/PROTOCOL.md`, `docs/LINK.md` and
`docs/MODELS.md`. These files are its examples and its test.

| file | what it holds | Swift test | a new client does |
|------|---------------|------------|-------------------|
| `link-messages.json` | One frame body for every device link message (`valid`), with the shapes that must be ignored (`unknown`, `malformed`) and ones that decode but break a limit (`unsound`). | `ProtocolVectorTests` | Decodes every `valid` vector, encodes it again and compares parsed JSON values (a vector with `reencodes` encodes to that instead). Rejects the others. |
| `bridge-messages.json` | Browser bridge messages: `outbound` (app to extension, build and compare), `inbound` (decode and compare with `expect`, defaults included) and `invalid`. | `ProtocolVectorTests` | Same idea as above. Only needed by a client that talks to the extension. |
| `retry-policy.json` | `delays`: policy and retry number to wait in seconds. `limits`: stored request limits to clamped values and policy. `errors`: an HTTP status, a transport failure or a cancellation to retryable or not. | `RetryPolicyVectorTests` | Builds the policy from the fields (retries and delay at least 0, multiplier at least 1, `maxDelay` 60 unless given) and checks every case. |
| `tool-filtering.json` | Tool id rules (`own.<group>.<tool>`, `mcp.<server>.<tool>`) and which tools are offered when groups or tools are switched off. | `ToolRegistryTests` | Computes ids and the offered list for every case. |
| `workspace-refs.json` | Workspace path normalisation, `imp-file://` references and checksums. | `WorkspaceReferenceTests` | Resolves and validates every path and reference the same way. |
| `kits/*.json` | Whole kits (Imps, triggers, tools, animations) that must parse. | `DenInstallTests`, `KitTests` | Parses each kit and keeps what it can express. |

Not in a file here: the Hop handshake bytes, keys and signatures. They are pinned by the fixed values in
`Tests/ImpKitTests/HopTests.swift` (derived outside Swift) and by the Rust tests in `server/crates/hop`.

## Rules for vectors

- Compare parsed values, never text. Key order and number spelling (`0.4` or `0.40000000000000002`)
  are not part of the contract.
- Binary values are base64, dates in link messages are seconds since 1970, UUIDs are text.
- A vector is added with the change that adds the message or rule, and its name says what it shows.
- Every `LinkMessage` case needs a `valid` vector. `ProtocolVectorTests` fails when one is missing.
- The files hold no secrets. Keys and proofs in them are made-up patterns.
