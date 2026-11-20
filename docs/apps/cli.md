# The terminal app (`imp`)

Imp also has a command line version that works on any computer with a Rust toolchain. It makes Imps and chats
with them in a terminal, using any OpenAI-compatible service. Its Imps use tools from MCP servers, message
each other, and travel to your Mac and iPhone and back, as in the apps.

## Install

```sh
cargo install imp-chat
```

This installs the `imp` program from [crates.io](https://crates.io/crates/imp-chat). It needs Rust 1.99 or
newer. Run the same command again to update. From a checkout of the repository, `cargo install --path chat --locked`
builds that version.

## Quick start

1. Put your API key in an environment variable.

   ```sh
   export OPENROUTER_API_KEY=sk-or-...
   ```

2. Tell Imp where the model lives, and make an Imp that uses it.

   ```sh
   imp provider add openrouter --url https://openrouter.ai/api/v1 --key-env OPENROUTER_API_KEY
   imp agent new pip --model openrouter/openai/gpt-6-luna
   ```

3. Add an MCP server for its tools. The last argument is the folder you chat in.

   ```sh
   imp mcp add files --command npx -y @modelcontextprotocol/server-filesystem .
   ```

4. Start the chat. `imp` on its own does the same.

   ```sh
   imp
   ```

Then type a message and press Enter. Type `/` to see the commands.

## Commands

Run `imp --help` to see every command, or `imp <command> --help` to see one. Lists and details take `--json`.

| Command | What it does |
| --- | --- |
| `imp`, `imp chat` | Opens the chat with your Imps (`imp chat --imp NAME` for another one) |
| `imp agent list`, `show`, `new`, `set`, `edit`, `rename`, `remove` | Makes and changes Imps: files in `~/.agents/agents` |
| `imp provider list`, `add`, `set`, `remove` | The model services |
| `imp auth set`, `clear`, `list` | Keys, kept in `auth.json`. They are never shown |
| `imp model [provider/model#variant]` | Shows or chooses the default model (`--agent NAME` for one Imp) |
| `imp mcp list`, `add`, `set`, `remove`, `enable`, `disable` | The MCP servers that give Imps their tools |
| `imp permission list`, `add`, `remove` | Rules for what Imps may do: allow, ask or deny |
| `imp skill`, `imp command` | Lists the skills and custom commands that were found |
| `imp project`, `imp config` | What a folder adds and whether it is trusted; `imp.json` by key |
| `imp qr` | Shows a code to scan with Imp on a Mac or an iPhone |
| `imp link` | Keeps this computer online as one of your devices |
| `imp serve` | Runs the Hop. See `server/README.md` |

## One configuration with the Mac app

The terminal app and the Mac app use the same files, so an Imp made in one is in the other, with the same
services, tool servers, permissions, triggers and keys:

- Imps are Markdown files in `~/.agents/agents`, and skills and custom commands are in `~/.agents` too.
- Services, the default model, tool servers and permissions are in `imp.json`, and keys in `auth.json`, in
  `~/.config/imp` (or `$IMP_CONFIG_HOME`). `imp config path` prints it, and the Mac app's Settings shows it
  under Backup.

Change a file in an editor, with `imp`, or in the Mac app, and the others take it in. See
[Configuration](/architecture/configuration).

## In the chat

Models that think show their reasoning live and then as a collapsed `✻ Thought for 3s` line (see
[Using the terminal chat](/apps/cli-chat#thinking)).

The chat has its own pages:

- [Using the terminal chat](/apps/cli-chat): writing messages, `@` files, the `/` list, sending again, copying
  text, and keys.
- [Commands in the chat](/apps/cli-commands): every `/` command, and how to write your own with
  `.agents/commands/`, such as `/review src/auth.rs`.
- [Sub-agents](/apps/cli-agents): Imps that a project shares, such as a reviewer or a researcher, and how Imps
  ask each other for help.

## Keys

A key is never written to `imp.json`. Name an environment variable (`--key-env VAR` on `imp provider add`), or
save one with `imp auth set PROVIDER` (typed hidden) into `auth.json`, which only you can read. Nothing uses
the system keychain, so `imp chat` never asks for your password.

## With your devices

`imp qr` (or `/pair` in the chat) shows a code to scan with Imp on a Mac or an iPhone. While a chat or
`imp link` runs, this computer is online as one of your devices: `/send iPhone` sends an Imp there, `/call`
brings it back, and Imps thrown to the computer visit it and can be talked to with `/imp NAME`. It follows
[Imp Link](/connecting/link).

Full details are in `chat/README.md`, the reference that ships with the crate.
