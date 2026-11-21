# Testing

The everyday checks run from the `Makefile` at the root. CI runs the same commands for the Apple apps
(`.github/workflows/ci.yml`) and for the Rust workspace (`.github/workflows/server.yml`).

## Everyday commands

| Command                   | What it does                                                               |
| ------------------------- | -------------------------------------------------------------------------- |
| `make test`               | All Swift tests on the Mac, the screen snapshots included                  |
| `make snapshots`          | Only the screen snapshots (`apple/Tests/ImpSnapshotTests`)                 |
| `make snapshots RECORD=1` | Records the snapshot images again                                          |
| `make rust`               | Format check, lint (`clippy -D warnings`) and tests for the Rust workspace |
| `make tokens-check`       | Fails when a generated design file is out of date (see [Design](/design/)) |

CI also runs `node design/generate.mjs --check` and `make build` (the debug Mac app). A separate CI job
builds the iPhone app for the Simulator.

## Live tests (real services)

| Command           | What it does                                                                                                   |
| ----------------- | -------------------------------------------------------------------------------------------------------------- |
| `make test-live`  | Calls the real API configured in `.env`: chat, tools, recaps, pictures and speech through MCP. **Costs a few cents.** |
| `make test-server` | Runs the Hop tests against a running Hop|

`make test-server` reads one variable:

| Variable     | Default                             | Meaning                                                    |
| ------------ | ----------------------------------- | ---------------------------------------------------------- |
| `IMP_HOP`    | `<LocalHostName>.local:4677`        | The Hop's host and port, using this Mac's `.local` name    |

Don't use `localhost` for `IMP_HOP`. A linking code never gives out a loopback Hop, so the Hop tests would find no route.

### Running the server tests

1. Start a Hop (`imp serve`, or see `server/README.md`).
2. Start the Hop with `HOP_PER_IP_PER_MINUTE=100000` so repeated runs stay under its rate limit.
3. Run the tests:

   ```sh
   make test-server IMP_HOP=<LocalHostName>.local:4677
   ```

The Hop tests are in Rust (`chat/tests/hop_live.rs`).

## The iPhone app

| Command                    | What it does                                                             |
| -------------------------- | ------------------------------------------------------------------------ |
| `make ios`                 | Builds the iPhone app for the Simulator (needs XcodeGen)                 |
| `make ios-snapshots-build` | Builds the iPhone's snapshot tests without running them                  |

Running the iPhone snapshot tests needs the Simulator, so they run on a developer machine. `make ios-snapshots-build`
only checks that they compile.

The playful camera (`testPlayfulCamera`, `testChatTakeAPhotoOpensTheImpCamera`) needs the phone's real camera and its permission
prompt, so it only runs on a device; its geometry (`CameraGeometryTests`) runs with `swift test`.

The UI tests (`apple/iOS/UITests`, scheme `ImpPhoneUITests`) drive the app on a real iPhone: they hatch Imps, set a
Brain, change the look and the tools, go through Settings and keep a screenshot of every screen. They run in a sandbox
of Imps of their own (`-uiTestSandbox`, debug builds only), emptied when each test starts and ends: the phone owner's
Imps are never shown, changed or deleted. The Brain is any OpenAI-compatible server on your Mac, passed in `IMP_TEST_BRAIN` (without it the
Brain steps are skipped):

```sh
TEST_RUNNER_IMP_TEST_BRAIN="http://$(scutil --get LocalHostName).local:8799/v1" \
  xcodebuild test -project apple/iOS/ImpPhone.xcodeproj -scheme ImpPhoneUITests -destination 'id=<UDID>' \
  DEVELOPMENT_TEAM=<Team ID> -allowProvisioningUpdates -resultBundlePath build/ui.xcresult
xcrun xcresulttool export attachments --path build/ui.xcresult --output-path build/ui
```

## Where the tests live

- `apple/Tests/ImpKitTests`: the logic in `ImpKit` (agent loop, tools, MCP, kits, link).
- `apple/Tests/ImpDesignTests`: the shared look (tokens, contrast, layout, generated files).
- `apple/Tests/ImpTests`: the Mac app's own paths that need its models and views.
- `apple/Tests/ImpSnapshotTests`: reference images of the main screens and their key states.
- `apple/iOS/SnapshotTests`: reference images of the iPhone's screens.
- `apple/iOS/UITests`: the iPhone's settings, end to end on a device.
- `spec/fixtures`: the JSON vectors every client reads (protocol messages, tool filtering, retry policy, workspace paths).
- `engine/` and `server/`: Rust tests, run by `make rust`.
