//! The Den's behaviour, shared by the REST API, the MCP tools and the sign-in page: accounts, OAuth
//! grants, items, installs, reports, stats, and the limits around all of them.
//! Split by concern: `limits` (rate limiters), `model` (wire types), `accounts`, `oauth` (clients, codes
//! and tokens), `items`, `cursor` (list paging).

mod accounts;
mod cursor;
mod items;
mod limits;
mod model;
mod oauth;

use limits::{Limits, gate};

pub use model::*;
pub use oauth::{AuthRequest, Client, OAuthError, SCOPE, TokenSet};

use std::sync::Arc;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use altcha::{CreateChallengeOptions, VerifySolutionOptions};
use base64::Engine;
use base64::engine::general_purpose::{STANDARD, URL_SAFE_NO_PAD};
use imp_shared::ip::IpKey;
use imp_shared::limit::KeyedLimiter;
use moka::sync::Cache;
use schemars::JsonSchema;
use serde::{Deserialize, Serialize};
use serde_json::Value;
use sha2::{Digest, Sha256};
use sqlx::sqlite::SqliteRow;
use sqlx::{QueryBuilder, Row, Sqlite, SqlitePool};
use time::OffsetDateTime;
use time::format_description::well_known::Rfc3339;
use tokio::sync::watch;

use crate::config::Config;
use crate::crypto::{hmac_sha256, sha256_hex};
use crate::error::{Error, Violation};
use crate::installs::Installs;
use crate::kit::{self, Counts, Kind};
use crate::meta;

const CHALLENGE_LIFETIME_SECS: i64 = 600;
const CHALLENGE_ALGORITHM: &str = "PBKDF2/SHA-256";
const MAX_ITEMS_PER_ACCOUNT: i64 = 100;
const MAX_BYTES_PER_ACCOUNT: i64 = 2 * 1024 * 1024;
const MAX_NEW_ITEMS_PER_DAY: i64 = 20;
const REPORTS_TO_HIDE: i64 = 5;
const CACHE_TTL: Duration = Duration::from_secs(30);
/// The prefix of the account key, of an access token and of a refresh token.
const KEY_PREFIX: &str = "dak_";
const ACCESS_PREFIX: &str = "dat_";
const REFRESH_PREFIX: &str = "drt_";
/// Where items are visible: not hidden by reports or the operator, and the account not deactivated.
const VISIBLE: &str = "hidden = 0 AND suspended = 0";

/// Who is asking: the client's address key and the bearer token they sent, if any.
#[derive(Debug, Clone)]
pub struct Caller {
    pub ip: IpKey,
    pub token: Option<String>,
}

pub struct Den {
    pub config: Config,
    pool: SqlitePool,
    limits: Limits,
    lists: Cache<String, Arc<ItemList>>,
    stats: Cache<(), Arc<Stats>>,
    installs: Installs,
}

fn now() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .ok()
        .and_then(|d| i64::try_from(d.as_secs()).ok())
        .unwrap_or_default()
}

fn stamp(seconds: i64) -> String {
    OffsetDateTime::from_unix_timestamp(seconds)
        .ok()
        .and_then(|t| t.format(&Rfc3339).ok())
        .unwrap_or_default()
}

/// A fresh secret: `prefix` and 43 base64url characters (256 random bits).
fn new_secret(prefix: &str) -> String {
    format!(
        "{prefix}{}",
        URL_SAFE_NO_PAD.encode(rand::random::<[u8; 32]>())
    )
}

/// Whether `secret` has the form `new_secret(prefix)` makes.
fn secret_shaped(secret: &str, prefix: &str) -> bool {
    secret.len() == prefix.len() + 43
        && secret.starts_with(prefix)
        && secret[prefix.len()..]
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_')
}

fn bad(detail: impl Into<String>) -> Error {
    Error::BadRequest(detail.into())
}

fn parse_json<T: serde::de::DeserializeOwned>(text: &str) -> Result<T, Error> {
    serde_json::from_str(text).map_err(|e| {
        tracing::error!(error = %e, "stored JSON is unreadable");
        Error::Internal
    })
}

impl Den {
    pub async fn new(config: Config, pool: SqlitePool) -> Arc<Self> {
        Arc::new(Self {
            config,
            pool,
            limits: Limits::new(),
            lists: Cache::builder()
                .max_capacity(500)
                .time_to_live(CACHE_TTL)
                .build(),
            stats: Cache::builder()
                .max_capacity(1)
                .time_to_live(CACHE_TTL)
                .build(),
            installs: Installs::new(),
        })
    }

    pub fn pool(&self) -> &SqlitePool {
        &self.pool
    }

    fn forget_cached(&self) {
        self.lists.invalidate_all();
        self.stats.invalidate_all();
    }

    pub async fn ping(&self) -> Result<(), Error> {
        sqlx::query("SELECT 1").execute(&self.pool).await?;
        Ok(())
    }

    /// Housekeeping every minute: install counts to disk, expired rows and idle limiter keys
    /// forgotten. Writes the install counts one last time when `stop` fires.
    pub async fn maintain(self: Arc<Self>, mut stop: watch::Receiver<bool>) {
        let mut tick = tokio::time::interval(Duration::from_secs(60));
        tick.tick().await;
        loop {
            tokio::select! {
                _ = tick.tick() => {}
                _ = stop.changed() => {
                    self.flush_installs().await;
                    return;
                }
            }
            self.flush_installs().await;
            if let Err(e) = self.sweep_database().await {
                tracing::error!(error = %e, "cleaning the database failed");
            }
            self.limits.sweep();
        }
    }

    /// Forgets what has run out: spent challenges, codes, tokens, items-made records of past days and
    /// clients that never got anywhere.
    async fn sweep_database(&self) -> Result<(), sqlx::Error> {
        let now = now();
        for (sql, before) in [
            ("DELETE FROM spent_challenges WHERE expires_at < ?1", now),
            ("DELETE FROM codes WHERE expires_at < ?1", now),
            ("DELETE FROM tokens WHERE expires_at < ?1", now),
            ("DELETE FROM new_items WHERE created_at < ?1", now - 86_400),
            (
                "DELETE FROM clients WHERE created_at < ?1 \
                 AND NOT EXISTS (SELECT 1 FROM grants WHERE grants.client_id = clients.client_id) \
                 AND NOT EXISTS (SELECT 1 FROM codes WHERE codes.client_id = clients.client_id)",
                now - 7 * 86_400,
            ),
        ] {
            sqlx::query(sql).bind(before).execute(&self.pool).await?;
        }
        Ok(())
    }

    pub async fn flush_installs(&self) {
        self.installs.flush(&self.pool).await;
    }
}
