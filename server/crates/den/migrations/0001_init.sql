CREATE TABLE accounts (
    handle     TEXT PRIMARY KEY,
    token_hash TEXT NOT NULL UNIQUE,
    created_at INTEGER NOT NULL
) STRICT;

CREATE TABLE items (
    id            INTEGER PRIMARY KEY AUTOINCREMENT,
    handle        TEXT NOT NULL REFERENCES accounts (handle) ON DELETE CASCADE,
    slug          TEXT NOT NULL,
    kind          TEXT NOT NULL,
    name          TEXT NOT NULL,
    about         TEXT NOT NULL,
    summary       TEXT NOT NULL,
    tags          TEXT NOT NULL,
    kit           TEXT NOT NULL,
    counts        TEXT NOT NULL,
    sha256        TEXT NOT NULL,
    size          INTEGER NOT NULL,
    revision      INTEGER NOT NULL,
    runs_programs INTEGER NOT NULL,
    installs      INTEGER NOT NULL DEFAULT 0,
    hidden        INTEGER NOT NULL DEFAULT 0,
    created_at    INTEGER NOT NULL,
    updated_at    INTEGER NOT NULL,
    UNIQUE (handle, slug)
) STRICT;

CREATE INDEX items_popular ON items (hidden, installs DESC, id DESC);

CREATE TABLE reports (
    id         INTEGER PRIMARY KEY AUTOINCREMENT,
    item       INTEGER NOT NULL REFERENCES items (id) ON DELETE CASCADE,
    ip_key_hash TEXT NOT NULL,
    reason     TEXT NOT NULL,
    created_at INTEGER NOT NULL,
    UNIQUE (item, ip_key_hash)
) STRICT;

CREATE TABLE spent_challenges (
    signature  TEXT PRIMARY KEY,
    expires_at INTEGER NOT NULL
) STRICT;
