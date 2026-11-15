# Imp server

One Rust workspace, one Docker image, two services. The wire contract is in [PROTOCOL.md](../spec/PROTOCOL.md).

- **imp-den** (`server/den`, command `den`): accounts, shared kits, the web gallery and the MCP endpoint over HTTP.
- **imp-hop** (`server/hop`, command `hop`): the blind relay that lets a device reach the device that hosts it. Listens on TCP 4677.
- **imp-shared** (`server/shared`): configuration, client IP, rate limiting, logging and shutdown helpers.
- **imp-engine** (`engine`) and **imp-chat** (`chat`, command `imp`): the terminal app and the logic it shares.

## Run from GitHub Packages

The image is published as `ghcr.io/impsland/imp` for amd64 and arm64: `latest` follows `main`,
and a tag such as `server-v1.2.0` publishes `1.2.0` and `1.2`. To try it on one computer:

```sh
docker run -d --name den -p 8080:8080 -v den-data:/data \
  -e DEN_SECRET="$(openssl rand -base64 48)" -e DEN_PUBLIC_URL=http://localhost:8080 -e DEN_ADDR=0.0.0.0:8080 \
  ghcr.io/impsland/imp serve
docker run -d --name hop -p 4677:4677 -e HOP_ADDR=0.0.0.0:4677 --entrypoint hop ghcr.io/impsland/imp
```

Then, in Imp's settings under Devices, choose **Custom** for The Den and enter `http://<this computer>:8080`,
and for The Hop enter `<this computer>:4677`. They are two settings: you can set only one of them, and
they can point at different computers. For a server running on the same computer, enter
`http://localhost:8080` and `localhost:4677` (a linking code then gives the Hop out under the computer's own
network name, since `localhost` on the other device would be that device). With only a Den you can browse and install
but not link from anywhere. With only a Hop you can link devices but not use the Den. Keep the `DEN_SECRET` you chose:
the Den needs the same one after a restart. For a public server with TLS, use Docker Compose below,
which runs the same image.

## Run locally

```sh
DEN_SECRET="$(openssl rand -base64 48)" \
DEN_PUBLIC_URL=http://localhost:8080 \
DEN_DATABASE=/tmp/den.db \
cargo run -p imp-den --bin den

cargo run -p imp-hop --bin hop
```

On a computer that just wants to be its own server, `imp serve` (from `chat`) can run the services in
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
cd server
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

### The Den

| Variable | Default | Meaning |
|----------|---------|---------|
| `DEN_SECRET` | none, required | At least 32 bytes. Signs ALTCHA challenges. Keep it: the Den needs the same one after a restart. |
| `DEN_PUBLIC_URL` | none, required | Such as `https://den.example.org`. Used in links, problem types and MCP host checks. |
| `DEN_ADDR` | `0.0.0.0:8080` | Listen address. |
| `DEN_DATABASE` | `den.db` | SQLite file. |
| `DEN_TRUSTED_PROXIES` | empty | Comma separated IP addresses or CIDR networks allowed to set `X-Forwarded-For`. |
| `DEN_ALTCHA_COST` | `5000` | Proof-of-work cost. Must be at least 1. |
| `DEN_LOG_FORMAT` | text | `json` for JSON lines, anything else for text. |

### The Hop

| Variable | Default | Meaning |
|----------|---------|---------|
| `HOP_ADDR` | `0.0.0.0:4677` | Listen address. |
| `HOP_LOG_FORMAT` | text | `json` for JSON lines, anything else for text. |
| `HOP_HANDSHAKE_SECS` | `10` | Deadline for steps 1 to 3. |
| `HOP_PER_IP_CONNECTIONS` | `64` | Open connections per IP address (IPv6 /64). |
| `HOP_PER_IP_PER_MINUTE` | `120` | New connections per IP address per minute. |
| `HOP_MAX_CONNECTIONS` | `20000` | Open connections in total. |
| `HOP_IDLE_SECS` | `120` | Idle time before a session closes. |
| `HOP_BYTES_PER_SECOND` | `4194304` | Bandwidth per session, each way. |
| `HOP_HOST_WAIT_SECS` | `300` | How long a host waits for a guest. |
| `HOP_GUEST_WAIT_SECS` | `15` | How long a guest waits for a host. |
| `HOP_ROOM_SESSIONS` | `16` | Live sessions per room. |

Every Hop limit must be at least 1, or the Hop refuses to start. The limits are described in
[PROTOCOL.md](../spec/PROTOCOL.md).

## Ports and endpoints

| Port | Service | Notes |
|------|---------|-------|
| 8080/tcp | den | HTTP. Not published by Compose: Caddy reaches it on the `web` network. |
| 4677/tcp | hop | Relay. Published directly by Compose. |
| 80/tcp, 443/tcp, 443/udp | caddy | TLS for `DEN_HOST`. |

| Method | Path | Purpose |
|--------|------|---------|
| `GET` | `/healthz` | Health check. Used by the `healthcheck` command of both programs. |
| `GET` | `/challenge` | A fresh ALTCHA challenge. |
| `POST` | `/accounts` | Create an account from a solved challenge. |
| `DELETE` | `/accounts/me` | Delete the signed-in account. |
| `GET` | `/accounts/{handle}` | An account's page. |
| `GET` | `/items` | List or search items. |
| `GET` | `/items/{handle}/{slug}/kit.json` | Download an item's kit. |
| `POST` | `/items/{handle}/{slug}/installs` | Count an install. |
| `POST` | `/items/{handle}/{slug}/reports` | Report an item. |
| `GET` | `/stats` | Gallery statistics. |
| `GET` | `/`, `/i/{handle}/{slug}`, `/a/{handle}` | The web gallery. |
| `*` | `/mcp` | The MCP endpoint. |

The full wire contract is in [PROTOCOL.md](../spec/PROTOCOL.md).

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
hidden. Nothing unhides it automatically: review it with `den admin reported`, then run
`den admin unhide <handle>/<slug>` to show it again.

## Database schema

The Den creates its tables from one schema file, `den/migrations/0001_schema.sql`, the first time it opens a
database. A database made by an earlier build has a different history and is not read: start the Den on a new
database file and publish again. Change the schema by editing that file. Releases that change it say so.

## Backup

The database runs in WAL mode. Take a consistent copy with the Den itself, into the data volume,
then copy it out:

```sh
docker compose exec den den admin backup /data/backup.db
docker compose cp den:/data/backup.db ./den-backup.db
docker compose exec den rm /data/backup.db
```
