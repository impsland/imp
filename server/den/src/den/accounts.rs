//! Accounts: challenge, sign-up, view and delete.

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

    pub(super) async fn authenticate(&self, caller: &Caller) -> Result<String, Error> {
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
    pub(super) async fn authorize_write(&self, caller: &Caller) -> Result<String, Error> {
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
}
