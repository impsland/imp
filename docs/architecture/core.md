# How the apps reach the core

The Mac and iPhone apps call `imp-engine` through `imp-ffi`, a small crate that exports plain records
and functions with [UniFFI](https://github.com/mozilla/uniffi-rs) 0.32 (proc-macro mode, no UDL).
UniFFI writes the Swift bindings from the built library. The same crate could give Kotlin bindings for
Android, and Windows and Linux could reach the core through a C ABI. Neither app exists yet.

## The build

`apple/scripts/apple.sh core` (run by `make core`, and by the app targets such as `make build`, `make test` and `make ios`):

1. builds `imp-ffi` as a static library for each slice it is asked for (`mac`, `mac-universal`,
   `ios-sim`, `ios`) with the toolchain in `rust-toolchain.toml`,
2. writes the Swift bindings to `apple/Sources/ImpCore/ImpCore.swift`,
3. packs the libraries and the C header into `apple/Frameworks/ImpCoreFFI.xcframework`.

Both outputs are generated and not committed. `apple/Package.swift` has a binary target
(`ImpCoreFFI`) and a Swift target (`ImpCore`) on top of it, and `ImpKit` depends on `ImpCore`.
Local builds use the `apple-dev` profile, which rebuilds quickly. `make dist` and `make ios-device`
use `release`.

The script uses rustup's toolchain explicitly. A `cargo` from another source (for example Homebrew)
earlier on `PATH` has no Apple mobile targets.

## No I/O in the apps' core

`imp-engine` has an `io` feature with the parts that reach the network and other processes: the
OpenAI-compatible HTTP client, the stdio and HTTP MCP transports and the driver that runs the agent loop
over them.
The command line app turns it on. `imp-ffi` and the Hop leave it off. The apps' core therefore has no HTTP
or TLS stack, and the apps do their own I/O through the system (URLSession, Network.framework). CI lints and
tests the core both ways.

The MCP protocol itself needs no I/O and is always built (`engine/src/mcp/protocol.rs`): the JSON-RPC
messages, how answers and tool lists are read, how tools are named, and the Streamable HTTP headers. The
apps call it through `imp-ffi` and only move the messages (a child process, URLSession). The command line
transports call the same functions. Over HTTP the client first asks `server/discover` for the stateless
revision `2026-07-28`, where every request carries the revision in `_meta` and in the `MCP-Protocol-Version`,
`Mcp-Method` and `Mcp-Name` headers, and there is no session. A server that refuses discovery gets the
`initialize` handshake (`2025-11-25`, or an older revision the server picks). A child process always gets
the handshake. When a handshake server started a session, the client ends it with a DELETE.

Streamed answers carry the model's reasoning as its own event (`StreamEvent::Reasoning`, and `reasoning` on
the reply). It is read from `reasoning`, `reasoning_content` or the `reasoning.text` and `reasoning.summary`
entries of `reasoning_details` (never twice when both are sent), and from a `<think>…</think>` block at the very
start of the text (`ThinkSplitter`, which copes with tags split across chunks). Reasoning is for showing only:
it is never put in the messages a request carries.

The rest of a chat works the same way. These need no I/O, and both the apps and the command line use them:

- **The agent loop** (`engine/src/agent.rs`) is a step machine. It says what to ask the model next and which
  tools to run, and it adds each answer to the chat. It also stops after the step limit, then asks once
  more for a plain answer. A tool answer that starts with `Error:` counts as failed. Pictures from tools
  follow as one user message. The apps and the command line do only the requests and run the tools.
- **Model requests** (`engine/src/chat.rs`): the request body, the reply, the model list and the error
  sentence a service sends back.
- **Chat memory** (`engine/src/memory.rs`): which exchanges the model sees, how a recap covers older ones,
  the long-chat notice and the chat title.
- **Built-in tools** (`engine/src/tools.rs`): one list gives each tool its name, its id and its group. The
  apps run a tool by its core name and never spell one themselves.
- **What Imps say to each other** (`engine/src/troupe.rs`): the `imp_message` tool's words and schema, and the
  turn an Imp gets when another Imp messages it. What only one app has (a speech bubble, file links) is an
  option, so the words are written once.
- **Adding an MCP server** (`engine/src/mcp/setup.rs`): pasted setup text (a JSON config, an address or a
  command line), the names suggested for it, MCP config files, and command lines read and written as a
  shell does.
- **The `.agents/` layout** (`engine/src/agents.rs`): front matter, agent and skill files, the instructions and
  skills in the system text, the `use_skill` tool, `${NAME}` values and the digest of what a project asks to
  be trusted. The command line app reads the folders. An app that adds `.agents/` reuses these rules.
- **Custom commands** (`engine/src/custom.rs`): finding the command a typed line names, how the list words it, the
  plan for a run (the filled-in text in pieces: plain text, a command line, a file) and putting the pieces
  together again. Each app runs the command lines and reads the files behind its own permission rules. The Mac
  and iPhone chats get the plan, the skills' system text and the `use_skill` tool through `engine/ffi/src/library.rs`.
- **Chat memory** is used by the command line app too: it keeps the core's `ChatMemory` beside the chat it
  shows, so a long terminal chat is clipped, recapped (`/compact`) and noticed the same way as in the apps.

## Measurements

Measured on an Apple silicon Mac with Rust 1.99.1, Xcode 27.2, release profile, linked with
`-dead_strip` into a small Swift program and stripped.

| What is linked | Binary size added | Launch time added |
|---|---|---|
| Logic only (retry policy, tool selection) | 1.07 MB | 0.4 ms |
| Logic plus the HTTP client (reqwest, rustls, tokio) | 3.97 MB | 1.2 ms |

- The first call into the core took 0.02 ms (logic) and 1.9 ms with a new async runtime.
- The static archive itself is about 40 to 92 MB, because it carries every object file. The linker keeps
  only what is called, so the archive size does not reach the app.
- A clean release build takes about 2.5 minutes per target on this Mac. A clean `apple-dev` build of
  the Mac slice takes about 1.5 minutes. A build with nothing changed takes about 8 seconds.
- Rust 1.99.1 from rustup has `aarch64-apple-darwin`, `x86_64-apple-darwin`, `aarch64-apple-ios` and
  `aarch64-apple-ios-sim`. The Simulator build is arm64 only, because Xcode runs only on Apple silicon.

## The decision

UniFFI with a static XCFramework, and no I/O in the apps' core.

- **Chosen:** UniFFI. It writes Swift and Kotlin from one Rust source, so no binding is written by hand.
  The cost is about 1 MB and well under a millisecond at launch.
- **Rejected:** a hand-written C header with `cbindgen`. It needs hand-written Swift and Kotlin
  wrappers, which would be a second copy of every signature.
- **Rejected:** a dynamic framework. It adds load time at launch and an embedding step for the iPhone
  app, and gives nothing back for a library only Imp uses.
- **Rejected:** the HTTP client in the apps' core. It would add about 3 MB, and the system networking
  already handles proxies, VPNs, cellular rules and certificate trust the way the user expects.
