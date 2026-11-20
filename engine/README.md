# imp-engine

The portable logic every Imp platform shares. It holds the device link (identity, handshake, tickets, and the
book of linked devices), the retry policy, tool filtering, workspace paths, an MCP client, and an
OpenAI-compatible chat client with the agent loop that runs tools.

It is the core of [`imp-chat`](https://crates.io/crates/imp-chat), the `imp` terminal app, and of the Mac and
iPhone apps in [impsland/imp](https://github.com/impsland/imp).

How the apps reach the core: [docs/architecture/core.md](../docs/architecture/core.md).

## Install

```toml
[dependencies]
imp-engine = "1"
```

## Features

| Feature | Default | What it adds |
| --- | --- | --- |
| `io` | yes | The parts that reach the network and other processes: the OpenAI-compatible client, the stdio and Streamable HTTP MCP transports, and the agent loop that runs them. |

Turn default features off for the pure logic. The Hop server does this. The apps reach the logic through
`imp-ffi` (the `engine/ffi` crate), which does their own I/O.

## Modules

| Module | What it holds |
| --- | --- |
| `agent` | The agent loop as a state machine that does no I/O, and `run_agent` with the `io` feature. |
| `agents` | The shared `.agents/` layout: front matter, Imps, skills, and the system text. |
| `chat` | The OpenAI-compatible `chat/completions` client, streaming, and tool calls. |
| `config` | `imp.json` and `auth.json`: reading, merging, checking and writing them, the permission rules, and project folder trust. |
| `link` | The device link: identity, the Noise session, the Hop, invites, the book, and Imps travelling between devices. |
| `local_brain` | Finding a model server on the local network. |
| `mcp` | MCP protocol rules (`protocol`), setup parsing (`setup`), and the transports (`client` and `http`, with `io`). |
| `memory` | What an Imp remembers of one chat and sends the model. |
| `retry` | The retry policy and the request limits. |
| `servers` | Checks the Hop address a person types, and the default Hop. |
| `talk` | Messages from one Imp to another and the conversations they make. |
| `tools` | Built-in tool ids and which tools are offered. |
| `troupe` | The `imp_message` tool and the turn an Imp gets when another Imp messages it. |
| `workspace` | Workspace file references and path rules. |

## Test

```sh
cargo test -p imp-engine
cargo test -p imp-engine --no-default-features --locked   # the pure logic, as the Hop and the apps build it
```

The live API tests in `tests/live.rs` and `tests/live_troupe.rs` are opt-in. They read the
`.env` file at the repository root, which sets `OPENAI_BASE_URL`, `OPENAI_API_KEY` and `OPENAI_MODEL`. Run them with:

```sh
IMP_LIVE_TESTS=1 cargo test -p imp-engine --test live -- --nocapture
```

## License

Licensed under MIT.
