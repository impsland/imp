//! Items: list, read, publish, delete, install, report and stats.

use super::cursor::{decode_cursor, encode_cursor};
use super::*;

pub(super) const SUMMARY_COLUMNS: &str = "id, handle, slug, kind, name, summary, tags, runs_programs, installs, revision, created_at, updated_at";
const DETAIL_COLUMNS: &str = "id, handle, slug, kind, name, summary, tags, runs_programs, installs, revision, \
                              created_at, updated_at, about, sha256, size, counts";

impl Den {
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
                "{}/items/{handle}/{slug}/kit.json",
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
pub(super) fn summary_of(row: &SqliteRow) -> Result<ItemSummary, Error> {
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
