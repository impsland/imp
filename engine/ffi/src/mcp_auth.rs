//! MCP authorization for the apps (OAuth 2.1, RFC 9728, 8414, 7591, 7636, 8707). The apps make
//! the requests (URLSession, a web authentication session) and ask these functions what to ask,
//! what the answers mean and when to refresh. The rules are in `imp_engine::mcp::auth`.
//!
//! The flow, for an MCP server at `mcp_url` that answered 401:
//! 1. `mcp_parse_challenge` the `WWW-Authenticate` header.
//! 2. GET each of `mcp_resource_metadata_urls` until one answers 200, then
//!    `mcp_parse_resource_metadata`. For an authorization server in it, GET each of
//!    `mcp_auth_server_metadata_urls` until one answers 200, then `mcp_parse_auth_server`.
//! 3. If there is no client id for the issuer yet, POST `mcp_registration_body` (JSON) to its
//!    `registration_endpoint` and read `mcp_parse_registration`. Keep the client id per issuer.
//! 4. `mcp_pkce_new`, `mcp_random_state`, `mcp_authorize_url`, open it in a web authentication
//!    session, and read the address it came back to with `mcp_parse_callback`.
//! 5. POST `mcp_token_request_code` (form) to the token endpoint, `mcp_parse_token_response`, then
//!    `mcp_auth_new` and store the `McpAuth` privately (the Keychain).
//! 6. Add `mcp_auth_header` to every request. Before a request, if `mcp_auth_needs_refresh`, POST
//!    `mcp_token_request_refresh`, `mcp_parse_token_response` and `mcp_auth_refreshed`. Do the same
//!    once on a 401. When the refresh answer `mcp_is_invalid_grant`, start again at step 1.

use imp_engine::mcp::auth;

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct McpChallenge {
    pub resource_metadata: Option<String>,
    pub scope: Option<String>,
    /// A 403 asking for more permission than the token has.
    pub insufficient_scope: bool,
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct McpResourceInfo {
    pub authorization_servers: Vec<String>,
    pub scopes_supported: Vec<String>,
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct McpAuthServer {
    pub issuer: String,
    pub authorization_endpoint: String,
    pub token_endpoint: String,
    pub registration_endpoint: Option<String>,
    pub scopes_supported: Vec<String>,
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct McpPkce {
    pub verifier: String,
    pub challenge: String,
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct McpTokenGrant {
    pub access_token: String,
    pub refresh_token: Option<String>,
    /// Unix seconds.
    pub expires_at: Option<u64>,
    pub scope: Option<String>,
}

/// What to keep, privately, for one signed-in MCP server.
#[derive(Clone, PartialEq, uniffi::Record)]
pub struct McpAuth {
    pub issuer: String,
    pub token_endpoint: String,
    pub client_id: String,
    pub redirect_uri: String,
    pub access_token: String,
    pub refresh_token: Option<String>,
    /// Unix seconds.
    pub expires_at: Option<u64>,
    pub scope: Option<String>,
}

impl std::fmt::Debug for McpAuth {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("McpAuth")
            .field("issuer", &self.issuer)
            .finish_non_exhaustive()
    }
}

impl From<auth::McpAuth> for McpAuth {
    fn from(a: auth::McpAuth) -> Self {
        Self {
            issuer: a.issuer,
            token_endpoint: a.token_endpoint,
            client_id: a.client_id,
            redirect_uri: a.redirect_uri,
            access_token: a.access_token,
            refresh_token: a.refresh_token,
            expires_at: a.expires_at,
            scope: a.scope,
        }
    }
}

impl From<McpAuth> for auth::McpAuth {
    fn from(a: McpAuth) -> Self {
        Self {
            issuer: a.issuer,
            token_endpoint: a.token_endpoint,
            client_id: a.client_id,
            redirect_uri: a.redirect_uri,
            access_token: a.access_token,
            refresh_token: a.refresh_token,
            expires_at: a.expires_at,
            scope: a.scope,
        }
    }
}

impl From<auth::AuthServer> for McpAuthServer {
    fn from(s: auth::AuthServer) -> Self {
        Self {
            issuer: s.issuer,
            authorization_endpoint: s.authorization_endpoint,
            token_endpoint: s.token_endpoint,
            registration_endpoint: s.registration_endpoint,
            scopes_supported: s.scopes_supported,
        }
    }
}

impl From<McpAuthServer> for auth::AuthServer {
    fn from(s: McpAuthServer) -> Self {
        Self {
            issuer: s.issuer,
            authorization_endpoint: s.authorization_endpoint,
            token_endpoint: s.token_endpoint,
            registration_endpoint: s.registration_endpoint,
            scopes_supported: s.scopes_supported,
        }
    }
}

impl From<McpTokenGrant> for auth::TokenGrant {
    fn from(g: McpTokenGrant) -> Self {
        Self {
            access_token: g.access_token,
            refresh_token: g.refresh_token,
            expires_at: g.expires_at,
            scope: g.scope,
        }
    }
}

/// A sign-in step that failed, as a sentence.
#[derive(Debug, uniffi::Error)]
pub enum McpAuthError {
    Failed { message: String },
}

impl std::fmt::Display for McpAuthError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Failed { message } => f.write_str(message),
        }
    }
}

fn failed(message: String) -> McpAuthError {
    McpAuthError::Failed { message }
}

/// Reads a `WWW-Authenticate` header value. Nothing when it has no Bearer challenge.
#[uniffi::export]
pub fn mcp_parse_challenge(header: String) -> Option<McpChallenge> {
    auth::parse_challenge(&header).map(|c| McpChallenge {
        resource_metadata: c.resource_metadata,
        scope: c.scope,
        insufficient_scope: c.insufficient_scope,
    })
}

/// The addresses to try, in order, for the protected resource metadata.
#[uniffi::export]
pub fn mcp_resource_metadata_urls(mcp_url: String, from_challenge: Option<String>) -> Vec<String> {
    auth::resource_metadata_urls(&mcp_url, from_challenge.as_deref())
}

#[uniffi::export]
pub fn mcp_parse_resource_metadata(
    body: String,
    mcp_url: String,
) -> Result<McpResourceInfo, McpAuthError> {
    auth::parse_resource_metadata(&body, &mcp_url)
        .map(|i| McpResourceInfo {
            authorization_servers: i.authorization_servers,
            scopes_supported: i.scopes_supported,
        })
        .map_err(failed)
}

/// The addresses to try, in order, for an authorization server's metadata.
#[uniffi::export]
pub fn mcp_auth_server_metadata_urls(issuer: String) -> Vec<String> {
    auth::auth_server_metadata_urls(&issuer)
}

/// Reads and checks authorization server metadata (issuer, endpoints, PKCE S256).
#[uniffi::export]
pub fn mcp_parse_auth_server(body: String, issuer: String) -> Result<McpAuthServer, McpAuthError> {
    auth::parse_auth_server(&body, &issuer)
        .map(Into::into)
        .map_err(failed)
}

/// The scope to ask for: the challenge's, else all the resource's.
#[uniffi::export]
pub fn mcp_choose_scope(challenge: Option<String>, supported: Vec<String>) -> Option<String> {
    auth::choose_scope(challenge.as_deref(), &supported)
}

/// The JSON body to POST to the registration endpoint.
#[uniffi::export]
pub fn mcp_registration_body(redirect_uris: Vec<String>) -> String {
    auth::registration_body(&redirect_uris).to_string()
}

/// The client id from the registration answer.
#[uniffi::export]
pub fn mcp_parse_registration(status: u16, body: String) -> Result<String, McpAuthError> {
    auth::parse_registration(status, &body).map_err(failed)
}

#[uniffi::export]
pub fn mcp_pkce_new() -> McpPkce {
    let p = auth::pkce_new();
    McpPkce {
        verifier: p.verifier,
        challenge: p.challenge,
    }
}

#[uniffi::export]
pub fn mcp_random_state() -> String {
    auth::random_state()
}

/// The address to open for the person. `scope` is the challenge's or the metadata's.
#[uniffi::export]
pub fn mcp_authorize_url(
    server: McpAuthServer,
    client_id: String,
    redirect_uri: String,
    code_challenge: String,
    state: String,
    scope: Option<String>,
    mcp_url: String,
) -> String {
    auth::authorize_url(
        &server.into(),
        &client_id,
        &redirect_uri,
        &code_challenge,
        &state,
        scope.as_deref(),
        &mcp_url,
    )
}

/// The authorization code in the address the sign-in came back to, after checking `state`.
#[uniffi::export]
pub fn mcp_parse_callback(
    callback: String,
    expected_state: String,
) -> Result<String, McpAuthError> {
    auth::parse_callback(&callback, &expected_state).map_err(failed)
}

/// The form body to POST to the token endpoint to trade the code.
#[uniffi::export]
pub fn mcp_token_request_code(
    client_id: String,
    code: String,
    redirect_uri: String,
    verifier: String,
    mcp_url: String,
) -> String {
    auth::token_request_code(&client_id, &code, &redirect_uri, &verifier, &mcp_url)
}

/// The form body to POST to the token endpoint to refresh.
#[uniffi::export]
pub fn mcp_token_request_refresh(
    client_id: String,
    refresh_token: String,
    mcp_url: String,
) -> String {
    auth::token_request_refresh(&client_id, &refresh_token, &mcp_url)
}

/// Reads the token endpoint's answer. `now` is Unix seconds.
#[uniffi::export]
pub fn mcp_parse_token_response(
    status: u16,
    body: String,
    now: u64,
) -> Result<McpTokenGrant, McpAuthError> {
    auth::parse_token_response(status, &body, now)
        .map(|g| McpTokenGrant {
            access_token: g.access_token,
            refresh_token: g.refresh_token,
            expires_at: g.expires_at,
            scope: g.scope,
        })
        .map_err(failed)
}

/// Whether a failed token answer says the refresh token or code is dead (`invalid_grant`).
#[uniffi::export]
pub fn mcp_is_invalid_grant(body: String) -> bool {
    auth::is_invalid_grant(&body)
}

/// The record to store after the first sign-in.
#[uniffi::export]
pub fn mcp_auth_new(
    server: McpAuthServer,
    client_id: String,
    redirect_uri: String,
    grant: McpTokenGrant,
) -> McpAuth {
    auth::McpAuth::new(&server.into(), &client_id, &redirect_uri, grant.into()).into()
}

/// The record after a refresh (a refresh token that was not rotated is kept).
#[uniffi::export]
pub fn mcp_auth_refreshed(auth: McpAuth, grant: McpTokenGrant) -> McpAuth {
    auth::McpAuth::from(auth).refreshed(grant.into()).into()
}

/// Whether to refresh before the next request (under a minute left). `now` is Unix seconds.
#[uniffi::export]
pub fn mcp_auth_needs_refresh(auth: McpAuth, now: u64) -> bool {
    auth::McpAuth::from(auth).needs_refresh(now)
}

/// The `Authorization: Bearer ...` header for requests to the server.
#[uniffi::export]
pub fn mcp_auth_header(auth: McpAuth) -> crate::McpHeader {
    let (name, value) = auth::McpAuth::from(auth).header();
    crate::McpHeader { name, value }
}

/// The revisions Imp speaks, newest first.
#[uniffi::export]
pub fn mcp_supported_versions() -> Vec<String> {
    imp_engine::mcp::protocol::SUPPORTED_VERSIONS
        .iter()
        .map(|v| v.to_string())
        .collect()
}

/// The version to speak after `initialize`. Fails with a sentence when the server picked a revision
/// Imp does not speak: the app must disconnect and show it.
#[uniffi::export]
pub fn mcp_checked_version(
    initialize_result_json: String,
) -> Result<String, crate::McpProtocolError> {
    let v: serde_json::Value = serde_json::from_str(&initialize_result_json).map_err(|_| {
        crate::McpProtocolError::Failed {
            message: "the MCP server sent something that is not JSON".into(),
        }
    })?;
    imp_engine::mcp::protocol::checked_version(&v)
        .map_err(|message| crate::McpProtocolError::Failed { message })
}
