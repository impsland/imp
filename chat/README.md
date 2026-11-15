# imp, the terminal app

Make Imps and chat with them from a terminal. An Imp talks to any OpenAI-compatible service (OpenRouter,
OpenAI, a local one such as Ollama), uses tools from MCP servers, messages your other Imps, and travels to
your Mac and iPhone and back, as in the apps.

## Install

```sh
cargo install imp-chat
```

This installs a program called `imp` from [crates.io](https://crates.io/crates/imp-chat). It needs Rust 1.99 or
newer ([rustup](https://rustup.rs)). Run `imp --help` to see what it can do, and the same command again to
update. The tools in the quick start below also need [Node.js](https://nodejs.org) for `npx`.

To build the version in a checkout of this repository instead, run `cargo install --path chat --locked`.

## Quick start

An Imp that works with the files of the folder you start the chat in:

```sh
export OPENROUTER_API_KEY=sk-or-...        # never written to a file

imp imp new pip --model openai/gpt-6-luna --api-key-env OPENROUTER_API_KEY
imp mcp add files -- npx -y @modelcontextprotocol/server-filesystem .

cd ~/projects/my-app                        # the folder pip works in
imp chat
```

`imp imp new` asks for anything you leave out. The service address is OpenRouter's
(`https://openrouter.ai/api/v1`) unless you give `--url`. In the server's arguments, `.` and
`${workspaceFolder}` are the folder the chat is started in, so the same settings work in every folder.
The Imp is told that folder too.

Then ask, for example:

```text
› What is this project? Read the README and list the main folders.
⏺ read_text_file(path: "/Users/me/projects/my-app/README.md")
  ⎿ # My app (+41 lines)
⏺ list_directory(path: "/Users/me/projects/my-app")
  ⎿ [DIR] src (+6 lines)
● It's a small web app. The code is in src, the tests in tests …

› Write a TODO.md with the three biggest problems you see.
⏺ write_file(path: "/Users/me/projects/my-app/TODO.md", content: "# TODO…")
  ⎿ Successfully wrote to /Users/me/projects/my-app/TODO.md
```

Everything can also be done inside the chat: `/mcp add files npx -y @modelcontextprotocol/server-filesystem .`,
`/model openai/gpt-6-luna`, `/api_key sk-or-...`. Type `/` to see the commands.

## Commands

| command | what it does |
|---|---|
| `imp chat [--imp NAME]` | The full-screen chat. `--plain` for the line chat, `--offline` to stay off the link |
| `imp imp new [NAME]` | Make an Imp. `--model`, `--url`, `--personality`, `--api-key-env`, `--default` |
| `imp imp list`, `imp imp remove NAME` | List your Imps (`*` is the default one), remove one |
| `imp imp set NAME KEY VALUE` | Change `model`, `base_url`, `personality`, `api_key_env` or `hue` |
| `imp mcp add NAME -- COMMAND [ARGS...]` | Give an Imp an MCP server it starts. `--env VAR` passes a variable on |
| `imp mcp add NAME URL` | An MCP server at an address. `--header NAME` sends a header |
| `imp mcp list`, `imp mcp remove NAME` | List or remove servers. `--imp NAME` for an Imp that isn't the default |
| `imp config` | The settings and where each key comes from. `imp config set default_imp pip` changes one |
| `imp config set-key [--imp NAME]` | Save a key in the system keychain (read from standard input) |
| `imp qr` | Link a Mac or an iPhone: shows a code to scan, then stays online |
| `imp link` | Stay online for your linked devices without a chat |
| `imp serve` | Run the Den and the Hop on this computer |
| `imp qr TEXT` | Draw any text as a QR code |

## What the Imp remembers

The chat shows everything that was said. What the model is sent is the Imp's memory of it, the same as
in the Mac and iPhone apps: the latest exchanges (all of them by default, see `memory_exchanges`), with
long tool results clipped. A message that failed or that you stopped still shows, but is not sent again.
When a chat grows long (`long_chat_tokens`, 250,000 tokens by default) it says so once. `/compact` then
has the model sum up the chat so far; the summary goes in place of everything before the last exchange,
so the chat carries on for less. `/clear` starts over.

## The full-screen chat

In a terminal, `imp chat` shows the conversation with the reply arriving as it is written.

```text
› Ask zed what he thinks of basil.
⇢ zed: What do you think of basil?
  ⇠ Arrr, basil's a fine herb, makes a tomato taste shipshape.
● Zed likes it: he says it makes tomatoes better.

 › Write a message, / for commands, @ for files
● pip · openai/gpt-6-luna · ~/projects/my-app                      Ready · ? help
```

An empty chat shows the Imp in the middle of the screen, with how to start and what the folder adds
(`AGENTS.md · 3 skills`). Who the Imp is, its model and the folder it works in are in the bottom line.

- `›` is what you wrote and `●` is the Imp. `⏺` is a tool it used, with its arguments, and `⎿` is the
  result's first line (or `running…`). `⇢` is a message to another Imp and `⇠` its answer.
- Dim lines are notes from commands and your devices. They are never sent to the model.
- The bottom line shows the Imp, its model, the folder, and what it is doing: `Thinking 3s`,
  `Using the tool read_file`, `Retrying 2 of 3`, `On iPhone`. On a narrow terminal the folder is shortened
  from the left (`…/my-app`), then left out.
- Enter sends. Alt+Enter, Shift+Enter or Ctrl+J adds a line. Pasting several lines works.
- Type `/` to see the commands. Up and Down choose one, Tab or Right puts it in the message, and Enter runs it
  (a command that needs more, such as `/send DEVICE`, is completed instead). Esc closes the list. After a command
  and a space, a line shows how to use it, and fixed choices such as `save` after `/api_key` are listed.
- Left, Right, Home, End (or Ctrl+A, Ctrl+E) move in the message. Alt or Ctrl with Left or Right moves by word.
  Backspace and Delete erase at the cursor, Ctrl+W (or Alt+Backspace) the word before it, Ctrl+U everything.
- Ctrl+P and Ctrl+N bring back what you sent.
- Type `@` to add a file: the folder's files that match what follows are listed (`@main` finds
  `src/main.rs`), and Tab or Enter puts the path in the message. A folder opens to what is in it. When the
  message is sent, each file named with `@` goes with it for the Imp to read (text up to 100 KB, 256 KB
  in all; a folder goes as the list of what is in it). The chat shows `⎿ with notes.txt` under the message.
  Paths with spaces are written `@"my notes.md"`. A word such as `@zed` that is not a path is left alone.
- Drag over the conversation to choose text: it is copied as soon as you let go, and the status line says
  `Copied`. Two clicks copy a word and three a paragraph. Holding the mouse on the top row (or below the
  last one) scrolls while choosing. The marks (`●`, `›`) are left out, and a paragraph that wrapped is
  copied as one line. Ctrl+C copies the chosen text again and Esc lets go of it. The text goes to the
  clipboard with `pbcopy` on a Mac (`wl-copy`, `xclip` or `xsel` on Linux), or, over SSH, through the
  terminal (OSC 52, which iTerm2, kitty, WezTerm, Ghostty, Alacritty and tmux understand). Most terminals still
  offer their own selection while a key is held as you drag (Shift in most, Option in iTerm2).
- PageUp, PageDown, Up, Down (when no list is open) and the mouse wheel scroll. While you read further up,
  new lines arrive below without moving what you are reading, and the status line says `End ↓ latest`.
  End (with nothing typed) or Ctrl+End jumps back to the newest line.
- Esc closes the `/` list, else stops an answer that is arriving, and otherwise leaves. Ctrl+C leaves. The terminal is put back as it
  was, also after an error.
- `?` (when nothing is typed) or F1 opens a card that explains every key. On a short terminal it drops its
  blank lines, takes two columns if the terminal is wide, and else scrolls with Up, Down and the wheel.
- On a short terminal the message field loses its blank rows and the Imp's picture is left out.

`imp chat --plain` is the line chat. It is also used when the input or output is not a terminal, for
example in a pipe. Answers go to standard output and everything else (tool calls, notes) to standard error:

```sh
echo "Summarise notes.txt in one line" | imp chat --plain > summary.txt
```

The look follows the apps as far as a terminal can: no boxes and no lines, the terminal's own background,
and the only colours are the Imp's mark and red for problems. Colours come from `design/tokens.json`
through `chat/src/theme.generated.rs`. Set `NO_COLOR` to turn them off. Nothing is wider than the terminal,
down to 36 columns. The words are in English, Spanish and Simplified Chinese, from `LC_ALL`, `LC_MESSAGES`
or `LANG`. They live in `design/strings/cli.json`, and `node design/generate.mjs` writes them to
`chat/src/strings.generated.rs`.

## Chat commands

Type them in the chat. Changes are saved to the settings file and take effect with the next message.
`//text` sends a message that starts with `/`.

| command | what it does |
|---|---|
| `/help` | List the commands |
| `/clear` | Start the conversation over |
| `/compact` | Sum up the chat so far: the Imp goes on from the summary instead of everything said before (also `/recap`) |
| `/quit` | Leave (also `/exit`) |
| `/model [NAME]` | Show or change the model, such as `/model openai/gpt-6-luna` |
| `/base_url [URL]` | Show or change the service address (an OpenAI-compatible `/v1` root) |
| `/api_key [KEY]` | Show where the key comes from, or use `KEY` until the chat ends |
| `/api_key save KEY` | Use it and keep it in the system keychain. `/api_key forget` removes it |
| `/api_key_env [NAME]` | Read this Imp's key from another environment variable |
| `/personality [TEXT]` | Show or change how the Imp behaves |
| `/imp [NAME]` | List the Imps (and visitors), or talk to another one |
| `/mcp` | List the MCP servers, with their tools or why they did not start |
| `/mcp add NAME COMMAND [ARGS...]` | Add a server the chat starts. `--env VAR` passes a variable on |
| `/mcp add NAME URL` | Add a server at an address. `--header NAME` sends a header |
| `/mcp add {CONFIG}` | Add the servers of a pasted config, such as `{"mcpServers": {...}}`. Only the names of its variables and headers are kept |
| `/mcp remove NAME`, `/mcp reload` | Remove a server, or start them all again |
| `/tools`, `/tools off ID`, `/tools on ID` | List the tools by id, switch one off or on |
| `/settings` | The Imp's settings, its folder and the settings file |
| `/project` | What this folder's `AGENTS.md` and `.agents/` add (also `/skills`, `/agents`) |
| `/project trust`, `/project untrust` | Start the MCP servers of the folder's `.agents/mcp.json`, or stop them |
| `/devices` | Linked devices, the Imps on their screens and the visitors here |
| `/pair` | Show a code to link a Mac or an iPhone |
| `/send DEVICE [IMP]` | Send this Imp (or another) to a linked device |
| `/call [IMP]` | Bring an Imp back from another device |
| `/return [VISITOR]` | Send a visiting Imp back to its home |
| `/trust DEVICE [off]` | Let your Imps use their tools for one of your devices |
| `/forget DEVICE` | End the link with a device |

A key given to `/api_key` is never shown in the chat and never written to the settings file.

## Settings file

By default it is `config.toml` in the system's config folder for `imp` (`~/.config/imp/config.toml` on Linux,
`~/Library/Application Support/imp-chat/config.toml` on a Mac). Use `--config FILE` or `IMP_CONFIG` for another
one. `imp config path` prints it.

On a Mac, `imp` keeps its settings and data in `~/Library/Application Support/imp-chat`, a folder of its own.
Before imp-chat 1.5 it used `~/Library/Application Support/imp`, which is also the Mac app's `Imp` folder (a Mac
ignores case in file names), where the app's Factory Reset would delete them. The first time a newer `imp`
runs, it moves the files it made there (`config.toml`, `link-book`, `link-identity`, `talks` and the rest)
into its own folder and leaves the app's files alone. While an older `imp` is still running, nothing moves
until it ends.

```toml
default_imp = "pip"
api_key_env = "IMP_API_KEY"   # the variable every Imp reads its key from, unless it names its own
retries = 3                   # tries again after a failed request, 0 to 10
max_steps = 10                # the most rounds of tool calls for one answer
memory_exchanges = 0          # how many of the latest exchanges go with each message, 0 for all
long_chat_tokens = 250000     # say a chat is long (and suggest /compact) at this many tokens, 0 never

[imps.pip]
id = "…"                      # made by imp, the same on every device it visits
personality = "Friendly, curious and a little mischievous. Keeps answers short."
base_url = "https://openrouter.ai/api/v1"
model = "openai/gpt-6-luna"
api_key_env = "OPENROUTER_API_KEY"   # optional, for this Imp only
# hue = 0.57                  # its colour on other devices, 0 to 1 (taken from the name if left out)

[imps.pip.mcp_servers.files]
command = "npx"
args = ["-y", "@modelcontextprotocol/server-filesystem", "${workspaceFolder}"]
```

## AGENTS.md and the .agents folder

A chat reads the files that other coding agents read too, from its folder's project: the nearest folder,
from the one you start the chat in up, with a `.agents` folder or a `.git`.

```text
my-app/
  AGENTS.md                       instructions for every Imp working here
  src/AGENTS.md                   more, for a chat started in src/ (read after the one above)
  .agents/
    AGENTS.md                     instructions too
    skills/release-notes/SKILL.md a skill
    agents/pip.md                 the Imp pip, in this folder
    mcp.json                      MCP servers for every Imp here
```

- **AGENTS.md** goes in the system text, after who the Imp is, in the order above (32 KB at most). That
  is where standing rules belong: the model gives the system text the most weight, it holds for the whole
  chat and after `/clear`, and it stays the same from message to message, so services that cache the start
  of a request can reuse it.
- **Skills** follow the [Agent Skills](https://agentskills.io) format: a `SKILL.md` whose front matter has a
  `name` (lowercase letters, digits and dashes) and a `description` of when to use it. Only the names and
  descriptions go in the system text. The Imp gets a tool, `use_skill`, that reads the whole skill and lists
  the files beside it when a task needs it, so many skills cost few words. `/tools off own.skills.use_skill`
  switches it off.
- **agents/NAME.md** is the whole Imp NAME for this folder. The front matter can have `model`, `base_url`,
  `api_key_env: NAME` (or `api_key: ${NAME}`: the environment variable that holds the key, never the key
  itself), `tools` (only these are on: tool names such as `read_file`, ids such as `mcp.files.read_file`, or
  servers such as `mcp.files`), `disallowedTools`, `hue` and `default: true` (the Imp a chat in this
  folder opens with). The text under it is how the Imp behaves. What a file leaves out comes from your
  default Imp, and an Imp that is not in your settings file exists only in this folder.

  ```markdown
  ---
  description: Reviews changes before they are merged
  default: true
  base_url: https://openrouter.ai/api/v1
  api_key: ${OPENROUTER_API_KEY}
  model: openai/gpt-6-luna
  tools: [read_file, search_files, use_skill, imp_message]
  ---
  You review code. Say what could break, most serious first, and keep it short.
  ```

  The Imps of a folder message each other with `imp_message` as the Imps of the settings file do: with
  `imp.md` and `pip.md`, `imp` can ask `pip`, who answers with its own service, model and personality.
- **mcp.json** lists servers the usual way: `{"mcpServers": {"NAME": {"command": ..., "args": [...],
  "env": {...}}}}` or `{"url": ..., "headers": {...}}`. Values can be written in it or taken from the
  environment with `${NAME}` (or `${NAME:-default}`), and `${workspaceFolder}` is the chat's folder. An
  Imp's own server of the same name wins.
- **Trust.** A downloaded project could start programs (its MCP servers) or send your key to its own
  address (`base_url` with `api_key_env`). So a project's servers and its Imps' `base_url` and key variable
  are not used until you allow them with `/project trust`; until then those Imps use your default Imp's
  service, and the chat says what waits. If any of them changes, they wait to be allowed again.
  `/project untrust` turns them off.

The same layout in your home folder (`~/.agents/AGENTS.md`, `~/.agents/skills/`, `~/.agents/agents/`,
`~/.agents/mcp.json`) is yours, read in every chat and trusted. A project's skill or Imp replaces yours of
the same name. `/project` shows what was found, and problems with the files are shown when the chat starts.

## Tools through MCP servers

An Imp can use tools from MCP servers. A server is either a program on your computer, which is started when
the chat starts and stopped when it ends, or a service reached over HTTP. Add them with `imp mcp add` or
`/mcp add`, or in the settings file. Only the NAMES of environment variables and headers are listed. Their
values are never stored in that file.

```toml
[imps.pip]
tools_off = ["mcp.files.write_file"]  # tools this Imp must not use, by id

[imps.pip.mcp_servers.files]
command = "npx"
args = ["-y", "@modelcontextprotocol/server-filesystem", "${workspaceFolder}", "~/notes"]

[imps.pip.mcp_servers.github]
command = "npx"
args = ["-y", "@modelcontextprotocol/server-github"]
env = ["GITHUB_PERSONAL_ACCESS_TOKEN"]

[imps.pip.mcp_servers.search]         # a server reached over HTTP
url = "https://mcp.example.org/mcp"
headers = ["Authorization"]
```

- In `command` and `args`, `${workspaceFolder}` and `${cwd}` are the folder the chat is started in, and a
  leading `~/` is your home folder. A plain `.` works too, because the server starts in that folder.
- A server has a `command` (with `args` and `env`) or a `url` (with `headers`), never both.
- Imp speaks the Streamable HTTP transport: it posts each message to the address, accepts a JSON answer or an
  event stream, and keeps the session the server starts. The value of a header is read from the environment
  variable `IMP_MCP_SERVER_HEADER` (for the example, `IMP_MCP_SEARCH_AUTHORIZATION`), or else from the
  system keychain, where `imp config set-header search Authorization` saves it.
- Tool ids look like `mcp.SERVER.TOOL` for MCP tools and `own.GROUP.TOOL` for the ones that come with `imp`.
  `/tools` lists them. Tools in `tools_off` are not offered, and a call to one is refused.
- When a tool is called, the result goes back to the model, which can call more tools, up to `max_steps`
  rounds. After the last one, the model is asked once more for a plain answer.
- A server that does not start is shown with the reason, and the chat goes on without it.

## Imps talking to each other

When you have more than one Imp, each can send a message to the others with the `imp_message` tool, as in the
Mac and iPhone apps. The other Imp answers with its own model and personality, without tools of its own. The
chat shows the message (`⇢`) and the answer (`⇠`). The tool id is `own.troupe.imp_message`, so `tools_off` can
switch it off.

While the chat is online (see below), the Imps on your Mac's and iPhone's screens can be messaged too, and
they can message the Imps of this computer. An Imp of another device with the same name as one here is
called `name@Device`.

The tool has an optional `conversation` choice, `new` or `continue`. If the Imp says nothing, the
conversation continues when the last message between the two is younger than the window. Conversations are
saved per pair of Imps in the data folder (`talks` inside it). Two settings at the top of the settings file
change the rule:

```toml
talk_window_minutes = 60        # default 60, at most 10080
talk_threading = "decides"      # decides (default), recent, always or never
```

## Your Mac and iPhone

This computer can be one of your devices, next to your Macs and iPhones, the way they are to each other
([Imp Link](../docs/connecting/link.md)).

1. **Link.** Run `imp qr` (or type `/pair` in the chat) and scan the code with Imp on the Mac or the iPhone
   (Devices, then Scan). The code holds this computer's addresses on the local network, Wi-Fi first, and
   the Hop to meet at when the devices are on different networks (`--hop host:port` or `IMP_HOP`).
2. **Be online.** A full-screen chat is online for your linked devices while it is open, and so is `imp link`
   without a chat. Only one of them at a time: the others say so and carry on without devices.
3. **Send an Imp.** `/send iPhone` sends the Imp you are talking to, with its conversation. It shows up on the
   iPhone's screen and you talk to it there. It keeps thinking here, with its own model, key and tools:
   keep the chat or `imp link` running. While it is away, the chat shows what the iPhone asks it.
   `/call` brings it back with everything that was said. Throwing it back from the iPhone does the same.
4. **Visitors.** An Imp thrown from the Mac or the iPhone to this computer lands here. `/imp NAME` talks to
   it: what you say goes to its home device, which answers and sends its chat back. `/return` sends it home,
   `/send DEVICE` passes it on.
5. **Trust.** What another device asks an Imp of this computer is answered without tools, unless you mark the
   device as yours with `/trust DEVICE`. Then the Imp uses its tools (files, MCP servers) for it, in the folder
   the chat was started in.

`/devices` shows the linked devices, whether each is connected (directly or through the Hop), the Imps on its
screen and the visitors here. `/forget DEVICE` ends a link: your Imps there come back, and its visitors go
home.

The link itself (identity, handshake, tickets, the book of linked devices) is the same code the apps use, in
`imp-engine`. The identity key is never printed. It is kept in the file `link-identity` in the data folder, which
only you can read (as `~/.ssh` keeps a key), and the book file `link-book` next to it holds the rest. Each data
folder (`--data-dir`, `IMP_DATA_DIR`) has its own key. Nothing about the link touches the system keychain, so
the chat never asks for your password. An older `imp` kept the key in the keychain: run `imp link` (or
`imp qr`, or `/devices` in the chat) once to move it into the file. Until then the chat starts without your
devices and says so. The terminal does not share files with the apps yet, and an iPhone Imp can't move in for
good here (`adopt`): send it over to visit instead.

`imp qr TEXT` draws any text as a QR code instead, for example a kit address to open on a phone. The code is
always drawn in black on white with a quiet zone of four modules, whatever colours the terminal has, so a
phone can read it.

## API keys

A key is never printed and never written to the settings file. It is looked up in this order:

1. A key given in the chat with `/api_key KEY`, until the chat ends.
2. The environment variable named by the Imp's `api_key_env`, or else the global `api_key_env`
   (`IMP_API_KEY` by default).
3. The system keychain, where `imp config set-key --imp NAME` or `/api_key save KEY` saves it.
   `imp config clear-key` or `/api_key forget` removes it.

The keychain is read only when the environment variable is empty, so a key in the environment never brings a
password prompt. On macOS, a key saved in the keychain makes the Keychain ask once after each update of `imp`
(a new build is a new program to it): choose "Always Allow", or keep the key in the environment instead.

## Environment variables

- `IMP_API_KEY` holds the API key (the name can be changed in the settings, per Imp too).
- `IMP_CONFIG` is the path of the settings file.
- `IMP_DATA_DIR` is the folder for saved data: conversations between Imps and the link book. `imp serve`,
  `imp qr` and `imp link` read it too.
- `IMP_HOP` is the Hop to meet linked devices at, as `host:port`.
- `IMP_LINK_LOG` is a file to add a line to for each event of the link (connected, disconnected, each
  message's kind and size, passes), with the time. Never what was said, a key or a ticket. For finding out
  why a connection dropped or an Imp went astray.
- `NO_COLOR` turns the colours off. `LC_ALL`, `LC_MESSAGES` and `LANG` choose the language of the chat screen.

## Be your own server

`imp serve` runs a Den (accounts and shared kits) and a Hop (the relay between linked devices) in one process.

```sh
imp serve                      # Den on http://localhost:8080, Hop on localhost:4677
imp serve --host 0.0.0.0       # let devices on your network reach it
imp serve --den-port 9000 --hop-port 9001 --data-dir ./imp-data
imp serve --den-only --public-url https://den.example.org   # the Den alone, with its public address
imp serve --hop-only           # the Hop alone
```

It prints where each one listens and what to type into the apps. Data is kept in the usual data folder for
`imp` (or `--data-dir`, or `IMP_DATA_DIR`). The Den's secret is made the first time, kept in the file
`den-secret` there with permissions only you can use, and is never printed. Press Ctrl+C to stop. The server
programs in `server/den` and `server/hop` and the Docker image are separate and unchanged.

## For developers

`chat/src` is split by what each part does:

| file | what it is |
|---|---|
| `cli.rs` | the command line grammar (`imp --help`) |
| `commands/` | what each command does: `chat`, `imps`, `mcp_cmd`, `config_cmd`, `serve` |
| `config.rs`, `keys.rs` | the settings file, and where keys come from |
| `session.rs` | an Imp ready to chat: model client, MCP servers, tools. Rebuilt as `/` commands change it |
| `slash.rs` | the `/` commands, shared by both chats |
| `chat_state.rs`, `transcript.rs` | the conversation, and how tool calls read in one line |
| `tui/` | the full-screen chat: `mod` (state and keys), `view`, `help`, `text`, `terminal` (the event loop) |
| `troupe.rs` | `imp_message`, here and across devices |
| `link/` | this computer on the link: `book` (book file, seed file), `net` (addresses), `runner` (sockets for the core's node), `device` (home, holder and troupe) |
| `qr.rs`, `serve.rs` | codes and pairing, the Den and the Hop |

`cargo test -p imp-chat` runs everything without a real service or key store: `tests/device.rs` links the
computer with a phone made from the core's node over loopback sockets and a mock model, and checks an Imp
going away, answering there and coming back, a visitor, and messages across devices.
