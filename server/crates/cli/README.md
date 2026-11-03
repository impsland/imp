# imp, the terminal app

Make Imps and chat with them from a terminal. It talks to any OpenAI-compatible service, including a local one such as Ollama.

## Install

```sh
cargo install --path server/crates/cli
```

This installs a program called `imp`. Run `imp --help` to see what it can do.

## Quick start

```sh
imp imp new pip --model gpt-5          # make an Imp (anything you leave out is asked for)
export IMP_API_KEY=...                 # not needed for a local model
imp chat                               # full-screen chat, Esc leaves
```

Other commands:

- `imp imp list` lists your Imps, and `imp imp remove NAME` removes one.
- `imp config` shows the settings and where each key comes from. `imp config set default_imp pip` changes one.
- `imp config path` prints the settings file's location.
- `imp chat --imp NAME` chats with a specific Imp. Inside a chat, `/clear` starts over and `/quit` leaves.
- `imp chat --plain` uses the simple line chat. It is also used when the input or output is not a terminal, for example in a pipe.

## The full-screen chat

In a terminal, `imp chat` shows the conversation with the reply arriving as it is written. The bottom line shows the Imp, its model and what it is doing, such as "Thinking", "Retrying 2 of 3" or "Using the tool files__read".

- Enter sends. Alt+Enter, Shift+Enter or Ctrl+J adds a new line. Pasting several lines works.
- PageUp and PageDown, the arrow keys up and down and the mouse wheel scroll. End jumps back to the newest line.
- Esc or Ctrl+C leaves. The terminal is put back as it was, also after an error.
- Ctrl+U clears what you typed.

## Settings file

By default it is `config.toml` in the system's config folder for `imp`, such as `~/.config/imp/config.toml` on Linux. Use `--config FILE` or the `IMP_CONFIG` variable to use another one.

```toml
default_imp = "pip"
api_key_env = "IMP_API_KEY"
retries = 3

[imps.pip]
personality = "Friendly, curious and a little mischievous. Keeps answers short."
base_url = "https://api.openai.com/v1"
model = "gpt-5"
# api_key_env = "OTHER_KEY"   # optional, for this Imp only
```

## Tools through MCP servers

An Imp can use tools from MCP servers that run on your computer. The server is started when the chat starts and stopped when it ends. Add servers under the Imp in the settings file. Only the NAMES of environment variables are listed. Their values are read from the environment when the server starts and are never stored.

```toml
[imps.pip]
tools_off = ["mcp.files.delete"]      # tools this Imp must not use, by id

[imps.pip.mcp_servers.files]
command = "mcp-server-files"
args = ["--root", "/home/me/notes"]
env = ["FILES_TOKEN"]
```

Tool ids look like `mcp.SERVER.TOOL` for MCP tools and `own.GROUP.TOOL` for the ones that come with `imp`. Tools in `tools_off` are not offered, and a call to one is refused. When a tool is called, the answer goes back to the model, which can call more tools. `max_steps` (10 by default) limits the model requests for one answer. A server that does not start is reported and skipped. Only servers started by a command are supported so far, not servers reached over HTTP.

## Imps talking to each other

When you have more than one Imp, each can send a message to the others with the `imp_message` tool, as in the Mac and iPhone apps. The other Imp answers with its own model and personality, without tools of its own. The tool id is `own.troupe.imp_message`, so `tools_off` can switch it off.

The tool has an optional `conversation` choice, `new` or `continue`. If the Imp says nothing, the conversation continues when the last message between the two is younger than the window. Conversations are saved per pair of Imps in the data folder (`talks` inside it, or inside `IMP_DATA_DIR` if set). Two settings at the top of the settings file change the rule:

```toml
talk_window_minutes = 60        # default 60, at most 10080
talk_threading = "decides"      # decides (default), recent, always or never
```

## API keys

A key is never printed and never written to the settings file. It is looked up in this order:

1. The environment variable named by the Imp's `api_key_env`, or else the global `api_key_env` (`IMP_API_KEY` by default).
2. The system keychain, where `imp config set-key --imp NAME` saves it (it reads the key from the first line of standard input). `imp config clear-key` removes it.

## Environment variables

- `IMP_API_KEY` holds the API key (the name can be changed in the settings).
- `IMP_CONFIG` is the path of the settings file.
- `IMP_DATA_DIR` is the folder for saved data such as conversations between Imps.

## Be your own server

`imp serve` runs a Den (accounts and shared kits) and a Hop (the relay between linked devices) in one process.

```sh
imp serve                      # Den on http://localhost:8080, Hop on localhost:4677
imp serve --host 0.0.0.0       # let devices on your network reach it
imp serve --den-port 9000 --hop-port 9001 --data-dir ./imp-data
```

It prints where each one listens and what to type into the apps. Data is kept in the usual data folder for `imp`
(or `--data-dir`, or `IMP_DATA_DIR`). The Den's secret is made the first time, kept in the file `den-secret` there
with permissions only you can use, and is never printed. Press Ctrl-C to stop. The server programs in `crates/den`
and `crates/hop` and the Docker image are separate and unchanged.

## QR codes

`imp qr TEXT` draws any text as a QR code (add `--light-terminal` on a light background). `imp qr` alone says why
there is no pairing code yet. The Imp apps scan only a device link invite (`implink://join...`), and the `imp://`
commands have no setting for a server address. A device link invite would be a promise that this program answers as a
linked device, which it cannot do yet, so it shows none.

## Pairing with the apps: what is left

`imp-core` has the link messages and frame codec (`imp_core::link`), checked against the shared vectors in
`Tests/Fixtures/link-messages.json`. Still missing for a real pairing:

- The TLS identity and session layer (`imp-link/2` certificates and PSK, the Ed25519 identity, the hello and welcome proofs).
- A Hop client for waiting at, and dialling through, the relay.
- A link book (trusted devices) and a node that answers messages.
- Then `imp qr` can show a real `implink://join` invite. Until then, an app change would be needed to accept a server code.

## What is coming

Pairing with the apps (`imp qr` can draw any text today, see above) and MCP servers over HTTP.
