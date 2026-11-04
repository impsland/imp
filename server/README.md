# Imp server

One Rust workspace, one Docker image, two services. The wire contract is in [PROTOCOL.md](PROTOCOL.md).

- **imp-den** (`crates/den`, command `den`): accounts, shared kits, the web gallery and the MCP endpoint over HTTP.
- **imp-hop** (`crates/hop`, command `hop`): the blind relay that lets a device reach the device that hosts it. Listens on TCP 4677.
- **imp-shared** (`crates/shared`): configuration, client IP, rate limiting, logging and shutdown helpers.
- **imp-core** (`crates/core`) and **imp-cli** (`crates/cli`, command `imp`): the terminal app and the logic it shares.

## Run from GitHub Packages

The image is published as `ghcr.io/impsland/imp` for amd64 and arm64: `latest` follows `main`,
and a tag such as `server-v1.1.0` publishes `1.1.0` and `1.1`. To try it on one computer:

```sh
docker run -d --name den -p 8080:8080 -v den-data:/data \
  -e DEN_SECRET="$(openssl rand -base64 48)" -e DEN_PUBLIC_URL=http://localhost:8080 -e DEN_ADDR=0.0.0.0:8080 \
  ghcr.io/impsland/imp serve
docker run -d --name hop -p 4677:4677 -e HOP_ADDR=0.0.0.0:4677 --entrypoint hop ghcr.io/impsland/imp
```

Then set the server in Imp's Devices tab to `http://<this computer>:8080`. Keep the `DEN_SECRET` you chose:
the Den needs the same one after a restart. For a public server with TLS, use Docker Compose below,
which runs the same image.

## Run locally

```sh
DEN_SECRET="$(openssl rand -base64 48)" \
DEN_PUBLIC_URL=http://localhost:8080 \
DEN_DATABASE=/tmp/den.db \
cargo run -p imp-den

cargo run -p imp-hop
```

On a computer that just wants to be its own server, `imp serve` (from `crates/cli`) can run the services in
three ways. Data and a generated secret stay in its own data folder.

- `imp serve` runs The Den and The Hop together, on ports 8080 and 4677.
- `imp serve --den-only` runs only The Den (accounts, shared kits, the web gallery).
- `imp serve --hop-only` runs only The Hop (the relay between devices). The Hop keeps no data and does not
  need The Den, so it can run on its own, on another computer, or beside any Den.

Options for a service that is not running are refused, for example `--hop-only --den-port 9000`.
The Docker image and the `den` and `hop` programs are not affected.

Check with `cargo fmt --all`, `cargo clippy --workspace --all-targets --locked -- -D warnings` and
`cargo test --workspace --locked`.

## Run with Docker Compose

```sh
cp .env.example .env     # set DEN_SECRET, DEN_HOST and DEN_PUBLIC_URL
docker compose up -d     # pulls ghcr.io/impsland/imp (add --build to build it from this folder)
```

`IMP_IMAGE` in `.env` picks another image or tag, for example `ghcr.io/impsland/imp:1.1`.

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
| `HOP_HANDSHAKE_SECS`, `HOP_PER_IP_CONNECTIONS`, `HOP_PER_IP_PER_MINUTE`, `HOP_MAX_CONNECTIONS`, `HOP_IDLE_SECS`, `HOP_BYTES_PER_SECOND`, `HOP_HOST_WAIT_SECS`, `HOP_GUEST_WAIT_SECS`, `HOP_ROOM_SESSIONS` | hop | the limits table in PROTOCOL.md |

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
