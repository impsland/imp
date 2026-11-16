# Commands in the chat

Type `/` in the chat to see the commands. Every command is typed as a line that starts with `/`, and it takes
effect with the next message. `//text` sends a message that starts with a single `/`. `/help` lists the
commands, including your custom ones.

There are two kinds of command:

- **Built-in commands**, listed below. They change settings, switch Imps or manage devices.
- **Custom commands**, which you write yourself as Markdown files. They send a prompt to the Imp. See
  [Custom commands](#custom-commands) below.

## Built-in commands

| Command | What it does |
| --- | --- |
| `/help` | Lists the commands and your custom commands |
| `/clear` | Starts the conversation over (also `/new`, `/reset`) |
| `/compact` | Sums up the chat, so the Imp goes on from the summary (also `/recap`, `/summarize`) |
| `/quit` | Leaves the chat (also `/exit`, `/q`) |
| `/model [NAME]` | Shows or changes the model, such as `/model openai/gpt-6-luna` |
| `/base_url [URL]` | Shows or changes the service address, an OpenAI-compatible `/v1` root (also `/url`) |
| `/api_key [KEY]` | Shows where the key comes from, or uses `KEY` until the chat ends (also `/key`) |
| `/api_key save KEY` | Uses the key and keeps it in the system keychain. `/api_key forget` removes it |
| `/api_key_env [NAME]` | Reads this Imp's key from another environment variable |
| `/personality [TEXT]` | Shows or changes how the Imp behaves |
| `/imp [NAME]` | Lists the Imps and the visitors, or talks to another Imp (also `/imps`) |
| `/mcp` | Lists the MCP servers, with their tools, or why one did not start |
| `/mcp add NAME COMMAND [ARGS...]` | Adds a server that the chat starts. `--env VAR` passes a variable on |
| `/mcp add NAME URL` | Adds a server at an address. `--header NAME` sends a header |
| `/mcp add {CONFIG}` | Adds the servers of a pasted config, such as `{"mcpServers": {...}}` |
| `/mcp remove NAME`, `/mcp reload` | Removes a server, or starts them all again |
| `/tools`, `/tools off ID`, `/tools on ID` | Lists the tools by id, or switches one off or on |
| `/settings` | Shows the Imp's settings, its folder and the settings file (also `/config`) |
| `/project` | Shows what this folder adds (also `/skills`, `/agents`) |
| `/project trust`, `/project untrust` | Lets the folder's MCP servers and service settings run, or stops them |
| `/devices` | Lists the linked devices, the Imps on their screens and the visitors here (also `/peers`, `/visitors`) |
| `/pair` | Shows a code to link a Mac or an iPhone (also `/link`, `/qr`) |
| `/send DEVICE [IMP]` | Sends this Imp, or another one, to a linked device |
| `/call [IMP]` | Brings an Imp back from another device |
| `/return [VISITOR]` | Sends a visiting Imp back to its home |
| `/trust DEVICE [off]` | Lets your Imps use their tools for one of your devices |
| `/forget DEVICE` | Ends the link with a device |

A key given to `/api_key` is never shown in the chat and never written to the settings file.

Typing a few letters is enough to find a command. `/ex` offers `/quit`, `/mc` offers `/mcp`.

## Custom commands

A custom command is a Markdown file. Its name is the command's name, and its text is what the Imp receives when
you run the command.

### Write one

Make a folder called `commands` inside `.agents` in your project, and put a file in it:

```text
my-app/
  .agents/
    commands/
      review.md
```

`review.md` contains:

```markdown
Review $ARGUMENTS for bugs and missing tests.
```

Now type this in the chat:

```text
/review src/auth.rs
```

The Imp receives `Review src/auth.rs for bugs and missing tests.` The chat shows that message as you would
any other.

### How the text is filled in

- `$ARGUMENTS` is replaced by everything you typed after the command name. `/review` with nothing after it sends
  `Review  for bugs and missing tests.`, so write the placeholder where it reads well.
- If the text has no `$ARGUMENTS`, anything you type after the command is added below the text, after a blank
  line. So `summary.md` with `Summarise the chat so far.` run as `/summary in three bullets` sends the text and
  then `in three bullets`.
- The text is taken as it is. Write it the way you would write a message to the Imp.

### Names

- The file name, without `.md`, is the command name. It can contain letters, digits, `-` and `_`, and must start
  with a letter or a digit. `pr-check.md` becomes `/pr-check`.
- Files that do not end in `.md`, empty files and files with other names are ignored.
- A built-in command with the same name always wins. A custom command called `model.md` is never run, so pick
  another name.

### Where they are found

- `.agents/commands/` in your project folder. The project is the nearest folder, from the one you start the chat
  in up, with a `.agents` folder or a `.git`.
- `~/.agents/commands/` in your home folder. These are yours, and they work in every chat.

If a project and your home folder both have a command with the same name, the project's command is used.

### Trust

Custom commands need no `/project trust`. A command only sends the text you wrote in the file, on a command you
type yourself, so a project cannot start programs or send your key with one. The things that need trust are
unchanged: MCP servers and an Imp's `base_url` and key variable (see
[Sub-agents](/apps/cli-agents#trust)).

### When they are read

The chat reads the commands when it starts and again after each answer, so a new file shows up in the `/` list
after the Imp's next reply. The line chat reads them before each line. Changing a file takes effect the next
time it is read.

### Finding them

- Type `/` and the custom commands come after the built-in ones, with their arguments in the list, such as
  `/review ARGUMENTS`. The first line of the file is shown as its description.
- Type `/review` and press Enter. A command that takes arguments is completed to `/review ` so you can type
  them. Otherwise it is sent at once.
- `/help` lists them with the built-in commands.

### Examples

`.agents/commands/explain.md`:

```markdown
Explain $ARGUMENTS as if to a new colleague. Start with what it does, then how, then the pitfalls.
```

`.agents/commands/tests.md`:

```markdown
Write focused tests for $ARGUMENTS. Cover the normal case, the edge cases and one failure. Do not change the code under test.
```

`~/.agents/commands/todo.md`:

```markdown
List the TODO and FIXME comments in the project and sort them by how urgent they look.
```

Run them as `/explain src/parser.rs`, `/tests src/cart.rs` and `/todo`.
