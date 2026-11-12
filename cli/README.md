# imp, the terminal app

Make Imps and chat with them from a terminal. It talks to any OpenAI-compatible service, including a local one such as Ollama.

## Install

```sh
cargo install --path cli
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
- `?` (when nothing is typed) or F1 opens a short card that explains every key and what the status line shows. Any key closes it.

The screen follows the same look as the apps, as far as a terminal can. The terminal's own background is the only surface: there are no boxes and no lines between things. Messages are set apart by blank space, and a soft fill marks the message field. Text is in the default colour, hints are dim, and the only colour is the Imp's own mark (`●`) and red for problems. Colours come from `design/tokens.json` through `cli/src/theme.generated.rs`. Set `NO_COLOR` to turn colours off. Nothing is wider than the terminal, down to 36 columns.

The words are in English, Spanish and Simplified Chinese, chosen from `LC_ALL`, `LC_MESSAGES` or `LANG` (English for any other language). They live in `design/strings/cli.json`, and `node design/generate.mjs` writes them to `cli/src/strings.generated.rs`.

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

An Imp can use tools from MCP servers. A server is either a program on your computer, which is started when the chat starts and stopped when it ends, or a service reached over HTTP. Add servers under the Imp in the settings file. Only the NAMES of environment variables and headers are listed. Their values are never stored in that file.

```toml
[imps.pip]
tools_off = ["mcp.files.delete"]      # tools this Imp must not use, by id

[imps.pip.mcp_servers.files]
command = "mcp-server-files"
args = ["--root", "/home/me/notes"]
env = ["FILES_TOKEN"]

[imps.pip.mcp_servers.search]         # a server reached over HTTP
url = "https://mcp.example.org/mcp"
headers = ["Authorization"]
```

A server has a `command` (with `args` and `env`) or a `url` (with `headers`), never both. Imp speaks the Streamable HTTP transport: it posts each message to the address, accepts a JSON answer or an event stream, and keeps the session the server starts. The value of a header is read from the environment variable `IMP_MCP_SERVER_HEADER` (for the example, `IMP_MCP_SEARCH_AUTHORIZATION`), or else from the system keychain, where `imp config set-header search Authorization` saves it (it reads the value from the first line of standard input, such as `Bearer abc123`). It is never printed or written to the settings file.

Tool ids look like `mcp.SERVER.TOOL` for MCP tools and `own.GROUP.TOOL` for the ones that come with `imp`. Tools in `tools_off` are not offered, and a call to one is refused. When a tool is called, the answer goes back to the model, which can call more tools. `max_steps` (10 by default) limits the rounds of tool calls for one answer. After the last one, the model is asked once more for a plain answer. A server that does not start is reported and skipped.

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
- `NO_COLOR` turns the colours off. `LC_ALL`, `LC_MESSAGES` and `LANG` choose the language of the chat screen.

## Be your own server

`imp serve` runs a Den (accounts and shared kits) and a Hop (the relay between linked devices) in one process.

```sh
imp serve                      # Den on http://localhost:8080, Hop on localhost:4677
imp serve --host 0.0.0.0       # let devices on your network reach it
imp serve --den-port 9000 --hop-port 9001 --data-dir ./imp-data
```

It prints where each one listens and what to type into the apps. Data is kept in the usual data folder for `imp`
(or `--data-dir`, or `IMP_DATA_DIR`). The Den's secret is made the first time, kept in the file `den-secret` there
with permissions only you can use, and is never printed. Press Ctrl-C to stop. The server programs in `server/den`
and `server/hop` and the Docker image are separate and unchanged.

## Pairing with the apps

`imp qr` shows a pairing code (`implink://join...`) as a QR code and keeps running as a linked device. Scan it
with Imp on a phone or a Mac to link the two. The code holds this computer's addresses on the local network, and
the Hop to meet at when the devices are on different networks. The link itself (identity, handshake, the book of
linked devices) is the same code the apps use, in `imp-core`. The identity key is never printed. It is kept in the system keychain (the Credential Manager on Windows, the Secret Service on Linux), and the book file in the data folder holds the rest without it. If there is no key store, `imp qr` says so and does nothing else. On a Linux machine with no desktop session, start a Secret Service such as GNOME Keyring first.

`imp qr TEXT` draws any text as a QR code instead, for example a kit address to open on a phone. The code is always drawn in black on white with a quiet zone of four modules, whatever colours the terminal has, so a phone can read it. It uses half-block characters, so the modules are square.
