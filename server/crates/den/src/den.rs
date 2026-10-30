//! The Den's behaviour, shared by the REST API and the MCP tools: accounts, items, installs,
//! reports, stats, and the limits around all of them.

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
const REPORTS_TO_HIDE: i64 = 5;
const CACHE_TTL: Duration = Duration::from_secs(30);
const TOKEN_PREFIX: &str = "den_";

/// Who is asking: the client's address key and the bearer token they sent, if any.
#[derive(Debug, Clone)]
pub struct Caller {
    pub ip: IpKey,
    pub token: Option<String>,
}

struct Limits {
    reads: KeyedLimiter<IpKey>,
    challenges: KeyedLimiter<IpKey>,
    attempts: KeyedLimiter<IpKey>,
    accounts: KeyedLimiter<IpKey>,
    reports: KeyedLimiter<IpKey>,
    installs: KeyedLimiter<IpKey>,
    writes_by_ip: KeyedLimiter<IpKey>,
    writes_by_account: KeyedLimiter<String>,
}

impl Limits {
    fn new() -> Self {
        Self {
            reads: KeyedLimiter::per_minute(240),
            challenges: KeyedLimiter::per_minute(20),
            attempts: KeyedLimiter::per_minute(20),
            accounts: KeyedLimiter::per_day(3),
            reports: KeyedLimiter::per_hour(10),
            installs: KeyedLimiter::per_hour(120),
            writes_by_ip: KeyedLimiter::per_hour(30),
            writes_by_account: KeyedLimiter::per_hour(30),
        }
    }

    fn sweep(&self) {
        self.reads.sweep();
        self.challenges.sweep();
        self.attempts.sweep();
        self.accounts.sweep();
        self.reports.sweep();
        self.installs.sweep();
        self.writes_by_ip.sweep();
        self.writes_by_account.sweep();
    }
}

fn gate<K: std::hash::Hash + Eq + Clone>(limiter: &KeyedLimiter<K>, key: &K) -> Result<(), Error> {
    limiter.check(key).map_err(Error::RateLimited)
}

pub struct Den {
    pub config: Config,
    pool: SqlitePool,
    limits: Limits,
    lists: Cache<String, Arc<ItemList>>,
    stats: Cache<(), Arc<Stats>>,
    installs: Installs,
}

// ---- what goes over the wire

#[derive(Debug, Serialize)]
pub struct Created {
    pub handle: String,
    pub token: String,
    pub created_at: String,
}

#[derive(Debug, Clone, Serialize)]
pub struct ItemSummary {
    #[serde(skip)]
    id: i64,
    pub handle: String,
    pub slug: String,
    pub kind: String,
    pub name: String,
    pub summary: String,
    pub tags: Vec<String>,
    pub runs_programs: bool,
    pub installs: i64,
    pub revision: i64,
    pub created_at: String,
    pub updated_at: String,
}

#[derive(Debug, Clone, Serialize)]
pub struct Item {
    #[serde(flatten)]
    pub summary: ItemSummary,
    pub about: String,
    pub sha256: String,
    pub size: i64,
    pub kit_url: String,
    pub counts: Counts,
}

#[derive(Debug, Serialize)]
pub struct ItemList {
    pub items: Vec<ItemSummary>,
    pub next_cursor: Option<String>,
}

#[derive(Debug, Serialize)]
pub struct AccountView {
    pub handle: String,
    pub created_at: String,
    pub items: Vec<ItemSummary>,
}

#[derive(Debug, Serialize)]
pub struct Stats {
    pub accounts: i64,
    pub items: i64,
    pub installs: i64,
    pub by_kind: ByKind,
}

/// Visible items of each kind.
#[derive(Debug, Default, Serialize)]
pub struct ByKind {
    pub imp: i64,
    pub animation: i64,
    pub trigger: i64,
    pub tool: i64,
    pub kit: i64,
}

/// A kit as kept, with the validators clients cache it by.
#[derive(Debug)]
pub struct KitDoc {
    pub text: String,
    pub etag: String,
}

#[derive(Debug, Default, Deserialize, JsonSchema)]
pub struct ListQuery {
    /// One of `imp`, `animation`, `trigger`, `tool`, `kit`.
    pub kind: Option<String>,
    /// A single tag, for example `fun`.
    pub tag: Option<String>,
    /// Words to look for in the name, summary and about text. Case-insensitive.
    pub q: Option<String>,
    /// `new` (default) or `popular`.
    pub sort: Option<String>,
    /// How many items, 1 to 50 (default 20).
    pub limit: Option<u32>,
    /// The `next_cursor` of the previous page.
    pub cursor: Option<String>,
}

#[derive(Debug, Deserialize, JsonSchema)]
pub struct PutItem {
    /// One line of at most 120 characters.
    pub summary: String,
    /// 1 to 5 tags of lowercase letters, digits and dashes, up to 24 characters each.
    pub tags: Vec<String>,
    /// The kit: the JSON Imp exports, with `imp` (format 1 to 3) and a `name`.
    pub kit: Value,
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum Sort {
    New,
    Popular,
}

const SUMMARY_COLUMNS: &str = "id, handle, slug, kind, name, summary, tags, runs_programs, installs, revision, created_at, updated_at";
const DETAIL_COLUMNS: &str = "id, handle, slug, kind, name, summary, tags, runs_programs, installs, revision, \
                              created_at, updated_at, about, sha256, size, counts";

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

    /// Housekeeping every minute: install counts to disk, spent challenges and idle limiter keys
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
            let swept = sqlx::query("DELETE FROM spent_challenges WHERE expires_at < ?1")
                .bind(now())
                .execute(&self.pool)
                .await;
            if let Err(e) = swept {
                tracing::error!(error = %e, "cleaning spent challenges failed");
            }
            self.limits.sweep();
        }
    }

    pub async fn flush_installs(&self) {
        self.installs.flush(&self.pool).await;
    }

    // ---- accounts

    pub fn challenge(&self, caller: &Caller) -> Result<altcha::Challenge, Error> {
        gate(&self.limits.challenges, &caller.ip)?;
        let options = CreateChallengeOptions {
            algorithm: CHALLENGE_ALGORITHM.to_owned(),
            cost: self.config.altcha_cost,
            expires_at: Some(now() + CHALLENGE_LIFETIME_SECS),
            hmac_signature_secret: Some(self.config.secret.clone()),
            ..CreateChallengeOptions::default()
        };
        altcha::create_challenge(options).map_err(|e| {
            tracing::error!(error = %e, "creating a challenge failed");
            Error::Internal
        })
    }

    /// Checks a solved challenge. Returns its signature and when it expires. Does not spend it.
    async fn check_solution(&self, encoded: &str) -> Result<(String, i64), Error> {
        let failed = |detail: &str| Error::Challenge(detail.to_owned());
        if encoded.len() > 4096 {
            return Err(failed("The proof is too long."));
        }
        let bytes = STANDARD
            .decode(encoded)
            .map_err(|_| failed("The proof isn't valid base64."))?;
        let payload: altcha::Payload = serde_json::from_slice(&bytes)
            .map_err(|_| failed("The proof isn't a solved challenge."))?;
        let signature = payload
            .challenge
            .signature
            .clone()
            .ok_or_else(|| failed("The challenge isn't signed."))?;
        let expires = payload
            .challenge
            .parameters
            .expires_at
            .filter(|t| *t > 0)
            .ok_or_else(|| failed("The challenge has no expiry."))?;
        if expires < now() {
            return Err(failed("The challenge has expired. Ask for a new one."));
        }
        let spent = sqlx::query("SELECT 1 FROM spent_challenges WHERE signature = ?1")
            .bind(&signature)
            .fetch_optional(&self.pool)
            .await?;
        if spent.is_some() {
            return Err(failed("The challenge was already used. Ask for a new one."));
        }
        let secret = self.config.secret.clone();
        let verdict = tokio::task::spawn_blocking(move || {
            altcha::verify_solution(VerifySolutionOptions::new(
                &payload.challenge,
                &payload.solution,
                secret,
            ))
        })
        .await
        .map_err(|_| Error::Internal)?;
        match verdict {
            Ok(result) if result.verified => Ok((signature, expires)),
            Ok(result) if result.expired => {
                Err(failed("The challenge has expired. Ask for a new one."))
            }
            _ => Err(failed("The challenge isn't solved.")),
        }
    }

    pub async fn create_account(
        &self,
        caller: &Caller,
        handle: &str,
        altcha: &str,
    ) -> Result<Created, Error> {
        gate(&self.limits.attempts, &caller.ip)?;
        if let Some(problem) = meta::handle_problem(handle) {
            return Err(Error::invalid("/handle", problem));
        }
        let (signature, expires) = self.check_solution(altcha).await?;
        gate(&self.limits.accounts, &caller.ip)?;

        let token = format!(
            "{TOKEN_PREFIX}{}",
            URL_SAFE_NO_PAD.encode(rand::random::<[u8; 32]>())
        );
        let created = now();
        let mut tx = self.pool.begin_with("BEGIN IMMEDIATE").await?;
        let spent = sqlx::query(
            "INSERT OR IGNORE INTO spent_challenges (signature, expires_at) VALUES (?1, ?2)",
        )
        .bind(&signature)
        .bind(expires)
        .execute(&mut *tx)
        .await?;
        if spent.rows_affected() == 0 {
            return Err(Error::Challenge(
                "The challenge was already used. Ask for a new one.".to_owned(),
            ));
        }
        let inserted = sqlx::query(
            "INSERT INTO accounts (handle, token_hash, created_at) VALUES (?1, ?2, ?3)",
        )
        .bind(handle)
        .bind(sha256_hex(token.as_bytes()))
        .bind(created)
        .execute(&mut *tx)
        .await;
        match inserted {
            Ok(_) => {}
            Err(sqlx::Error::Database(e)) if e.is_unique_violation() => {
                return Err(Error::HandleTaken);
            }
            Err(e) => return Err(e.into()),
        }
        tx.commit().await?;
        self.stats.invalidate_all();
        Ok(Created {
            handle: handle.to_owned(),
            token,
            created_at: stamp(created),
        })
    }

    async fn authenticate(&self, caller: &Caller) -> Result<String, Error> {
        gate(&self.limits.reads, &caller.ip)?;
        let token = caller.token.as_deref().ok_or(Error::Unauthorized)?;
        let well_formed = token.len() == 47
            && token.starts_with(TOKEN_PREFIX)
            && token[TOKEN_PREFIX.len()..]
                .bytes()
                .all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_');
        if !well_formed {
            return Err(Error::Unauthorized);
        }
        sqlx::query_scalar::<_, String>("SELECT handle FROM accounts WHERE token_hash = ?1")
            .bind(sha256_hex(token.as_bytes()))
            .fetch_optional(&self.pool)
            .await?
            .ok_or(Error::Unauthorized)
    }

    /// Authenticates and spends one write from the account's and the address's allowance.
    async fn authorize_write(&self, caller: &Caller) -> Result<String, Error> {
        let handle = self.authenticate(caller).await?;
        gate(&self.limits.writes_by_account, &handle)?;
        gate(&self.limits.writes_by_ip, &caller.ip)?;
        Ok(handle)
    }

    pub async fn account(&self, caller: &Caller, handle: &str) -> Result<AccountView, Error> {
        gate(&self.limits.reads, &caller.ip)?;
        let created =
            sqlx::query_scalar::<_, i64>("SELECT created_at FROM accounts WHERE handle = ?1")
                .bind(handle)
                .fetch_optional(&self.pool)
                .await?
                .ok_or(Error::NotFound)?;
        let mut sql = QueryBuilder::<Sqlite>::new(format!(
            "SELECT {SUMMARY_COLUMNS} FROM items WHERE handle = "
        ));
        sql.push_bind(handle);
        sql.push(" AND hidden = 0 ORDER BY id DESC LIMIT ");
        sql.push_bind(MAX_ITEMS_PER_ACCOUNT);
        let rows = sql.build().fetch_all(&self.pool).await?;
        let items = rows.iter().map(summary_of).collect::<Result<_, _>>()?;
        Ok(AccountView {
            handle: handle.to_owned(),
            created_at: stamp(created),
            items,
        })
    }

    pub async fn delete_account(&self, caller: &Caller) -> Result<(), Error> {
        let handle = self.authorize_write(caller).await?;
        sqlx::query("DELETE FROM accounts WHERE handle = ?1")
            .bind(&handle)
            .execute(&self.pool)
            .await?;
        self.forget_cached();
        Ok(())
    }

    // ---- items

    pub async fn list(&self, caller: &Caller, query: ListQuery) -> Result<Arc<ItemList>, Error> {
        gate(&self.limits.reads, &caller.ip)?;
        let kind = query
            .kind
            .as_deref()
            .map(|k| {
                Kind::parse(k)
                    .ok_or_else(|| bad("`kind` is not one of imp, animation, trigger, tool, kit."))
            })
            .transpose()?;
        let sort = match query.sort.as_deref() {
            None | Some("new") => Sort::New,
            Some("popular") => Sort::Popular,
            Some(_) => return Err(bad("`sort` is `new` or `popular`.")),
        };
        let limit = query.limit.unwrap_or(20);
        if !(1..=50).contains(&limit) {
            return Err(bad("`limit` is 1 to 50."));
        }
        if let Some(tag) = &query.tag
            && meta::tag_problem(tag).is_some()
        {
            return Err(bad("`tag` is a single tag of a-z, 0-9 and dashes."));
        }
        let text = query.q.as_deref().map(str::trim).filter(|q| !q.is_empty());
        if text.is_some_and(|q| q.chars().count() > 100) {
            return Err(bad("`q` is at most 100 characters."));
        }
        let cursor = query
            .cursor
            .as_deref()
            .map(|c| decode_cursor(c, sort))
            .transpose()?;

        let cache_key = format!(
            "{:?}|{:?}|{:?}|{}|{limit}|{:?}",
            kind,
            query.tag,
            text,
            u8::from(sort == Sort::Popular),
            query.cursor
        );
        if let Some(hit) = self.lists.get(&cache_key) {
            return Ok(hit);
        }

        let mut sql = QueryBuilder::<Sqlite>::new(format!(
            "SELECT {SUMMARY_COLUMNS} FROM items WHERE hidden = 0"
        ));
        if let Some(kind) = kind {
            sql.push(" AND kind = ").push_bind(kind.as_str());
        }
        if let Some(tag) = &query.tag {
            sql.push(" AND EXISTS (SELECT 1 FROM json_each(items.tags) WHERE value = ")
                .push_bind(tag.clone())
                .push(")");
        }
        if let Some(text) = text {
            let like = format!(
                "%{}%",
                text.replace('\\', "\\\\")
                    .replace('%', "\\%")
                    .replace('_', "\\_")
            );
            sql.push(" AND (name LIKE ").push_bind(like.clone());
            sql.push(" ESCAPE '\\' OR summary LIKE ")
                .push_bind(like.clone());
            sql.push(" ESCAPE '\\' OR about LIKE ")
                .push_bind(like)
                .push(" ESCAPE '\\')");
        }
        match (sort, cursor) {
            (Sort::New, Some((_, id))) => {
                sql.push(" AND id < ").push_bind(id);
            }
            (Sort::Popular, Some((installs, id))) => {
                sql.push(" AND (installs < ").push_bind(installs);
                sql.push(" OR (installs = ")
                    .push_bind(installs)
                    .push(" AND id < ")
                    .push_bind(id)
                    .push("))");
            }
            (_, None) => {}
        }
        sql.push(match sort {
            Sort::New => " ORDER BY id DESC",
            Sort::Popular => " ORDER BY installs DESC, id DESC",
        });
        sql.push(" LIMIT ").push_bind(i64::from(limit) + 1);
        let rows = sql.build().fetch_all(&self.pool).await?;
        let mut items = rows.iter().map(summary_of).collect::<Result<Vec<_>, _>>()?;
        let next_cursor = if items.len() > usize::try_from(limit).unwrap_or(usize::MAX) {
            items.truncate(usize::try_from(limit).unwrap_or(usize::MAX));
            items
                .last()
                .map(|last| encode_cursor(sort, last.installs, last.id))
        } else {
            None
        };
        let list = Arc::new(ItemList { items, next_cursor });
        self.lists.insert(cache_key, Arc::clone(&list));
        Ok(list)
    }

    async fn fetch_item(
        &self,
        handle: &str,
        slug: &str,
        include_hidden: bool,
    ) -> Result<Item, Error> {
        let mut sql = QueryBuilder::<Sqlite>::new(format!(
            "SELECT {DETAIL_COLUMNS} FROM items WHERE handle = "
        ));
        sql.push_bind(handle);
        sql.push(" AND slug = ");
        sql.push_bind(slug);
        sql.push(" AND (hidden = 0 OR ");
        sql.push_bind(include_hidden);
        sql.push(")");
        let row = sql
            .build()
            .fetch_optional(&self.pool)
            .await?
            .ok_or(Error::NotFound)?;
        Ok(Item {
            summary: summary_of(&row)?,
            about: row.try_get("about")?,
            sha256: row.try_get("sha256")?,
            size: row.try_get("size")?,
            kit_url: format!(
                "{}/v1/items/{handle}/{slug}/kit.json",
                self.config.public.origin
            ),
            counts: parse_json(&row.try_get::<String, _>("counts")?)?,
        })
    }

    pub async fn item(&self, caller: &Caller, handle: &str, slug: &str) -> Result<Item, Error> {
        gate(&self.limits.reads, &caller.ip)?;
        self.fetch_item(handle, slug, false).await
    }

    pub async fn kit(&self, caller: &Caller, handle: &str, slug: &str) -> Result<KitDoc, Error> {
        gate(&self.limits.reads, &caller.ip)?;
        let row = sqlx::query("SELECT kit, sha256, revision FROM items WHERE handle = ?1 AND slug = ?2 AND hidden = 0")
            .bind(handle)
            .bind(slug)
            .fetch_optional(&self.pool)
            .await?
            .ok_or(Error::NotFound)?;
        let sha256: String = row.try_get("sha256")?;
        let revision: i64 = row.try_get("revision")?;
        Ok(KitDoc {
            text: row.try_get("kit")?,
            etag: format!("\"{sha256}-{revision}\""),
        })
    }

    pub async fn put_item(
        &self,
        caller: &Caller,
        handle: &str,
        slug: &str,
        body: PutItem,
    ) -> Result<(bool, Item), Error> {
        let owner = self.authorize_write(caller).await?;
        if owner != handle {
            return Err(Error::Forbidden(
                "You can only publish under your own handle.".to_owned(),
            ));
        }
        let mut problems: Vec<Violation> = Vec::new();
        if let Some(problem) = meta::slug_problem(slug) {
            problems.push(Violation {
                pointer: "/slug".to_owned(),
                detail: problem.to_owned(),
            });
        }
        problems.extend(meta::label_problems(&body.summary, &body.tags));
        let checked = match kit::check(body.kit) {
            Ok(checked) => Some(checked),
            Err(found) => {
                problems.extend(found.into_iter().map(|v| Violation {
                    pointer: format!("/kit{}", v.pointer),
                    detail: v.detail,
                }));
                None
            }
        };
        let Some(checked) = checked.filter(|_| problems.is_empty()) else {
            return Err(Error::Invalid(problems));
        };
        let tags = serde_json::to_string(&body.tags).map_err(|_| Error::Internal)?;
        let counts = serde_json::to_string(&checked.counts).map_err(|_| Error::Internal)?;
        let stamp_now = now();

        let mut tx = self.pool.begin_with("BEGIN IMMEDIATE").await?;
        let existing =
            sqlx::query_scalar::<_, i64>("SELECT id FROM items WHERE handle = ?1 AND slug = ?2")
                .bind(handle)
                .bind(slug)
                .fetch_optional(&mut *tx)
                .await?;
        let created = existing.is_none();
        match existing {
            Some(id) => {
                sqlx::query(
                    "UPDATE items SET kind = ?1, name = ?2, about = ?3, summary = ?4, tags = ?5, kit = ?6, counts = ?7, \
                     sha256 = ?8, size = ?9, revision = revision + 1, runs_programs = ?10, updated_at = ?11 WHERE id = ?12",
                )
                .bind(checked.kind.as_str())
                .bind(&checked.name)
                .bind(&checked.about)
                .bind(body.summary.trim())
                .bind(&tags)
                .bind(&checked.text)
                .bind(&counts)
                .bind(&checked.sha256)
                .bind(i64::try_from(checked.text.len()).unwrap_or(i64::MAX))
                .bind(checked.runs_programs)
                .bind(stamp_now)
                .bind(id)
                .execute(&mut *tx)
                .await?;
            }
            None => {
                let owned =
                    sqlx::query_scalar::<_, i64>("SELECT COUNT(*) FROM items WHERE handle = ?1")
                        .bind(handle)
                        .fetch_one(&mut *tx)
                        .await?;
                if owned >= MAX_ITEMS_PER_ACCOUNT {
                    return Err(Error::Quota(format!(
                        "An account can share at most {MAX_ITEMS_PER_ACCOUNT} items."
                    )));
                }
                sqlx::query(
                    "INSERT INTO items (handle, slug, kind, name, about, summary, tags, kit, counts, sha256, size, revision, \
                     runs_programs, created_at, updated_at) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, 1, ?12, ?13, ?13)",
                )
                .bind(handle)
                .bind(slug)
                .bind(checked.kind.as_str())
                .bind(&checked.name)
                .bind(&checked.about)
                .bind(body.summary.trim())
                .bind(&tags)
                .bind(&checked.text)
                .bind(&counts)
                .bind(&checked.sha256)
                .bind(i64::try_from(checked.text.len()).unwrap_or(i64::MAX))
                .bind(checked.runs_programs)
                .bind(stamp_now)
                .execute(&mut *tx)
                .await?;
            }
        }
        tx.commit().await?;
        self.forget_cached();
        Ok((created, self.fetch_item(handle, slug, true).await?))
    }

    pub async fn delete_item(
        &self,
        caller: &Caller,
        handle: &str,
        slug: &str,
    ) -> Result<(), Error> {
        let owner = self.authorize_write(caller).await?;
        if owner != handle {
            return Err(Error::Forbidden(
                "You can only delete your own items.".to_owned(),
            ));
        }
        let gone = sqlx::query("DELETE FROM items WHERE handle = ?1 AND slug = ?2")
            .bind(handle)
            .bind(slug)
            .execute(&self.pool)
            .await?;
        if gone.rows_affected() == 0 {
            return Err(Error::NotFound);
        }
        self.forget_cached();
        Ok(())
    }

    async fn visible_id(&self, handle: &str, slug: &str) -> Result<i64, Error> {
        sqlx::query_scalar::<_, i64>(
            "SELECT id FROM items WHERE handle = ?1 AND slug = ?2 AND hidden = 0",
        )
        .bind(handle)
        .bind(slug)
        .fetch_optional(&self.pool)
        .await?
        .ok_or(Error::NotFound)
    }

    pub async fn install(&self, caller: &Caller, handle: &str, slug: &str) -> Result<(), Error> {
        gate(&self.limits.installs, &caller.ip)?;
        let id = self.visible_id(handle, slug).await?;
        self.installs.count(id, &caller.ip);
        Ok(())
    }

    pub async fn report(
        &self,
        caller: &Caller,
        handle: &str,
        slug: &str,
        reason: &str,
    ) -> Result<(), Error> {
        gate(&self.limits.reports, &caller.ip)?;
        let reason = reason.trim();
        if reason.is_empty() || reason.chars().count() > 500 {
            return Err(Error::invalid("/reason", "must be 1 to 500 characters"));
        }
        let id = self.visible_id(handle, slug).await?;
        let who = hmac_sha256(
            self.config.secret.as_bytes(),
            &[b"report:", caller.ip.to_string().as_bytes()],
        )
        .ok_or(Error::Internal)?;
        let added = sqlx::query("INSERT OR IGNORE INTO reports (item, ip_key_hash, reason, created_at) VALUES (?1, ?2, ?3, ?4)")
            .bind(id)
            .bind(hex::encode(who))
            .bind(reason)
            .bind(now())
            .execute(&self.pool)
            .await?;
        if added.rows_affected() > 0 {
            let hidden = sqlx::query(
                "UPDATE items SET hidden = 1 WHERE id = ?1 AND hidden = 0 AND (SELECT COUNT(*) FROM reports WHERE item = ?1) >= ?2",
            )
            .bind(id)
            .bind(REPORTS_TO_HIDE)
            .execute(&self.pool)
            .await?;
            if hidden.rows_affected() > 0 {
                tracing::warn!(item = id, "item hidden after reports");
                self.forget_cached();
            }
        }
        Ok(())
    }

    pub async fn stats(&self, caller: &Caller) -> Result<Arc<Stats>, Error> {
        gate(&self.limits.reads, &caller.ip)?;
        if let Some(hit) = self.stats.get(&()) {
            return Ok(hit);
        }
        let row = sqlx::query(
            "SELECT (SELECT COUNT(*) FROM accounts) AS accounts, \
             (SELECT COUNT(*) FROM items WHERE hidden = 0) AS items, \
             (SELECT COALESCE(SUM(installs), 0) FROM items WHERE hidden = 0) AS installs",
        )
        .fetch_one(&self.pool)
        .await?;
        let mut by_kind = ByKind::default();
        let kinds =
            sqlx::query("SELECT kind, COUNT(*) AS n FROM items WHERE hidden = 0 GROUP BY kind")
                .fetch_all(&self.pool)
                .await?;
        for kind in kinds {
            let n: i64 = kind.try_get("n")?;
            match kind.try_get::<String, _>("kind")?.as_str() {
                "imp" => by_kind.imp = n,
                "animation" => by_kind.animation = n,
                "trigger" => by_kind.trigger = n,
                "tool" => by_kind.tool = n,
                _ => by_kind.kit += n,
            }
        }
        let stats = Arc::new(Stats {
            accounts: row.try_get("accounts")?,
            items: row.try_get("items")?,
            installs: row.try_get("installs")?,
            by_kind,
        });
        self.stats.insert((), Arc::clone(&stats));
        Ok(stats)
    }
}

fn summary_of(row: &SqliteRow) -> Result<ItemSummary, Error> {
    Ok(ItemSummary {
        id: row.try_get("id")?,
        handle: row.try_get("handle")?,
        slug: row.try_get("slug")?,
        kind: row.try_get("kind")?,
        name: row.try_get("name")?,
        summary: row.try_get("summary")?,
        tags: parse_json(&row.try_get::<String, _>("tags")?)?,
        runs_programs: row.try_get("runs_programs")?,
        installs: row.try_get("installs")?,
        revision: row.try_get("revision")?,
        created_at: stamp(row.try_get("created_at")?),
        updated_at: stamp(row.try_get("updated_at")?),
    })
}

fn encode_cursor(sort: Sort, installs: i64, id: i64) -> String {
    let plain = match sort {
        Sort::New => format!("n.{id}"),
        Sort::Popular => format!("p.{installs}.{id}"),
    };
    URL_SAFE_NO_PAD.encode(plain)
}

/// `(installs, id)` of the last item of the previous page. `installs` is unused when sorting by new.
fn decode_cursor(cursor: &str, sort: Sort) -> Result<(i64, i64), Error> {
    let invalid = || bad("`cursor` is not one this server gave out for this sort order.");
    let plain = URL_SAFE_NO_PAD
        .decode(cursor)
        .ok()
        .and_then(|b| String::from_utf8(b).ok())
        .ok_or_else(invalid)?;
    let parts: Vec<&str> = plain.split('.').collect();
    let number = |s: &str| s.parse::<i64>().ok().filter(|n| *n >= 0);
    match (sort, parts.as_slice()) {
        (Sort::New, ["n", id]) => Ok((0, number(id).ok_or_else(invalid)?)),
        (Sort::Popular, ["p", installs, id]) => Ok((
            number(installs).ok_or_else(invalid)?,
            number(id).ok_or_else(invalid)?,
        )),
        _ => Err(invalid()),
    }
}
