# imp-engine

The portable logic every Imp platform shares: the device link (identity, handshake, tickets, the book of
linked devices), the retry policy, tool filtering, workspace paths, an MCP client and an OpenAI-compatible
chat client with the agent loop that runs tools.

It is the core of [`imp-chat`](https://crates.io/crates/imp-chat), the `imp` terminal app, and of the Mac and
iPhone apps in [impsland/imp](https://github.com/impsland/imp).

```toml
[dependencies]
imp-engine = "1"
```

The default `io` feature adds the parts that reach the network and other processes (the chat client, the
stdio MCP transport and the agent loop). Turn default features off for the pure logic.

Licensed under MIT.
