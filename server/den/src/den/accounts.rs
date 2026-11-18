//! Accounts: challenge, sign-up, sign-in by account key, access tokens, view and delete.

use super::items::{SUMMARY_COLUMNS, summary_of};
use super::*;

impl Den {
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

    /// Makes an account from a handle and a solved challenge. The account key it returns is the only
    /// time the key is seen.
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

        let key = new_secret(KEY_PREFIX);
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
        let inserted =
            sqlx::query("INSERT INTO accounts (handle, key_hash, created_at) VALUES (?1, ?2, ?3)")
                .bind(handle)
                .bind(sha256_hex(key.as_bytes()))
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
            account_key: key,
            created_at: stamp(created),
        })
    }

    /// Finds the account an account key belongs to. A deactivated account is refused.
    pub async fn sign_in(&self, caller: &Caller, key: &str) -> Result<String, Error> {
        gate(&self.limits.attempts, &caller.ip)?;
        let unknown = || Error::Forbidden("That account key isn't one this Den knows.".to_owned());
        if !secret_shaped(key.trim(), KEY_PREFIX) {
            return Err(unknown());
        }
        let row = sqlx::query("SELECT handle, deactivated FROM accounts WHERE key_hash = ?1")
            .bind(sha256_hex(key.trim().as_bytes()))
            .fetch_optional(&self.pool)
            .await?
            .ok_or_else(unknown)?;
        if row.try_get::<bool, _>("deactivated")? {
            return Err(Error::AccountDeactivated);
        }
        Ok(row.try_get("handle")?)
    }

    /// The handle an access token belongs to. A token that is unknown, expired, revoked or of a
    /// deactivated account is `Unauthorized`.
    pub(super) async fn token_handle(&self, token: &str) -> Result<String, Error> {
        if !secret_shaped(token, ACCESS_PREFIX) {
            return Err(Error::Unauthorized);
        }
        sqlx::query_scalar::<_, String>(
            "SELECT t.handle FROM tokens t \
             JOIN grants g ON g.id = t.grant_id \
             JOIN accounts a ON a.handle = t.handle \
             WHERE t.hash = ?1 AND t.kind = 'access' AND t.expires_at > ?2 \
             AND g.revoked = 0 AND a.deactivated = 0",
        )
        .bind(sha256_hex(token.as_bytes()))
        .bind(now())
        .fetch_optional(&self.pool)
        .await?
        .ok_or(Error::Unauthorized)
    }

    /// The handle the request's bearer token belongs to.
    pub async fn authenticate(&self, caller: &Caller) -> Result<String, Error> {
        gate(&self.limits.reads, &caller.ip)?;
        let token = caller.token.as_deref().ok_or(Error::Unauthorized)?;
        self.token_handle(token).await
    }

    /// Authenticates and spends one write from the account's and the address's allowance.
    pub(super) async fn authorize_write(&self, caller: &Caller) -> Result<String, Error> {
        let handle = self.authenticate(caller).await?;
        gate(&self.limits.writes_by_account, &handle)?;
        gate(&self.limits.writes_by_ip, &caller.ip)?;
        Ok(handle)
    }

    pub async fn account(&self, caller: &Caller, handle: &str) -> Result<AccountView, Error> {
        gate(&self.limits.reads, &caller.ip)?;
        let created = sqlx::query_scalar::<_, i64>(
            "SELECT created_at FROM accounts WHERE handle = ?1 AND deactivated = 0",
        )
        .bind(handle)
        .fetch_optional(&self.pool)
        .await?
        .ok_or(Error::NotFound)?;
        Ok(AccountView {
            handle: handle.to_owned(),
            created_at: stamp(created),
            items: self.items_of(handle, true).await?,
        })
    }

    /// The items of an account, newest first, at most 100.
    async fn items_of(&self, handle: &str, only_visible: bool) -> Result<Vec<ItemSummary>, Error> {
        let mut sql = QueryBuilder::<Sqlite>::new(format!(
            "SELECT {SUMMARY_COLUMNS} FROM items WHERE handle = "
        ));
        sql.push_bind(handle);
        if only_visible {
            sql.push(format!(" AND {VISIBLE}"));
        }
        sql.push(" ORDER BY id DESC LIMIT ");
        sql.push_bind(MAX_ITEMS_PER_ACCOUNT);
        let rows = sql.build().fetch_all(&self.pool).await?;
        rows.iter().map(summary_of).collect()
    }

    /// The signed-in account with everything it shared (also what is hidden) and what is left of its quota.
    pub async fn my_account(&self, caller: &Caller) -> Result<MyAccount, Error> {
        let handle = self.authenticate(caller).await?;
        let created =
            sqlx::query_scalar::<_, i64>("SELECT created_at FROM accounts WHERE handle = ?1")
                .bind(&handle)
                .fetch_optional(&self.pool)
                .await?
                .ok_or(Error::Unauthorized)?;
        let items = self.items_of(&handle, false).await?;
        let used = self.usage(&handle).await?;
        Ok(MyAccount {
            handle,
            created_at: stamp(created),
            items,
            quota: Quota {
                items: used.items,
                items_left: (MAX_ITEMS_PER_ACCOUNT - used.items).max(0),
                bytes_left: (MAX_BYTES_PER_ACCOUNT - used.bytes).max(0),
                new_today_left: (MAX_NEW_ITEMS_PER_DAY - used.new_today).max(0),
            },
        })
    }

    /// Deletes the signed-in account, everything it shared and every token. `confirm` must be its handle.
    pub async fn delete_account(&self, caller: &Caller, confirm: &str) -> Result<(), Error> {
        let handle = self.authorize_write(caller).await?;
        if confirm != handle {
            return Err(bad("`confirm` must be your handle."));
        }
        sqlx::query("DELETE FROM accounts WHERE handle = ?1")
            .bind(&handle)
            .execute(&self.pool)
            .await?;
        self.forget_cached();
        Ok(())
    }
}
