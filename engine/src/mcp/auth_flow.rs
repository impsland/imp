//! The requests of MCP authorization, made with reqwest. The decisions are in `auth`.

use super::auth::{self, AuthServer, McpAuth, TokenGrant};
use super::client::McpError;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

/// The time now in Unix seconds.
pub fn now_secs() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0, |d| d.as_secs())
}

/// A client for the sign-in requests.
pub fn http_client() -> Result<reqwest::Client, McpError> {
    reqwest::Client::builder()
        .connect_timeout(Duration::from_secs(15))
        .timeout(Duration::from_secs(30))
        .redirect(reqwest::redirect::Policy::none())
        .build()
        .map_err(|e| McpError::Network(e.without_url().to_string()))
}

fn fail(sentence: impl Into<String>) -> McpError {
    McpError::Protocol(sentence.into())
}

async fn get_text(client: &reqwest::Client, url: &str) -> Option<(u16, String)> {
    let response = client
        .get(url)
        .header("Accept", "application/json")
        .send()
        .await
        .ok()?;
    let status = response.status().as_u16();
    Some((status, response.text().await.ok()?))
}

/// What discovery found out about the sign-in of one MCP server.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Discovery {
    pub server: AuthServer,
    /// The scope to ask for, if any.
    pub scope: Option<String>,
}

/// Finds and checks the authorization server of `mcp_url`: the protected resource metadata (from
/// the challenge's address, else the well-known ones), then the server's metadata.
pub async fn discover(
    client: &reqwest::Client,
    mcp_url: &str,
    resource_metadata: Option<&str>,
    challenge_scope: Option<&str>,
) -> Result<Discovery, McpError> {
    let mut info = None;
    let mut why = String::new();
    for url in auth::resource_metadata_urls(mcp_url, resource_metadata) {
        if let Some((200, body)) = get_text(client, &url).await {
            match auth::parse_resource_metadata(&body, mcp_url) {
                Ok(i) => {
                    info = Some(i);
                    break;
                }
                Err(e) => why = e,
            }
        }
    }
    let info = info.ok_or_else(|| {
        fail(if why.is_empty() {
            format!(
                "{mcp_url} needs a sign-in but does not say how (no protected resource metadata)"
            )
        } else {
            why
        })
    })?;
    let mut why = String::from("it has no authorization server metadata");
    for issuer in &info.authorization_servers {
        for url in auth::auth_server_metadata_urls(issuer) {
            if let Some((200, body)) = get_text(client, &url).await {
                match auth::parse_auth_server(&body, issuer) {
                    Ok(server) => {
                        return Ok(Discovery {
                            scope: auth::choose_scope(challenge_scope, &info.scopes_supported)
                                .or_else(|| auth::choose_scope(None, &server.scopes_supported)),
                            server,
                        });
                    }
                    Err(e) => why = e,
                }
            }
        }
    }
    Err(fail(format!("Cannot sign in to {mcp_url}: {why}.")))
}

/// Registers Imp as a public client (RFC 7591) and returns its client id.
pub async fn register(
    client: &reqwest::Client,
    server: &AuthServer,
    redirect_uri: &str,
) -> Result<String, McpError> {
    let endpoint = server.registration_endpoint.as_deref().ok_or_else(|| {
        fail(format!(
            "{} does not let apps register themselves, and Imp has no client id for it",
            server.issuer
        ))
    })?;
    let response = client
        .post(endpoint)
        .json(&auth::registration_body(&[redirect_uri.to_string()]))
        .send()
        .await
        .map_err(|e| McpError::Network(e.without_url().to_string()))?;
    let status = response.status().as_u16();
    let body = response.text().await.unwrap_or_default();
    auth::parse_registration(status, &body).map_err(fail)
}

async fn token_request(
    client: &reqwest::Client,
    endpoint: &str,
    form: String,
) -> Result<(u16, String), McpError> {
    let response = client
        .post(endpoint)
        .header("Content-Type", "application/x-www-form-urlencoded")
        .header("Accept", "application/json")
        .body(form)
        .send()
        .await
        .map_err(|e| McpError::Network(e.without_url().to_string()))?;
    let status = response.status().as_u16();
    Ok((status, response.text().await.unwrap_or_default()))
}

/// Trades the code from the browser for tokens.
pub async fn exchange_code(
    client: &reqwest::Client,
    server: &AuthServer,
    client_id: &str,
    redirect_uri: &str,
    code: &str,
    verifier: &str,
    mcp_url: &str,
) -> Result<McpAuth, McpError> {
    let form = auth::token_request_code(client_id, code, redirect_uri, verifier, mcp_url);
    let (status, body) = token_request(client, &server.token_endpoint, form).await?;
    let grant: TokenGrant = auth::parse_token_response(status, &body, now_secs()).map_err(fail)?;
    Ok(McpAuth::new(server, client_id, redirect_uri, grant))
}

/// Why a refresh failed.
#[derive(Debug)]
pub enum RefreshFailure {
    /// The refresh token is no good any more: the person must sign in again.
    Rejected,
    Other(McpError),
}

/// Trades the refresh token for new tokens. Refresh tokens may rotate: store the result.
pub async fn refresh(
    client: &reqwest::Client,
    auth_record: &McpAuth,
    mcp_url: &str,
) -> Result<McpAuth, RefreshFailure> {
    let Some(token) = auth_record.refresh_token.as_deref() else {
        return Err(RefreshFailure::Rejected);
    };
    let form = auth::token_request_refresh(&auth_record.client_id, token, mcp_url);
    let (status, body) = token_request(client, &auth_record.token_endpoint, form)
        .await
        .map_err(RefreshFailure::Other)?;
    if (400..500).contains(&status) && auth::is_invalid_grant(&body) {
        return Err(RefreshFailure::Rejected);
    }
    let grant = auth::parse_token_response(status, &body, now_secs())
        .map_err(|e| RefreshFailure::Other(fail(e)))?;
    Ok(auth_record.refreshed(grant))
}
