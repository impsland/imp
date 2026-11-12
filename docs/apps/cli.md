# The terminal app (`imp`)

Imp also has a command line version that works on any computer with a Rust toolchain. It makes Imps and chats with them
in a terminal, using any OpenAI-compatible service.

## Install

```sh
cargo install --path cli
```

## Use

```sh
imp imp new pip --model gpt-5
IMP_API_KEY=... imp chat
```

Your API key stays in an environment variable or the system keychain, and is never written to the settings file.

Run `imp --help` to see every command. The `imp` program can also run the Den and the Hop (`imp serve`). See
`server/README.md` in the repository.

Full details are in `cli/README.md`.
