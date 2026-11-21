# Imp server

One Rust workspace, one Docker image, two services. The wire contract is in [PROTOCOL.md](../spec/PROTOCOL.md). The Den in more detail: [docs/sharing/den.md](../docs/sharing/den.md).

- **imp-den** (`server/den`, command `den`): the Den, a standalone service. Shared items (Imps, animations, triggers, tools and kits), accounts, OAuth sign-in, the web gallery, a read-only JSON API and the MCP endpoint at `/mcp`.
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

Then connect to them:

- **The Den** is a remote MCP server. Any MCP host adds `http://<this computer>:8080/mcp`. In Imp, add it as a
  tool (**Settings, Tools**, or `imp mcp add den http://<this computer>:8080/mcp`), or press **Add to Imp** on the
  Den's home page, which opens Imp with the tool ready to review. Searching and downloading need no account.
  Publishing needs one: the host (or Imp) opens the Den's sign-in page in a browser, where you pick a handle (your
  browser solves an [ALTCHA](https://altcha.org) proof of work) or paste your account key, and then it continues
  on its own. The account key (`dak_...`) is shown once. Keep it: it connects other hosts to the same account.
- **The Hop**: in Imp's settings under Devices, choose **Custom** and enter `<this computer>:4677`. For a server
  on the same computer, enter `localhost:4677` (a linking code then gives the Hop out under the computer's own
  network name, since `localhost` on the other device would be that device).

The Den and the Hop are separate: run either one, on different computers if you like. Keep the `DEN_SECRET`
you chose: the Den needs the same one after a restart. For a public server with TLS, use Docker Compose below,
which runs the same image.

## Run locally

```sh
DEN_SECRET="$(openssl rand -base64 48)" \
DEN_PUBLIC_URL=http://localhost:8080 \
DEN_DATABASE=/tmp/den.db \
cargo run -p imp-den --bin den

cargo run -p imp-hop --bin hop
```

`imp serve` (from `chat`) runs only the Hop, for a computer that wants to be its own relay. It listens on
`127.0.0.1:4677`. `--host 0.0.0.0` lets devices on the network use it, and `--hop-port` changes the port. It keeps
no data. The Den is not part of it: run `den` (above), the Docker image or Compose.

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
The image is Alpine with two static musl binaries. Both containers run as the
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
| `HOP_FORWARDED_FROM` | none | Proxies whose `X-Forwarded-For` names the browser behind a WebSocket, as addresses or prefixes such as `172.16.0.0/12`. Without it a browser behind a proxy counts against the proxy's address. |

#### Browsers (WebSocket)

The Hop takes WebSockets on its own port too, for the web page in `web/` (see `spec/PROTOCOL.md`). A
page served over https may only open `wss://`, so give the Hop's host name a TLS site that passes
everything to the Hop. With the Compose file:

1. Add `networks: [default, web]` to the `hop` service, so Caddy can reach it.
2. Set `HOP_FORWARDED_FROM: 172.31.0.0/24` (the `web` subnet) on the `hop` service, so each browser keeps
   its own limits.
3. Add a site for the Hop's name to the `Caddyfile` (the name must point at the server):

```
hop.example.com {
	reverse_proxy hop:4677
}
```

Apps keep using `hop.example.com:4677` over TCP. The page uses `wss://hop.example.com/`.

Every Hop limit must be at least 1, or the Hop refuses to start. The limits are described in
[PROTOCOL.md](../spec/PROTOCOL.md).

## Ports and endpoints

| Port | Service | Notes |
|------|---------|-------|
| 8080/tcp | den | HTTP. Not published by Compose: Caddy reaches it on the `web` network. |
| 4677/tcp | hop | Relay. Published directly by Compose. |
| 80/tcp, 443/tcp, 443/udp | caddy | TLS for `DEN_HOST`. |

The API is read-only: there is no `PUT` or `DELETE`, and nothing is published over HTTP. Publishing, deleting
an item and deleting the account are MCP tools at `/mcp`.

| Method | Path | Purpose |
|--------|------|---------|
| `GET` | `/healthz` | Health check. Used by the `healthcheck` command of both programs. |
| `GET` | `/version` | Release, API and format versions, MCP revisions. |
| `GET` | `/challenge` | A fresh ALTCHA challenge, for the sign-in page. |
| `GET` | `/items` | Search (`type`, `q`, `tag`, `handle`, `sort`, `limit`, `cursor`). |
| `GET` | `/items/{handle}/{slug}` | One item. |
| `GET` | `/items/{handle}/{slug}/document.json` | The item's document, with an `ETag`. |
| `POST` | `/items/{handle}/{slug}/installs` | Count an install. |
| `POST` | `/items/{handle}/{slug}/reports` | Report an item. |
| `GET` | `/accounts/{handle}` | An account's page. |
| `GET` | `/stats` | Gallery statistics. |
| `GET` | `/.well-known/oauth-protected-resource`, `/.well-known/oauth-authorization-server` | OAuth discovery. |
| `POST` | `/oauth/register` | Dynamic client registration. |
| `GET`, `POST` | `/oauth/authorize` | The sign-in page and its form. |
| `POST` | `/oauth/token`, `/oauth/revoke` | Token exchange, refresh and revocation. |
| `POST` | `/mcp` | The MCP endpoint (search, get, download, the document format, publish, delete). |
| `GET` | `/`, `/i/{handle}/{slug}`, `/a/{handle}` | The web gallery. |
| `GET` | `/assets/{file}` | Files of the web gallery. |

The full wire contract is in [PROTOCOL.md](../spec/PROTOCOL.md).

## Operating with `den admin`

There is no HTTP admin surface. Run the commands next to the database (the image sets `DEN_DATABASE`, so
they act on the running Den's file):

```sh
docker compose exec den /usr/local/bin/den admin reported
docker compose exec den /usr/local/bin/den admin hide <handle>/<slug>
docker compose exec den /usr/local/bin/den admin unhide <handle>/<slug>
docker compose exec den /usr/local/bin/den admin remove <handle>/<slug>
docker compose exec den /usr/local/bin/den admin deactivate <handle>
docker compose exec den /usr/local/bin/den admin reactivate <handle>
docker compose exec den /usr/local/bin/den admin remove-account <handle>
docker compose exec den /usr/local/bin/den admin backup <file>
```

`deactivate` stops an account at once: it cannot sign in, its tokens answer 401 and its items are hidden.
`reactivate` undoes that. `remove-account` deletes the account and everything it shared. Changes show once the
30 second caches turn over. An item reported from 5 different addresses is hidden. Nothing unhides it
automatically: review it with `den admin reported`, then run `den admin unhide <handle>/<slug>` to show it again.

## Tests

The Den's checks run in-process, with no network and no browser:

```sh
cargo test -p imp-den
cargo clippy -p imp-den --all-targets -- -D warnings
```

`server/den/tests/api.rs` covers OAuth, MCP, the read API, quotas and rate limits.

The Docker end-to-end test goes over real HTTP against the built image (it needs Docker):

```sh
docker build -f server/Dockerfile -t imp-den-e2e .
docker run -d --name den-e2e -p 8099:8080 -e DEN_ADDR=0.0.0.0:8080 \
  -e DEN_PUBLIC_URL=http://localhost:8099 -e DEN_SECRET="$(openssl rand -base64 48)" imp-den-e2e serve
DEN_E2E_URL=http://localhost:8099 cargo test -p imp-den --test e2e -- --ignored --nocapture full_flow
docker exec den-e2e den admin deactivate <handle printed by the test, or in .agent-logs/e2e-session.json>
DEN_E2E_URL=http://localhost:8099 cargo test -p imp-den --test e2e -- --ignored --nocapture deactivated_account_is_refused
docker rm -f den-e2e && docker rmi imp-den-e2e
```

`full_flow` signs up, runs OAuth with PKCE, publishes one item of each type and checks search, download,
ETag, deletion and refresh rotation. The second test checks that the deactivated account's token gets 401.
Set `DEN_E2E_STATE` to move the file that carries the handle and token between them.

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
