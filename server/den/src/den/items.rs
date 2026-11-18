//! Items: list, read, download, publish, delete, install, report and stats.

use super::cursor::{Cursor, decode_cursor, encode_cursor};
use super::*;

pub(super) const SUMMARY_COLUMNS: &str = "id, handle, slug, type, format, name, summary, tags, runs_programs, installs, revision, created_at, updated_at";
const DETAIL_COLUMNS: &str = "id, handle, slug, type, format, name, summary, tags, runs_programs, installs, revision, \
                              created_at, updated_at, about, sha256, size, counts";

/// What an account has used of its quota.
pub(super) struct Usage {
    pub(super) items: i64,
    pub(super) bytes: i64,
    pub(super) new_today: i64,
}

impl Den {
    pub async fn list(&self, caller: &Caller, query: ListQuery) -> Result<Arc<ItemList>, Error> {
        gate(&self.limits.reads, &caller.ip)?;
        let kind = query
            .kind
            .as_deref()
            .map(|k| {
                Kind::parse(k)
                    .ok_or_else(|| bad("`type` is one of imp, animation, trigger, tool, kit."))
            })
            .transpose()?;
        let sort = match query.sort.as_deref() {
            None | Some("new") => Sort::New,
            Some("popular") => Sort::Popular,
            Some("name") => Sort::Name,
            Some(_) => return Err(bad("`sort` is `new`, `popular` or `name`.")),
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
        if let Some(handle) = &query.handle
            && !(handle.len() <= 32
                && handle
                    .bytes()
                    .all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'-'))
        {
            return Err(bad("`handle` is an account handle."));
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
            "{:?}|{:?}|{:?}|{:?}|{}|{limit}|{:?}",
            kind,
            query.tag,
            query.handle,
            text,
            query.sort.as_deref().unwrap_or("new"),
            query.cursor
        );
        if let Some(hit) = self.lists.get(&cache_key) {
            return Ok(hit);
        }

        let mut sql = QueryBuilder::<Sqlite>::new(format!(
            "SELECT {SUMMARY_COLUMNS} FROM items WHERE {VISIBLE}"
        ));
        if let Some(kind) = kind {
            sql.push(" AND type = ").push_bind(kind.as_str());
        }
        if let Some(tag) = &query.tag {
            sql.push(" AND EXISTS (SELECT 1 FROM json_each(items.tags) WHERE value = ")
                .push_bind(tag.clone())
                .push(")");
        }
        if let Some(handle) = &query.handle {
            sql.push(" AND handle = ").push_bind(handle.clone());
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
                .push_bind(like.clone());
            sql.push(
                " ESCAPE '\\' OR EXISTS (SELECT 1 FROM json_each(items.tags) WHERE value LIKE ",
            )
            .push_bind(like)
            .push(" ESCAPE '\\'))");
        }
        match cursor {
            Some(Cursor::New { id }) => {
                sql.push(" AND id < ").push_bind(id);
            }
            Some(Cursor::Popular { installs, id }) => {
                sql.push(" AND (installs < ").push_bind(installs);
                sql.push(" OR (installs = ")
                    .push_bind(installs)
                    .push(" AND id < ")
                    .push_bind(id)
                    .push("))");
            }
            Some(Cursor::Name { name, id }) => {
                sql.push(" AND (name COLLATE NOCASE > ")
                    .push_bind(name.clone());
                sql.push(" OR (name COLLATE NOCASE = ")
                    .push_bind(name)
                    .push(" AND id > ")
                    .push_bind(id)
                    .push("))");
            }
            None => {}
        }
        sql.push(match sort {
            Sort::New => " ORDER BY id DESC",
            Sort::Popular => " ORDER BY installs DESC, id DESC",
            Sort::Name => " ORDER BY name COLLATE NOCASE ASC, id ASC",
        });
        sql.push(" LIMIT ").push_bind(i64::from(limit) + 1);
        let rows = sql.build().fetch_all(&self.pool).await?;
        let mut items = rows.iter().map(summary_of).collect::<Result<Vec<_>, _>>()?;
        let limit = usize::try_from(limit).unwrap_or(usize::MAX);
        let next_cursor = if items.len() > limit {
            items.truncate(limit);
            items.last().map(|last| encode_cursor(sort, last))
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
        sql.push(format!(" AND ({VISIBLE} OR "));
        sql.push_bind(include_hidden);
        sql.push(")");
        let row = sql
            .build()
            .fetch_optional(&self.pool)
            .await?
            .ok_or(Error::NotFound)?;
        let document_url = format!(
            "{}/items/{handle}/{slug}/document.json",
            self.config.public.origin
        );
        Ok(Item {
            summary: summary_of(&row)?,
            about: row.try_get("about")?,
            sha256: row.try_get("sha256")?,
            size: row.try_get("size")?,
            open_url: format!("imp://add?url={}", meta::percent_encode(&document_url)),
            document_url,
            counts: parse_json(&row.try_get::<String, _>("counts")?)?,
        })
    }

    pub async fn item(&self, caller: &Caller, handle: &str, slug: &str) -> Result<Item, Error> {
        gate(&self.limits.reads, &caller.ip)?;
        self.fetch_item(handle, slug, false).await
    }

    async fn stored_document(&self, handle: &str, slug: &str) -> Result<StoredDocument, Error> {
        let row = sqlx::query(sqlx::AssertSqlSafe(format!(
            "SELECT document, sha256 FROM items WHERE handle = ?1 AND slug = ?2 AND {VISIBLE}"
        )))
        .bind(handle)
        .bind(slug)
        .fetch_optional(&self.pool)
        .await?
        .ok_or(Error::NotFound)?;
        // The document never changes without its sha256 changing, so the sha256 is the validator.
        Ok(StoredDocument {
            text: row.try_get("document")?,
            etag: format!("\"{}\"", row.try_get::<String, _>("sha256")?),
        })
    }

    /// The document as stored.
    pub async fn document(
        &self,
        caller: &Caller,
        handle: &str,
        slug: &str,
    ) -> Result<StoredDocument, Error> {
        gate(&self.limits.reads, &caller.ip)?;
        self.stored_document(handle, slug).await
    }

    /// The summary and the document of an item, and one install counted.
    pub async fn download(
        &self,
        caller: &Caller,
        handle: &str,
        slug: &str,
    ) -> Result<Download, Error> {
        gate(&self.limits.reads, &caller.ip)?;
        let item = self.fetch_item(handle, slug, false).await?;
        let stored = self.stored_document(handle, slug).await?;
        if self.limits.installs.check(&caller.ip).is_ok() {
            self.installs.count(item.summary.id, &caller.ip);
        }
        Ok(Download {
            item: item.summary,
            document: parse_json(&stored.text)?,
        })
    }

    pub(super) async fn usage(&self, handle: &str) -> Result<Usage, Error> {
        let row = sqlx::query(
            "SELECT COUNT(*) AS items, COALESCE(SUM(size), 0) AS bytes, \
             (SELECT COUNT(*) FROM new_items WHERE handle = ?1 AND created_at > ?2) AS new_today \
             FROM items WHERE handle = ?1",
        )
        .bind(handle)
        .bind(now() - 86_400)
        .fetch_one(&self.pool)
        .await?;
        Ok(Usage {
            items: row.try_get("items")?,
            bytes: row.try_get("bytes")?,
            new_today: row.try_get("new_today")?,
        })
    }

    /// Creates the signed-in account's item `slug`, or updates it (revision plus one).
    pub async fn publish(&self, caller: &Caller, body: PublishItem) -> Result<Published, Error> {
        let handle = self.authorize_write(caller).await?;
        let slug = body.slug.as_str();
        let mut problems: Vec<Violation> = Vec::new();
        let kind = Kind::parse(&body.kind);
        if kind.is_none() {
            problems.push(Violation {
                pointer: "/type".to_owned(),
                detail: "must be one of imp, animation, trigger, tool, kit".to_owned(),
            });
        }
        if let Some(problem) = meta::slug_problem(slug) {
            problems.push(Violation {
                pointer: "/slug".to_owned(),
                detail: problem.to_owned(),
            });
        }
        problems.extend(meta::label_problems(&body.summary, &body.tags));
        // A model sometimes sends the document as text.
        let document = match body.document {
            Value::String(text) => serde_json::from_str(&text).unwrap_or(Value::String(text)),
            other => other,
        };
        let checked = match kind.map(|kind| kit::check(document, kind)) {
            Some(Ok(checked)) => Some(checked),
            Some(Err(Error::Invalid(found))) => {
                problems.extend(found);
                None
            }
            Some(Err(other)) => return Err(other),
            None => None,
        };
        let (Some(kind), Some(checked), true) = (kind, checked, problems.is_empty()) else {
            problems.truncate(25);
            return Err(Error::Invalid(problems));
        };
        let summary = body.summary.trim();
        let tags = serde_json::to_string(&body.tags).map_err(|_| Error::Internal)?;
        let counts = serde_json::to_string(&checked.counts).map_err(|_| Error::Internal)?;
        let size = i64::try_from(checked.text.len()).unwrap_or(i64::MAX);
        let stamp_now = now();

        let mut tx = self.pool.begin_with("BEGIN IMMEDIATE").await?;
        let existing = sqlx::query(
            "SELECT id, sha256, type, summary, tags, size FROM items WHERE handle = ?1 AND slug = ?2",
        )
        .bind(&handle)
        .bind(slug)
        .fetch_optional(&mut *tx)
        .await?;

        if let Some(row) = &existing
            && row.try_get::<String, _>("sha256")? == checked.sha256
        {
            // The same document again to the same item: no new revision.
            let same_labels = row.try_get::<String, _>("type")? == kind.as_str()
                && row.try_get::<String, _>("summary")? == summary
                && row.try_get::<String, _>("tags")? == tags;
            if !same_labels {
                sqlx::query("UPDATE items SET type = ?1, summary = ?2, tags = ?3, updated_at = ?4 WHERE id = ?5")
                    .bind(kind.as_str())
                    .bind(summary)
                    .bind(&tags)
                    .bind(stamp_now)
                    .bind(row.try_get::<i64, _>("id")?)
                    .execute(&mut *tx)
                    .await?;
            }
            tx.commit().await?;
            if !same_labels {
                self.forget_cached();
            }
            return Ok(Published::Unchanged(
                self.fetch_item(&handle, slug, true).await?,
            ));
        }

        let twin = sqlx::query(sqlx::AssertSqlSafe(format!(
            "SELECT handle, slug FROM items WHERE sha256 = ?1 AND {VISIBLE} \
             AND NOT (handle = ?2 AND slug = ?3) LIMIT 1"
        )))
        .bind(&checked.sha256)
        .bind(&handle)
        .bind(slug)
        .fetch_optional(&mut *tx)
        .await?;
        if let Some(twin) = twin {
            return Err(Error::Duplicate(format!(
                "{}/{}",
                twin.try_get::<String, _>("handle")?,
                twin.try_get::<String, _>("slug")?
            )));
        }

        let used = {
            let row = sqlx::query(
                "SELECT COUNT(*) AS items, COALESCE(SUM(size), 0) AS bytes, \
                 (SELECT COUNT(*) FROM new_items WHERE handle = ?1 AND created_at > ?2) AS new_today \
                 FROM items WHERE handle = ?1",
            )
            .bind(&handle)
            .bind(stamp_now - 86_400)
            .fetch_one(&mut *tx)
            .await?;
            Usage {
                items: row.try_get("items")?,
                bytes: row.try_get("bytes")?,
                new_today: row.try_get("new_today")?,
            }
        };
        let old_size = match &existing {
            Some(row) => row.try_get::<i64, _>("size")?,
            None => 0,
        };
        if used.bytes - old_size + size > MAX_BYTES_PER_ACCOUNT {
            return Err(Error::Quota(format!(
                "An account can keep at most {} MB of documents.",
                MAX_BYTES_PER_ACCOUNT / (1024 * 1024)
            )));
        }
        let outcome = match existing {
            Some(row) => {
                sqlx::query(
                    "UPDATE items SET type = ?1, format = ?2, name = ?3, about = ?4, summary = ?5, tags = ?6, \
                     document = ?7, counts = ?8, sha256 = ?9, size = ?10, revision = revision + 1, \
                     runs_programs = ?11, updated_at = ?12 WHERE id = ?13",
                )
                .bind(kind.as_str())
                .bind(checked.format)
                .bind(&checked.name)
                .bind(&checked.about)
                .bind(summary)
                .bind(&tags)
                .bind(&checked.text)
                .bind(&counts)
                .bind(&checked.sha256)
                .bind(size)
                .bind(checked.runs_programs)
                .bind(stamp_now)
                .bind(row.try_get::<i64, _>("id")?)
                .execute(&mut *tx)
                .await?;
                false
            }
            None => {
                if used.items >= MAX_ITEMS_PER_ACCOUNT {
                    return Err(Error::Quota(format!(
                        "An account can share at most {MAX_ITEMS_PER_ACCOUNT} items."
                    )));
                }
                if used.new_today >= MAX_NEW_ITEMS_PER_DAY {
                    return Err(Error::Quota(format!(
                        "An account can share at most {MAX_NEW_ITEMS_PER_DAY} new items a day."
                    )));
                }
                sqlx::query(
                    "INSERT INTO items (handle, slug, type, format, name, about, summary, tags, document, counts, \
                     sha256, size, revision, runs_programs, created_at, updated_at) \
                     VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, 1, ?13, ?14, ?14)",
                )
                .bind(&handle)
                .bind(slug)
                .bind(kind.as_str())
                .bind(checked.format)
                .bind(&checked.name)
                .bind(&checked.about)
                .bind(summary)
                .bind(&tags)
                .bind(&checked.text)
                .bind(&counts)
                .bind(&checked.sha256)
                .bind(size)
                .bind(checked.runs_programs)
                .bind(stamp_now)
                .execute(&mut *tx)
                .await?;
                sqlx::query("INSERT INTO new_items (handle, created_at) VALUES (?1, ?2)")
                    .bind(&handle)
                    .bind(stamp_now)
                    .execute(&mut *tx)
                    .await?;
                true
            }
        };
        tx.commit().await?;
        self.forget_cached();
        let item = self.fetch_item(&handle, slug, true).await?;
        Ok(if outcome {
            Published::Created(item)
        } else {
            Published::Updated(item)
        })
    }

    /// Deletes one of the signed-in account's items. `handle`, when given, must be the account's own.
    pub async fn delete_item(
        &self,
        caller: &Caller,
        handle: Option<&str>,
        slug: &str,
    ) -> Result<(), Error> {
        let owner = self.authorize_write(caller).await?;
        if handle.is_some_and(|h| h != owner) {
            return Err(Error::Forbidden(
                "You can only delete your own items.".to_owned(),
            ));
        }
        let gone = sqlx::query("DELETE FROM items WHERE handle = ?1 AND slug = ?2")
            .bind(&owner)
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
        sqlx::query_scalar::<_, i64>(sqlx::AssertSqlSafe(format!(
            "SELECT id FROM items WHERE handle = ?1 AND slug = ?2 AND {VISIBLE}"
        )))
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
        let row = sqlx::query(sqlx::AssertSqlSafe(format!(
            "SELECT (SELECT COUNT(*) FROM accounts WHERE deactivated = 0) AS accounts, \
             (SELECT COUNT(*) FROM items WHERE {VISIBLE}) AS items, \
             (SELECT COALESCE(SUM(installs), 0) FROM items WHERE {VISIBLE}) AS installs"
        )))
        .fetch_one(&self.pool)
        .await?;
        let mut by_type = ByType::default();
        let types = sqlx::query(sqlx::AssertSqlSafe(format!(
            "SELECT type, COUNT(*) AS n FROM items WHERE {VISIBLE} GROUP BY type"
        )))
        .fetch_all(&self.pool)
        .await?;
        for row in types {
            let n: i64 = row.try_get("n")?;
            match Kind::parse(&row.try_get::<String, _>("type")?) {
                Some(Kind::Imp) => by_type.imp = n,
                Some(Kind::Animation) => by_type.animation = n,
                Some(Kind::Trigger) => by_type.trigger = n,
                Some(Kind::Tool) => by_type.tool = n,
                Some(Kind::Kit) => by_type.kit = n,
                None => {}
            }
        }
        let stats = Arc::new(Stats {
            accounts: row.try_get("accounts")?,
            items: row.try_get("items")?,
            installs: row.try_get("installs")?,
            by_type,
        });
        self.stats.insert((), Arc::clone(&stats));
        Ok(stats)
    }
}

pub(super) fn summary_of(row: &SqliteRow) -> Result<ItemSummary, Error> {
    Ok(ItemSummary {
        id: row.try_get("id")?,
        handle: row.try_get("handle")?,
        slug: row.try_get("slug")?,
        kind: row.try_get("type")?,
        format: row.try_get("format")?,
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
