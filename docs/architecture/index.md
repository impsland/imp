# Architecture

Imp is one product on every platform. Its code has three layers, and each piece of code belongs to
exactly one of them.

| Layer | What it holds | Where |
|---|---|---|
| Portable core | Protocol messages, the link, tool selection, retry policy, workspace paths, MCP, the agent loop and chat state. No UI. Network and process code sits behind the `io` feature, which the apps leave off. | `engine/` (Rust, `imp-engine`) |
| Platform adapters | Secure key storage, sockets and TLS, files, speech, notifications, windows and input, sensors and power. They translate between the system and the core. | in each platform folder |
| Native UI | SwiftUI on Apple, the browser extension, and the terminal UI of the CLI. Planned: Jetpack Compose on Android, WinUI 3 on Windows and GTK 4 on Linux. | in each platform folder |

An adapter or a view never holds a rule of its own. When a platform needs a rule, it asks the core.

## Repository layout

```text
engine/        imp-engine, the portable core (Rust)
engine/ffi/    imp-ffi, the bindings the apps call the core through (UniFFI)
chat/          imp, the command line app
server/        the Den (den/, a standalone MCP service), the Hop (hop/) and their shared code (shared/), with the Docker files
spec/          PROTOCOL.md and fixtures/, the JSON vectors every platform passes
apple/         the Mac and iPhone apps: Package.swift, Sources/, Tests/, iOS/, Resources/, scripts/
extension/     the browser extension
docs/          this site
```

The Rust crates form one workspace (`Cargo.toml` at the root, toolchain in `rust-toolchain.toml`).
New platforms get their own folder next to `apple/`.

## Shared behavior

The vectors in `spec/fixtures` describe behavior that every platform shows. The core's own tests read
them, and so does every platform test that shows the same behavior. A platform that calls the core for
a rule does not need a second copy of the rule, so the vectors mainly guard the core and the edges
where a platform reads or writes data.

Read next: [How the apps reach the core](./core).
