# Testing

Every check in the repository runs from the `Makefile` at the root. CI runs the same commands
(`.github/workflows/ci.yml` for the Apple apps, `.github/workflows/server.yml` for the Rust workspace).

## Everyday commands

| Command                 | What it does                                                                  |
| ----------------------- | ----------------------------------------------------------------------------- |
| `make test`             | All Swift tests on the Mac, the screen snapshots included                     |
| `make snapshots`        | Only the screen snapshots (`apple/Tests/ImpSnapshotTests`)                    |
| `make snapshots RECORD=1` | Record the snapshot images again                                            |
| `make rust`             | Format check, lint (`clippy -D warnings`) and tests for the Rust workspace    |
| `make tokens-check`     | Fail when a generated design file is out of date (see [Design](/design/))     |

CI also runs `node design/generate.mjs --check` and `make build`. It builds the iPhone app for the Simulator too.

## Live tests (real services)

| Command                     | What it does                                                              |
| --------------------------- | ------------------------------------------------------------------------- |
| `make test-live`            | Calls the real API configured in `.env`: chat, tools, recaps, pictures and speech through MCP. **Costs a few cents.** |
| `make test-server`          | Plays a Mac, an iPhone and an Imp against a running Den and Hop           |

`make test-server` reads two variables, with these defaults:

- `IMP_SERVER=http://localhost:8080`, the Den's URL.
- `IMP_HOP=localhost:4677`, the Hop's host and port.

## The iPhone app

| Command                          | What it does                                                        |
| -------------------------------- | ------------------------------------------------------------------- |
| `make ios`                       | Builds the iPhone app for the Simulator (needs XcodeGen)            |
| `make ios-snapshots-build`       | Builds the iPhone's snapshot tests without running them             |

Running the iPhone snapshot tests needs the Simulator, so they run on a developer machine. `make ios-snapshots-build`
only checks that they compile.

## Where the tests live

- `apple/Tests/ImpKitTests`: the logic in `ImpKit` (agent loop, tools, MCP, kits, link).
- `apple/Tests/ImpDesignTests`: the shared look (tokens, contrast, layout, generated files).
- `apple/Tests/ImpTests`: the Mac app's own paths that need its models and views.
- `apple/Tests/ImpSnapshotTests`: reference images of the main screens and their key states.
- `apple/iOS/SnapshotTests`: reference images of the iPhone's screens.
- `spec/fixtures`: the JSON vectors every client reads (protocol messages, tool filtering, retry policy, workspace paths).
- `core/` and `server/`: Rust tests, run by `make rust`.
