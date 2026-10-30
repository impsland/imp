# Imp server

One Rust workspace, one Docker image, two services. The wire contract is in [PROTOCOL.md](PROTOCOL.md).

- **den** (`crates/den`): accounts, shared kits, the web gallery and the MCP endpoint over HTTP.
- **hop** (`crates/hop`): the blind relay that lets an iPhone reach its Mac. Listens on TCP 4677.
- **shared** (`crates/shared`): configuration, client IP, rate limiting, logging and shutdown helpers.

## Run locally

```sh
DEN_SECRET="$(openssl rand -base64 48)" \
DEN_PUBLIC_URL=http://localhost:8080 \
DEN_DATABASE=/tmp/den.db \
cargo run -p den

cargo run -p hop
```

Check with `cargo fmt --all`, `cargo clippy --workspace --all-targets --locked -- -D warnings` and
`cargo test --workspace --locked`.

## Run with Docker Compose

```sh
cp .env.example .env     # set DEN_SECRET, DEN_HOST and DEN_PUBLIC_URL
docker compose up -d --build
```

Caddy terminates TLS for `DEN_HOST` on ports 80 and 443 and gets its certificate on its own, so
the DNS name must already point at the server. The Hop is published directly on `4677/tcp`.
The image is Alpine with two static musl binaries (about 28 MB). Both containers run as the
unprivileged `imp` user with a read-only root file system and no capabilities. The Den's
data lives in the `den-data` volume. The Den trusts `X-Forwarded-For` only from the Compose
network that Caddy sits on.

## Environment

| variable | service | meaning |
|----------|---------|---------|
| `DEN_SECRET` | den | required, at least 32 bytes, signs ALTCHA challenges |
| `DEN_PUBLIC_URL` | den | required, such as `https://den.example.org`, used in links, problem types and MCP host checks |
| `DEN_ADDR` | den | listen address, default `0.0.0.0:8080` |
| `DEN_DATABASE` | den | SQLite file, default `den.db` |
| `DEN_TRUSTED_PROXIES` | den | comma separated CIDRs allowed to set `X-Forwarded-For` |
| `DEN_ALTCHA_COST` | den | proof-of-work cost, default 5000 |
| `DEN_LOG_FORMAT` | den | `json` or text |
| `HOP_ADDR`, `HOP_LOG_FORMAT` | hop | listen address, default `0.0.0.0:4677`, and log format |
| `HOP_HANDSHAKE_SECS`, `HOP_PER_IP_CONNECTIONS`, `HOP_PER_IP_PER_MINUTE`, `HOP_MAX_CONNECTIONS`, `HOP_IDLE_SECS`, `HOP_BYTES_PER_SECOND`, `HOP_MAC_WAIT_SECS`, `HOP_PHONE_WAIT_SECS`, `HOP_ROOM_SESSIONS` | hop | the limits table in PROTOCOL.md |

## Moderation

There is no HTTP admin surface. Run the commands next to the database:

```sh
docker compose exec den /usr/local/bin/den admin reported
docker compose exec den /usr/local/bin/den admin hide <handle>/<slug>
docker compose exec den /usr/local/bin/den admin unhide <handle>/<slug>
docker compose exec den /usr/local/bin/den admin remove <handle>/<slug>
docker compose exec den /usr/local/bin/den admin remove-account <handle>
```

Changes show once the 30 second caches turn over. An item reported from 5 different addresses is
hidden until you look at it.

## Backup

The database runs in WAL mode. Take a consistent copy with the Den itself, into the data volume,
then copy it out:

```sh
docker compose exec den den admin backup /data/backup.db
docker compose cp den:/data/backup.db ./den-backup.db
docker compose exec den rm /data/backup.db
```
