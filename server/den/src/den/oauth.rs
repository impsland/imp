//! The Den as its own OAuth 2.1 authorization server: clients (RFC 7591), authorization codes with PKCE,
//! access and refresh tokens, and revocation (RFC 7009). Every secret is kept only as a SHA-256.

use super::*;

const CODE_LIFETIME_SECS: i64 = 60;
const ACCESS_LIFETIME_SECS: i64 = 3600;
const REFRESH_LIFETIME_SECS: i64 = 90 * 86_400;
/// The only scope there is.
pub const SCOPE: &str = "publish";

/// An OAuth failure: an error code of RFC 6749 or RFC 7591 with a sentence, or an ordinary Den error
/// (a rate limit, an internal error).
#[derive(Debug)]
pub enum OAuthError {
    Protocol {
        error: &'static str,
        description: String,
    },
    Den(Error),
}

impl OAuthError {
    pub fn protocol(error: &'static str, description: impl Into<String>) -> Self {
        OAuthError::Protocol {
            error,
            description: description.into(),
        }
    }
}

impl From<Error> for OAuthError {
    fn from(e: Error) -> Self {
        OAuthError::Den(e)
    }
}

impl From<sqlx::Error> for OAuthError {
    fn from(e: sqlx::Error) -> Self {
        OAuthError::Den(e.into())
    }
}

/// A registered client.
#[derive(Debug, Clone, Serialize)]
pub struct Client {
    pub client_id: String,
    pub client_name: String,
    pub redirect_uris: Vec<String>,
    pub client_id_issued_at: i64,
    pub token_endpoint_auth_method: &'static str,
    pub grant_types: [&'static str; 2],
    pub response_types: [&'static str; 1],
    pub scope: &'static str,
}

/// What an authorization request carries once checked.
#[derive(Debug, Clone)]
pub struct AuthRequest {
    pub client: Client,
    pub redirect_uri: String,
    pub code_challenge: String,
    pub state: String,
}

/// The answer to a successful token request.
#[derive(Debug, Serialize)]
pub struct TokenSet {
    pub access_token: String,
    pub token_type: &'static str,
    pub expires_in: i64,
    pub refresh_token: String,
    pub scope: &'static str,
}

fn invalid_grant(why: &str) -> OAuthError {
    OAuthError::protocol("invalid_grant", why)
}

impl Den {
    /// Registers a public client (RFC 7591). `redirect_uris` must follow `crate::redirect`.
    pub async fn register_client(
        &self,
        caller: &Caller,
        body: &Value,
    ) -> Result<Client, OAuthError> {
        gate(&self.limits.registrations, &caller.ip)?;
        let metadata = |why: &str| OAuthError::protocol("invalid_client_metadata", why);
        let Some(body) = body.as_object() else {
            return Err(metadata("send a JSON object"));
        };
        let uris: Vec<String> = match body.get("redirect_uris") {
            Some(Value::Array(list)) if (1..=5).contains(&list.len()) => list
                .iter()
                .map(|u| u.as_str().map(str::to_owned))
                .collect::<Option<_>>()
                .ok_or_else(|| {
                    OAuthError::protocol("invalid_redirect_uri", "redirect_uris are text")
                })?,
            _ => {
                return Err(OAuthError::protocol(
                    "invalid_redirect_uri",
                    "redirect_uris is a list of 1 to 5 addresses",
                ));
            }
        };
        for uri in &uris {
            if let Some(problem) = crate::redirect::problem(uri) {
                return Err(OAuthError::protocol(
                    "invalid_redirect_uri",
                    format!("{uri} {problem}"),
                ));
            }
        }
        if let Some(method) = body.get("token_endpoint_auth_method")
            && method.as_str() != Some("none")
        {
            return Err(metadata(
                "only public clients are registered: token_endpoint_auth_method is none",
            ));
        }
        for (key, allowed) in [
            ("grant_types", &["authorization_code", "refresh_token"][..]),
            ("response_types", &["code"][..]),
        ] {
            if let Some(list) = body.get(key) {
                let ok = list.as_array().is_some_and(|l| {
                    l.iter()
                        .all(|v| v.as_str().is_some_and(|s| allowed.contains(&s)))
                });
                if !ok {
                    return Err(metadata(&format!(
                        "{key} may only hold {}",
                        allowed.join(", ")
                    )));
                }
            }
        }
        let name: String = body
            .get("client_name")
            .and_then(Value::as_str)
            .map(|n| {
                n.chars()
                    .filter(|c| !c.is_control())
                    .take(100)
                    .collect::<String>()
            })
            .map(|n| n.trim().to_owned())
            .filter(|n| !n.is_empty())
            .unwrap_or_else(|| "An MCP client".to_owned());
        let client_id = format!("dc_{}", URL_SAFE_NO_PAD.encode(rand::random::<[u8; 16]>()));
        let issued = now();
        sqlx::query(
            "INSERT INTO clients (client_id, client_name, redirect_uris, created_at) VALUES (?1, ?2, ?3, ?4)",
        )
        .bind(&client_id)
        .bind(&name)
        .bind(serde_json::to_string(&uris).map_err(|_| Error::Internal)?)
        .bind(issued)
        .execute(&self.pool)
        .await?;
        Ok(client_of(client_id, name, uris, issued))
    }

    pub async fn client(&self, client_id: &str) -> Result<Option<Client>, Error> {
        if client_id.len() > 100 {
            return Ok(None);
        }
        let row = sqlx::query(
            "SELECT client_name, redirect_uris, created_at FROM clients WHERE client_id = ?1",
        )
        .bind(client_id)
        .fetch_optional(&self.pool)
        .await?;
        let Some(row) = row else { return Ok(None) };
        Ok(Some(client_of(
            client_id.to_owned(),
            row.try_get("client_name")?,
            parse_json(&row.try_get::<String, _>("redirect_uris")?)?,
            row.try_get("created_at")?,
        )))
    }

    /// Makes an authorization code for `handle`. It works for 60 seconds, once.
    pub async fn issue_code(&self, request: &AuthRequest, handle: &str) -> Result<String, Error> {
        let code = URL_SAFE_NO_PAD.encode(rand::random::<[u8; 32]>());
        sqlx::query(
            "INSERT INTO codes (code_hash, client_id, handle, redirect_uri, code_challenge, expires_at) \
             VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
        )
        .bind(sha256_hex(code.as_bytes()))
        .bind(&request.client.client_id)
        .bind(handle)
        .bind(&request.redirect_uri)
        .bind(&request.code_challenge)
        .bind(now() + CODE_LIFETIME_SECS)
        .execute(&self.pool)
        .await?;
        Ok(code)
    }

    /// `grant_type=authorization_code`. The code is spent whether or not the rest matches.
    pub async fn exchange_code(
        &self,
        caller: &Caller,
        client_id: &str,
        code: &str,
        redirect_uri: &str,
        verifier: &str,
    ) -> Result<TokenSet, OAuthError> {
        gate(&self.limits.tokens, &caller.ip)?;
        let row = sqlx::query(
            "DELETE FROM codes WHERE code_hash = ?1 \
             RETURNING client_id, handle, redirect_uri, code_challenge, expires_at",
        )
        .bind(sha256_hex(code.as_bytes()))
        .fetch_optional(&self.pool)
        .await?
        .ok_or_else(|| invalid_grant("That code is unknown, expired or already used."))?;
        if row.try_get::<i64, _>("expires_at")? < now() {
            return Err(invalid_grant("That code has expired."));
        }
        if row.try_get::<String, _>("client_id")? != client_id {
            return Err(invalid_grant("That code was given to another client."));
        }
        if row.try_get::<String, _>("redirect_uri")? != redirect_uri {
            return Err(invalid_grant("redirect_uri isn't the one of the request."));
        }
        let verifier_ok = (43..=128).contains(&verifier.len())
            && verifier
                .bytes()
                .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'-' | b'.' | b'_' | b'~'));
        let proof = URL_SAFE_NO_PAD.encode(Sha256::digest(verifier.as_bytes()));
        if !verifier_ok || proof != row.try_get::<String, _>("code_challenge")? {
            return Err(invalid_grant(
                "code_verifier doesn't match the code_challenge.",
            ));
        }
        let handle: String = row.try_get("handle")?;
        let active =
            sqlx::query_scalar::<_, bool>("SELECT deactivated = 0 FROM accounts WHERE handle = ?1")
                .bind(&handle)
                .fetch_optional(&self.pool)
                .await?
                .unwrap_or(false);
        if !active {
            return Err(invalid_grant("That account can't sign in."));
        }
        let mut tx = self.pool.begin().await?;
        let grant = sqlx::query_scalar::<_, i64>(
            "INSERT INTO grants (client_id, handle, created_at) VALUES (?1, ?2, ?3) RETURNING id",
        )
        .bind(client_id)
        .bind(&handle)
        .bind(now())
        .fetch_one(&mut *tx)
        .await?;
        let tokens = issue_tokens(&mut tx, grant, &handle).await?;
        tx.commit().await?;
        Ok(tokens)
    }

    /// `grant_type=refresh_token`. The refresh token is replaced by a new one. Presenting one that was
    /// already replaced revokes the whole grant.
    pub async fn refresh(
        &self,
        caller: &Caller,
        client_id: &str,
        token: &str,
    ) -> Result<TokenSet, OAuthError> {
        gate(&self.limits.tokens, &caller.ip)?;
        if !secret_shaped(token, REFRESH_PREFIX) {
            return Err(invalid_grant("That refresh token isn't valid."));
        }
        let mut tx = self.pool.begin_with("BEGIN IMMEDIATE").await?;
        let row = sqlx::query(
            "SELECT t.grant_id, t.handle, t.expires_at, t.used, g.client_id, g.revoked, a.deactivated \
             FROM tokens t JOIN grants g ON g.id = t.grant_id JOIN accounts a ON a.handle = t.handle \
             WHERE t.hash = ?1 AND t.kind = 'refresh'",
        )
        .bind(sha256_hex(token.as_bytes()))
        .fetch_optional(&mut *tx)
        .await?
        .ok_or_else(|| invalid_grant("That refresh token isn't valid."))?;
        let grant: i64 = row.try_get("grant_id")?;
        if row.try_get::<String, _>("client_id")? != client_id {
            return Err(invalid_grant(
                "That refresh token was given to another client.",
            ));
        }
        if row.try_get::<bool, _>("used")? {
            // Someone presents a token that was already exchanged: it may have been stolen.
            sqlx::query("UPDATE grants SET revoked = 1 WHERE id = ?1")
                .bind(grant)
                .execute(&mut *tx)
                .await?;
            tx.commit().await?;
            tracing::warn!(grant, "refresh token reused: grant revoked");
            return Err(invalid_grant(
                "That refresh token was already used. Sign in again.",
            ));
        }
        if row.try_get::<bool, _>("revoked")?
            || row.try_get::<bool, _>("deactivated")?
            || row.try_get::<i64, _>("expires_at")? < now()
        {
            return Err(invalid_grant(
                "That refresh token is no longer valid. Sign in again.",
            ));
        }
        let handle: String = row.try_get("handle")?;
        sqlx::query("UPDATE tokens SET used = 1 WHERE hash = ?1")
            .bind(sha256_hex(token.as_bytes()))
            .execute(&mut *tx)
            .await?;
        let tokens = issue_tokens(&mut tx, grant, &handle).await?;
        tx.commit().await?;
        Ok(tokens)
    }

    /// RFC 7009: revokes the grant a token belongs to. A token that isn't known is not an error.
    pub async fn revoke(&self, caller: &Caller, token: &str) -> Result<(), Error> {
        gate(&self.limits.tokens, &caller.ip)?;
        if token.len() > 200 {
            return Ok(());
        }
        sqlx::query(
            "UPDATE grants SET revoked = 1 WHERE id = (SELECT grant_id FROM tokens WHERE hash = ?1)",
        )
        .bind(sha256_hex(token.as_bytes()))
        .execute(&self.pool)
        .await?;
        Ok(())
    }
}

fn client_of(
    client_id: String,
    client_name: String,
    redirect_uris: Vec<String>,
    issued: i64,
) -> Client {
    Client {
        client_id,
        client_name,
        redirect_uris,
        client_id_issued_at: issued,
        token_endpoint_auth_method: "none",
        grant_types: ["authorization_code", "refresh_token"],
        response_types: ["code"],
        scope: SCOPE,
    }
}

/// Writes a new access token and a new refresh token for `grant`.
async fn issue_tokens(
    tx: &mut sqlx::SqliteConnection,
    grant: i64,
    handle: &str,
) -> Result<TokenSet, sqlx::Error> {
    let access = new_secret(ACCESS_PREFIX);
    let refresh = new_secret(REFRESH_PREFIX);
    let issued = now();
    for (token, kind, lifetime) in [
        (&access, "access", ACCESS_LIFETIME_SECS),
        (&refresh, "refresh", REFRESH_LIFETIME_SECS),
    ] {
        sqlx::query(
            "INSERT INTO tokens (hash, kind, grant_id, handle, expires_at) VALUES (?1, ?2, ?3, ?4, ?5)",
        )
        .bind(sha256_hex(token.as_bytes()))
        .bind(kind)
        .bind(grant)
        .bind(handle)
        .bind(issued + lifetime)
        .execute(&mut *tx)
        .await?;
    }
    Ok(TokenSet {
        access_token: access,
        token_type: "Bearer",
        expires_in: ACCESS_LIFETIME_SECS,
        refresh_token: refresh,
        scope: SCOPE,
    })
}
