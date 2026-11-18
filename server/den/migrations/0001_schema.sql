-- An account is a handle. The only secret it has is the account key, kept as a SHA-256.
CREATE TABLE accounts (
    handle      TEXT PRIMARY KEY,
    key_hash    TEXT NOT NULL UNIQUE,
    created_at  INTEGER NOT NULL,
    deactivated INTEGER NOT NULL DEFAULT 0
) STRICT;

-- OAuth clients made by dynamic registration (RFC 7591). All are public clients.
CREATE TABLE clients (
    client_id     TEXT PRIMARY KEY,
    client_name   TEXT NOT NULL,
    redirect_uris TEXT NOT NULL,
    created_at    INTEGER NOT NULL
) STRICT;

-- What a person allowed one client to do. Revoking a grant ends every token of it.
CREATE TABLE grants (
    id         INTEGER PRIMARY KEY AUTOINCREMENT,
    client_id  TEXT NOT NULL REFERENCES clients (client_id) ON DELETE CASCADE,
    handle     TEXT NOT NULL REFERENCES accounts (handle) ON DELETE CASCADE,
    created_at INTEGER NOT NULL,
    revoked    INTEGER NOT NULL DEFAULT 0
) STRICT;

CREATE INDEX grants_handle ON grants (handle);

-- Authorization codes: 60 seconds, used once. Only the hash is kept.
CREATE TABLE codes (
    code_hash      TEXT PRIMARY KEY,
    client_id      TEXT NOT NULL REFERENCES clients (client_id) ON DELETE CASCADE,
    handle         TEXT NOT NULL REFERENCES accounts (handle) ON DELETE CASCADE,
    redirect_uri   TEXT NOT NULL,
    code_challenge TEXT NOT NULL,
    expires_at     INTEGER NOT NULL
) STRICT;

-- Access (`dat_`) and refresh (`drt_`) tokens. Only the hash is kept. A refresh token is marked used
-- when it is exchanged, and a second use of it revokes the grant.
CREATE TABLE tokens (
    hash       TEXT PRIMARY KEY,
    kind       TEXT NOT NULL,
    grant_id   INTEGER NOT NULL REFERENCES grants (id) ON DELETE CASCADE,
    handle     TEXT NOT NULL REFERENCES accounts (handle) ON DELETE CASCADE,
    expires_at INTEGER NOT NULL,
    used       INTEGER NOT NULL DEFAULT 0
) STRICT;

CREATE INDEX tokens_grant ON tokens (grant_id);
CREATE INDEX tokens_expiry ON tokens (expires_at);

CREATE TABLE items (
    id            INTEGER PRIMARY KEY AUTOINCREMENT,
    handle        TEXT NOT NULL REFERENCES accounts (handle) ON DELETE CASCADE,
    slug          TEXT NOT NULL,
    type          TEXT NOT NULL,
    format        INTEGER NOT NULL,
    name          TEXT NOT NULL,
    about         TEXT NOT NULL,
    summary       TEXT NOT NULL,
    tags          TEXT NOT NULL,
    document      TEXT NOT NULL,
    counts        TEXT NOT NULL,
    sha256        TEXT NOT NULL,
    size          INTEGER NOT NULL,
    revision      INTEGER NOT NULL,
    runs_programs INTEGER NOT NULL,
    installs      INTEGER NOT NULL DEFAULT 0,
    -- Hidden by reports or by the operator (`den admin hide`).
    hidden        INTEGER NOT NULL DEFAULT 0,
    -- Hidden because the account is deactivated (`den admin deactivate`).
    suspended     INTEGER NOT NULL DEFAULT 0,
    created_at    INTEGER NOT NULL,
    updated_at    INTEGER NOT NULL,
    UNIQUE (handle, slug)
) STRICT;

CREATE INDEX items_popular ON items (hidden, suspended, installs DESC, id DESC);
CREATE INDEX items_new ON items (hidden, suspended, id DESC);
CREATE INDEX items_sha256 ON items (sha256);

-- Items an account has made, kept after they are deleted, for the daily limit on new items.
CREATE TABLE new_items (
    handle     TEXT NOT NULL REFERENCES accounts (handle) ON DELETE CASCADE,
    created_at INTEGER NOT NULL
) STRICT;

CREATE INDEX new_items_handle ON new_items (handle, created_at);

CREATE TABLE reports (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    item        INTEGER NOT NULL REFERENCES items (id) ON DELETE CASCADE,
    ip_key_hash TEXT NOT NULL,
    reason      TEXT NOT NULL,
    created_at  INTEGER NOT NULL,
    UNIQUE (item, ip_key_hash)
) STRICT;

CREATE TABLE spent_challenges (
    signature  TEXT PRIMARY KEY,
    expires_at INTEGER NOT NULL
) STRICT;

CREATE INDEX spent_challenges_expiry ON spent_challenges (expires_at);
