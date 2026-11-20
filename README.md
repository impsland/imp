<p align="center">
  <img src="docs/assets/screenshot.png" width="760" alt="Imp, a tiny red desk imp, floating above your windows">
</p>

# Imp

A tiny desk imp for your Mac that does what you ask. Imp works with any OpenAI-compatible model service, including local models through Ollama. Your chats and settings stay on your Mac, and requests go only to the model service you add.

## Build and run

Run `make help` to list every command. The Apple steps are in `apple/scripts/apple.sh`. The tools you need are in [Building from source](docs/development/building.md).

```sh
make install   # build build/Imp.app, copy it to /Applications and open it
make run       # build build/Imp.app and open it
make test      # run every test, the screen snapshots included
make rust      # format, lint and test the Rust workspace
```

To install a release, use `brew install --cask impsland/tap/imp` or download `Imp.dmg` from the GitHub releases.

The terminal app is the `imp` binary. Install it with `cargo install imp-chat`.

## Documentation

- [Documentation index](docs/index.md)
- [Architecture](docs/architecture/index.md)
- [Building and testing](docs/development/building.md)
- [Server protocols](spec/PROTOCOL.md) and the shared test vectors in [spec/fixtures](spec/fixtures/README.md)
