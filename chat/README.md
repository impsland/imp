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

imp provider add openrouter --url https://openrouter.ai/api/v1 --key-env OPENROUTER_API_KEY
imp agent new Pip --model openrouter/openai/gpt-6-luna
imp mcp add files --command npx -y @modelcontextprotocol/server-filesystem .

cd ~/projects/my-app                        # the folder Pip works in
imp                                         # the same as imp chat
```

`imp provider add` is a service, called by the short name you give it (`openrouter`); a model is written
`provider/model`, with an optional `#variant` (`openai/gpt-6-luna#high`). `imp agent new` makes the Imp as a
file in `~/.agents/agents`. In the server's arguments, `.` and `${workspaceFolder}` are the folder the chat
is started in, so the same settings work in every folder. The Imp is told that folder too.

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

Everything can also be done inside the chat with the same words: `/mcp add files --command npx -y
@modelcontextprotocol/server-filesystem .`, `/model openrouter/openai/gpt-6-luna`, `/auth set openrouter`.
Type `/` to see the commands.

## Commands

Run `imp --help` for every command and `imp COMMAND --help` for one. Lists and details take `--json`.

| command | what it does |
|---|---|
| `imp chat [--imp NAME]` | The full-screen chat. `--plain` for the line chat, `--offline` to stay off the link |
| `imp agent list [--all]`, `show NAME` | The agents of `~/.agents/agents`; the Imps are the `primary` and `all` ones |
| `imp agent new NAME` | Make one. `--description`, `--model`, `--mode`, `--color` |
| `imp agent set NAME KEY VALUE` | Change `description`, `mode`, `model`, `variant`, `color`, `steps`, `hidden`, `disabled` or `prompt` (`-` clears) |
| `imp agent edit NAME`, `rename OLD NEW`, `remove NAME` | Open the file in `$EDITOR`, rename it, remove it |
| `imp provider list`, `add ID`, `set ID KEY VALUE`, `remove ID` | The services. `add` takes `--url`, `--name`, `--header NAME=VALUE`, `--key-env VAR` |
| `imp auth set PROVIDER`, `clear PROVIDER`, `list` | Keys in `auth.json`. `set` reads the key from standard input. Keys are never shown |
| `imp model [provider/model#variant] [--agent NAME]` | Show or choose the default model, or one agent's (`-` with `--agent`: the default again) |
| `imp mcp list`, `add NAME`, `set`, `remove`, `enable`, `disable` | MCP servers: `--command PROGRAM ARGS` or `--url URL`, with `--env` and `--header`. `--agent NAME` for one Imp |
| `imp permission list`, `add ACTION RESOURCE EFFECT`, `remove N` | Rules for what Imps may do. `--agent NAME` for one Imp |
| `imp skill list`, `show NAME`; `imp command list`, `show NAME` | The skills and custom commands that were found |
| `imp project`, `project trust`, `project untrust` | What this folder adds, and whether its settings run |
| `imp config path`, `get [KEY]`, `set KEY VALUE`, `unset KEY` | `imp.json` by dotted key, such as `requests.retries` |
| `imp qr` | Link a Mac or an iPhone: shows a code to scan, then stays online |
| `imp link` | Stay online for your linked devices without a chat |
| `imp serve` | Run the Hop on this computer. `--host ADDRESS` lets your network reach it |
| `imp qr TEXT` | Draw any text as a QR code |

## What the Imp remembers

The chat shows everything that was said. What the model is sent is the Imp's memory of it, the same as
in the Mac and iPhone apps: the latest exchanges (all of them by default, see `imps.NAME.memory.exchanges`), with
long tool results clipped. A message that failed or that you stopped still shows, but is not sent again.
When a chat grows long (`imps.NAME.memory.newChatAtTokens`, 250,000 tokens by default) it says so once. `/compact` then
has the model sum up the chat so far. The summary goes in place of everything before the last exchange,
so the chat carries on for less. `/clear` starts over.

## The full-screen chat

In a terminal, `imp chat` shows the conversation with the reply arriving as it is written.

```text
› Ask zed what he thinks of basil.
⇢ zed: What do you think of basil?
  ⇠ Arrr, basil's a fine herb, makes a tomato taste shipshape.
● Zed likes it: he says it makes tomatoes better.

 › Write a message, / for commands, @ for files
● Pip · openai/gpt-6-luna · ~/projects/my-app                      Ready · ? help
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
  and a space, a line shows how to use it, and fixed choices such as `save` after `/auth` are listed.
- Left, Right, Home, End (or Ctrl+A, Ctrl+E) move in the message. Alt or Ctrl with Left or Right moves by word.
  Backspace and Delete erase at the cursor, Ctrl+W (or Alt+Backspace) the word before it, Ctrl+U everything.
- Up on the first line of the message brings back what you sent before, and each Up goes one message further
  back, to the oldest. Within a message of several lines, Up first moves to the line above. Down on the last
  line goes forward again, and after the newest it returns what you were writing. Ctrl+P and Ctrl+N do the same.
- Type `@` to add a file: the folder's files that match what follows are listed (`@main` finds
  `src/main.rs`), and Tab or Enter puts the path in the message. A folder opens to what is in it. When the
  message is sent, each file named with `@` goes with it for the Imp to read (text up to 100 KB, 256 KB
  in all. A folder goes as the list of what is in it). The chat shows `⎿ with notes.txt` under the message.
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
- Esc closes the `/` list, else stops an answer that is arriving. It never leaves the chat. Ctrl+C or `/quit` leave. The terminal is put back as it
  was, also after an error.
- `?` (when nothing is typed) or F1 opens a card that explains every key. On a short terminal it drops its
  blank lines, takes two columns if the terminal is wide, and else scrolls with Up, Down and the wheel.
- On a short terminal the message field loses its blank rows and the Imp's picture is left out.

Models that think show it. While one thinks, a dim `Thinking` block streams its reasoning, the last four
rows of it, so the screen does not jump. When the answer or a tool call starts, the block becomes one line,
`✻ Thought for 3s`, like a tool call's `⏺` line. Click it, or press Ctrl+O (which opens the latest tool call
or thought), to read the whole reasoning; the arrows walk between calls and thoughts. Every phase of thinking
in a turn gets its own line, and they stay when you scroll back. The reasoning is only shown. It is never
sent back to the model. Reasoning is read from `reasoning`, `reasoning_content` and `reasoning_details`
(OpenRouter, DeepSeek, vLLM, LM Studio) and from a `<think>…</think>` block at the start of the reply (Ollama).

`imp chat --plain` is the line chat. It is also used when the input or output is not a terminal, for
example in a pipe. Answers go to standard output and everything else (tool calls, notes) to standard error:

```sh
echo "Summarise notes.txt in one line" | imp chat --plain > summary.txt
```

In the line chat, thinking shows as two lines on standard error, `✻ Thinking…` and then `✻ Thought for 3s`.
The reasoning text itself is not printed.

The look follows the apps as far as a terminal can: no boxes and no lines, the terminal's own background,
and the only colours are the Imp's mark and red for problems. Colours come from `design/tokens.json`
through `chat/src/theme.generated.rs`. Set `NO_COLOR` to turn them off. Nothing is wider than the terminal,
down to 36 columns. The words are in English, Spanish and Simplified Chinese, from `LC_ALL`, `LC_MESSAGES`
or `LANG`. They live in `design/strings/cli.json`, and `node design/generate.mjs` writes them to
`chat/src/strings.generated.rs`.

## Chat commands

Type them in the chat. They are the command line's words with a `/` in front of them (`imp model` is `/model`),
and they change the same files, so the Mac app shows the change too. `//text` sends a message that starts
with `/`.

| command | what it does |
|---|---|
| `/help` | List the commands, and your custom ones |
| `/clear` | Start the conversation over |
| `/compact` | Sum up the chat so far: the Imp goes on from the summary instead of everything said before (also `/recap`) |
| `/quit` | Leave (also `/exit`) |
| `/imp [NAME]` | List the Imps (and visitors), or talk to another one |
| `/model [provider/model#variant]` | Show or change the model |
| `/agent …` | `list`, `show`, `new`, `set`, `rename`, `remove`: the same as `imp agent` (editing is for the terminal) |
| `/provider …`, `/auth …` | Services and keys. `/auth set PROVIDER` asks for the key hidden; it is never shown or kept in the history |
| `/mcp …` | `list` (with each server's tools, or why one did not start), `add`, `set`, `remove`, `enable`, `disable` |
| `/permission …` | `list`, `add`, `remove` |
| `/skill …`, `/command …` | `list` and `show` |
| `/project …`, `/config …` | What the folder adds, trust; `imp.json` by key |
| `/tools` | List the tools by id and whether the rules leave them on |
| `/devices` | Linked devices, the Imps on their screens and the visitors here |
| `/pair` | Show a code to link a Mac or an iPhone |
| `/send DEVICE [IMP]` | Send this Imp (or another) to a linked device |
| `/call [IMP]` | Bring an Imp back from another device |
| `/return [VISITOR]` | Send a visiting Imp back to its home |
| `/trust DEVICE [off]` | Let your Imps use their tools for one of your devices |
| `/forget DEVICE` | End the link with a device |

Names that are close enough also work, and typing a few letters is enough to find a command: `/ex` already
offers `/quit`.

## Custom commands

A file `commands/NAME.md` in `~/.agents` (for every chat) or in a project's `.agents` is a command, run as
`/NAME arguments`. Its text is the message the Imp gets:

```markdown
---
description: Review a file
agent: reviewer
---
Review $1 for bugs and missing tests. Also consider: $ARGUMENTS
```

```text
› /review src/auth.rs the error handling
› Review src/auth.rs for bugs and missing tests. Also consider: src/auth.rs the error handling
```

- `$ARGUMENTS` is everything after the name; `$1`, `$2` … are its words one by one. Without a placeholder,
  what follows is added after the text.
- `` !`cmd` `` is replaced by what the command prints (it needs the `shell` permission for that command line),
  and `@path` by the file's contents (the `read` permission).
- Front matter: `description` (shown in the `/` list), `agent` (the Imp that runs it), `model` (for this
  message only) and `subtask: true` (a conversation of its own, whose answer is shown and not kept).
- Names are 1 to 32 letters, digits, `-` and `_`. A built-in command of the same name always wins, and a
  project's command replaces your home one of the same name.
- `imp command list` shows what was found, and `imp command show NAME` one command. The Mac app lists them too.
- They need no `/project trust`: they only send the text you wrote, on a command you type.

The full guide, with examples, is in the documentation under *Terminal app* (`docs/apps/cli-commands.md`).

## Where everything is kept

The terminal app and the Mac app share one configuration; set something up in one and the other shows it
(`docs/architecture/configuration.md` is the reference).

| what | where |
|---|---|
| Imps and other agents | `~/.agents/agents/NAME.md`: front matter, then the prompt |
| Skills, custom commands, standing notes | `~/.agents/skills/NAME/SKILL.md`, `~/.agents/commands/NAME.md`, `~/.agents/AGENTS.md` |
| Services, the default model, MCP servers, permissions, triggers, requests, link | `imp.json` in the config folder |
| Keys and MCP sign-ins | `auth.json` in the config folder, readable by you only |

The config folder is `$IMP_CONFIG_HOME`, else `$XDG_CONFIG_HOME/imp`, else `~/.config/imp` (on a Mac too).
`imp config path` prints the path of `imp.json`. What `imp` keeps only for itself (the link book and identity,
saved conversations between Imps) is in a data folder of its own: `~/Library/Application Support/imp-chat` on a
Mac, `IMP_DATA_DIR` for another. Files are written whole and renamed into place under a lock, after reading
again, so the two apps never undo each other.

```json
{
  "model": "openrouter/openai/gpt-6-luna",
  "providers": {
    "openrouter": { "name": "OpenRouter", "options": { "baseURL": "https://openrouter.ai/api/v1", "apiKey": "{env:OPENROUTER_API_KEY}" } }
  },
  "mcp": { "files": { "type": "local", "command": ["npx", "-y", "@modelcontextprotocol/server-filesystem", "${workspaceFolder}"] } },
  "permissions": [{ "action": "shell", "resource": "rm -rf *", "effect": "deny" }],
  "requests": { "timeoutSeconds": 120, "retries": 3 },
  "talk": { "threading": "decides", "windowMinutes": 60 }
}
```

```markdown
---
description: Friendly and brief
mode: primary
model: openrouter/openai/gpt-6-luna#high
steps: 40
---
Friendly, curious and a little mischievous. Keeps answers short.
```

`{env:NAME}` in a value is the environment variable and `{file:path}` the file's contents. Settings only the
Mac app has fields for (an Imp's character, size, memory, own animations, its id) are in `imp.json` under
`imps.NAME`. `steps` is the most tool rounds for one answer, `imps.NAME.memory.exchanges` how many of the latest
exchanges go with each message (0: all), and `imps.NAME.memory.newChatAtTokens` when a chat counts as long.

## AGENTS.md and the .agents folder

A chat reads the files that other coding agents read too, from its folder's project: every folder from the
one you start the chat in up to the git root (or your home folder).

```text
my-app/
  AGENTS.md                       instructions for every Imp working here
  src/AGENTS.md                   more, for a chat started in src/ (read after the one above)
  .agents/
    AGENTS.md                     instructions too
    skills/release-notes/SKILL.md a skill
    agents/review.md              the agent review, in this folder
    commands/review.md            the command /review
    imp.json                      services, MCP servers and permissions, once you trust them
```

- **AGENTS.md** goes in the system text, after who the Imp is, in the order above (32 KB at most). That
  is where standing rules belong.
- **Skills** follow the [Agent Skills](https://agentskills.io) format: a `SKILL.md` whose front matter has a
  `name` (the folder's name: lowercase letters, digits and dashes) and a `description` of when to use it.
  Only names and descriptions go in the system text; the Imp's `skill` tool reads the whole skill when a task
  needs it, so many skills cost few words. A `deny` rule on `skill` switches it off.
- **agents/NAME.md** is an agent (see above). A nearer folder wins over a farther one, and a project wins
  over `~/.agents`, by name: the project's `review.md` replaces your `review` there.
- **.agents/imp.json** may add services, MCP servers and permissions. Because those start programs and send
  keys, they wait until you allow them with `imp project trust`; if the file changes, they wait again.
  `imp project untrust` turns them off. Agents, skills, commands and `AGENTS.md` are text, read at once.

The same layout in `~/.agents` is yours, read in every chat and trusted. `imp project` shows what was found,
and problems with files are shown when the chat starts.

## Tools through MCP servers

An Imp can use tools from MCP servers. A server is either a program on your computer, which is started when
the chat starts and stopped when it ends, or a service reached over HTTP. Every Imp may use every server;
a rule turns one off for an Imp. Add them with `imp mcp add` or `/mcp add`, or in `imp.json`:

```json
{
  "mcp": {
    "files": { "type": "local", "command": ["npx", "-y", "@modelcontextprotocol/server-filesystem", "${workspaceFolder}", "~/notes"] },
    "github": { "type": "local", "command": ["npx", "-y", "@modelcontextprotocol/server-github"],
                "environment": { "GITHUB_PERSONAL_ACCESS_TOKEN": "{env:GITHUB_TOKEN}" } },
    "search": { "type": "remote", "url": "https://mcp.example.org/mcp", "headers": { "Authorization": "Bearer {env:SEARCH_KEY}" } }
  },
  "permissions": [{ "action": "mcp", "resource": "files/write_file", "effect": "deny" }]
}
```

- In `command`, `${workspaceFolder}` is the folder the chat is started in, and a leading `~/` is your home
  folder. A plain `.` works too, because the server starts in that folder.
- A server is `local` (`command`, `environment`) or `remote` (`url`, `headers`), never both. Values can use
  `{env:NAME}`, so a secret stays in your environment.
- A remote server that asks you to sign in (OAuth) is signed in once, in the Mac app or here, and the sign-in
  is kept in `auth.json` for both.
- Imp speaks the Streamable HTTP transport: it posts each message to the address, accepts a JSON answer or an
  event stream, and keeps the session the server starts.
- Tool ids look like `mcp.SERVER.TOOL` for MCP tools and `own.GROUP.TOOL` for the ones that come with `imp`.
  `/tools` lists them. A tool a rule denies (`mcp` with `server/tool`, or the group's action) is not offered,
  and a call to one is refused. `imp mcp disable NAME --agent IMP` writes the rule for one Imp.
- When a tool is called, the result goes back to the model, which can call more tools, up to the agent's
  `steps`. After the last one, the model is asked once more for a plain answer.
- A server that does not start is shown with the reason, and the chat goes on without it.

## Imps talking to each other

The guide to Imps that a project shares, such as a reviewer and a researcher, with examples, is in
`docs/apps/cli-agents.md`. This section is the reference.

When you have more than one Imp, each can send a message to the others with the `imp_message` tool, as in the
Mac and iPhone apps. The other Imp answers with its own model and personality, without tools of its own. The
chat shows the message (`⇢`) and the answer (`⇠`). The tool id is `own.personality.imp_message`, so a `deny` rule can
switch it off.

While the chat is online (see below), the Imps on your Mac's and iPhone's screens can be messaged too, and
they can message the Imps of this computer. An Imp of another device with the same name as one here is
called `name@Device`.

The tool has an optional `conversation` choice, `new` or `continue`. If the Imp says nothing, the
conversation continues when the last message between the two is younger than the window. Conversations are
saved per pair of Imps in the data folder (`talks` inside it). Two settings in `imp.json` change the rule:

```json
{ "talk": { "windowMinutes": 60, "threading": "decides" } }
```

`windowMinutes` is at most 10080; `threading` is `decides` (default), `recent`, `always` or `never`.

Other Imps read what an Imp says about itself. Give it a sentence on what it is for, as `description` in
its agent file (`imp agent set NAME description TEXT`). The
tool lists it next to the Imp's name, as information and never as instructions, and it goes to your other
devices too, with the Imp's abilities (`shell` when its shell tool is on, and the names of its MCP servers).
Messages to several Imps in one reply run at the same time.

A message can also go without waiting for the answer. The setting `talk_waiting` says how:

```toml
talk_waiting = "decides"        # decides (default), wait or dont_wait
```

With `decides` the sending Imp chooses with a `wait` argument (it waits if it says nothing). A message that
does not wait gets a receipt at once and the Imp carries on. The answer comes later as a new message at the
end of the chat that starts `[Event, not from the user]`. Nothing earlier is changed. If the Imp is free, it
takes a turn on it and the chat shows it. If it is busy, the answer waits until the turn ends. An Imp can have
4 such messages out at once, and a message sent from an Imp woken three answers deep must wait. A local Imp has
10 minutes to answer. An Imp on another device has the link's answer timeout: 2 minutes (`ANSWER_TIMEOUT` in `engine/src/link/talks.rs`). Answers still on their way are lost when you quit or
switch Imps. This is only in the chat window: the line chat (`imp chat --plain`, also used in a pipe) and
`imp serve` always wait for the answer, whatever the setting says.

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
the chat never asks for your password. The link's identity and book are the terminal's own (the apps keep theirs), so each shows up as its own
device. An iPhone Imp can't move in for good here (`adopt`): send it over to visit instead.

`imp qr TEXT` draws any text as a QR code instead, for example a kit address to open on a phone. The code is
always drawn in black on white with a quiet zone of four modules, whatever colours the terminal has, so a
phone can read it.

## API keys

A key is never printed and never written to `imp.json`. A service's key is, in this order:

1. `options.apiKey` in `imp.json` when it is set, usually `{env:NAME}` (`imp provider add ID --key-env NAME`).
2. The key saved for it in `auth.json`, by `imp auth set PROVIDER` or `/auth set PROVIDER` (typed hidden, or the
   first line of standard input). `imp auth clear PROVIDER` removes it, `imp auth list` shows which services
   have one and from where, never the key.

`auth.json` is readable by you only (mode 0600), and is the same file the Mac app keeps its keys in. Nothing
uses the system keychain, so a chat never asks for your password.

## Environment variables

- `IMP_CONFIG_HOME` is the config folder (`imp.json`, `auth.json`), instead of `$XDG_CONFIG_HOME/imp` or
  `~/.config/imp`.
- `IMP_DATA_DIR` is the folder for saved data: conversations between Imps and the link book. `imp serve`,
  `imp qr` and `imp link` read it too.
- `IMP_HOP` is the Hop to meet linked devices at, as `host:port`.
- Any variable a provider or MCP server names with `{env:NAME}`, such as `OPENROUTER_API_KEY`.
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
| `commands/` | what each command does: `chat`, `reply`, `serve`, and `manage/` (agents, providers, auth, models, MCP, permissions, skills, commands, project, config) |
| `settings.rs` | what the chat takes from the shared configuration: the model, steps, memory, talk rules |
| `folders.rs` | the settings and data folders, and the move of files from older builds |
| `project.rs` | the `AGENTS.md` and `.agents/` files of a folder |
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
