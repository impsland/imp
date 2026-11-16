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

2. Make an Imp that uses that variable.

   ```sh
   imp imp new pip --model openai/gpt-6-luna --api-key-env OPENROUTER_API_KEY
   ```

3. Add an MCP server for its tools. The last argument is the folder you chat in.

   ```sh
   imp mcp add files -- npx -y @modelcontextprotocol/server-filesystem .
   ```

4. Start the chat. `imp` on its own does the same.

   ```sh
   imp
   ```

Then type a message and press Enter. Type `/` to see the commands.

## Commands

Run `imp --help` to see every command, or `imp <command> --help` to see one.

| Command | What it does |
| --- | --- |
| `imp`, `imp chat` | Opens the chat with your Imps (`imp chat --imp NAME` for another one) |
| `imp imp new [NAME]` | Makes an Imp. Flags: `--model`, `--url`, `--personality`, `--api-key-env`, `--default` |
| `imp imp list`, `imp imp set`, `imp imp remove` | Lists, changes or removes Imps |
| `imp mcp add`, `imp mcp list`, `imp mcp remove` | Manages the MCP servers that give Imps their tools |
| `imp config set-key`, `imp config show` | Saves an API key in the system keychain, or shows the settings |
| `imp qr` | Shows a code to scan with Imp on a Mac or an iPhone |
| `imp link` | Keeps this computer online as one of your devices |
| `imp serve` | Runs the Den and the Hop. See `server/README.md` |

## In the chat

The chat has its own pages:

- [Using the terminal chat](/apps/cli-chat): writing messages, `@` files, the `/` list, sending again, copying
  text, and keys.
- [Commands in the chat](/apps/cli-commands): every `/` command, and how to write your own with
  `.agents/commands/`, such as `/review src/auth.rs`.
- [Sub-agents](/apps/cli-agents): Imps that a project shares, such as a reviewer or a researcher, and how Imps
  ask each other for help.

## Keys

Your API key stays in an environment variable, the system keychain or the chat's memory, and is never written
to the settings file. With the key in an environment variable, `imp chat` never opens the keychain, so it never
asks for your password.

## With your devices

`imp qr` (or `/pair` in the chat) shows a code to scan with Imp on a Mac or an iPhone. While a chat or
`imp link` runs, this computer is online as one of your devices: `/send iPhone` sends an Imp there, `/call`
brings it back, and Imps thrown to the computer visit it and can be talked to with `/imp NAME`. It follows
[Imp Link](/connecting/link).

Full details are in `chat/README.md`, the reference that ships with the crate.
