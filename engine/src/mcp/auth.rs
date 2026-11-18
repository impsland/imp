//! MCP authorization (OAuth 2.1, as the MCP authorization specification describes), without I/O.
//!
//! Every rule lives here: reading the `WWW-Authenticate` challenge, where the metadata documents are,
//! checking them, the dynamic client registration body, PKCE, the authorize address, the token
//! request bodies and the token response, and when a stored grant needs a refresh. The terminal app
//! moves the messages with `auth_flow`, and the apps reach these functions through `imp-ffi` and do
//! their own requests.

use base64::Engine;
use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};

/// Refresh a token with less than this many seconds left.
pub const REFRESH_MARGIN_SECS: u64 = 60;
/// The name a server shows on its sign-in page.
pub const CLIENT_NAME: &str = "Imp";

/// What a server asked for in `WWW-Authenticate: Bearer ...`.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct Challenge {
    pub resource_metadata: Option<String>,
    pub scope: Option<String>,
    /// The server said `error="insufficient_scope"` (a 403): the person must approve more.
    pub insufficient_scope: bool,
}

/// Reads a `WWW-Authenticate` header value. Nothing when it has no Bearer challenge.
pub fn parse_challenge(header: &str) -> Option<Challenge> {
    let lower = header.to_ascii_lowercase();
    let mut start = None;
    for (at, _) in lower.match_indices("bearer") {
        let before_ok = at == 0 || matches!(lower.as_bytes()[at - 1], b' ' | b',' | b'\t');
        let after = lower.as_bytes().get(at + 6).copied();
        if before_ok && matches!(after, None | Some(b' ') | Some(b',') | Some(b'\t')) {
            start = Some(at + 6);
            break;
        }
    }
    let rest = &header[start?..];
    let mut out = Challenge::default();
    let chars: Vec<char> = rest.chars().collect();
    let mut i = 0;
    while i < chars.len() {
        while i < chars.len() && matches!(chars[i], ' ' | ',' | '\t') {
            i += 1;
        }
        let key_start = i;
        while i < chars.len() && !matches!(chars[i], '=' | ' ' | ',') {
            i += 1;
        }
        let key: String = chars[key_start..i].iter().collect();
        if i >= chars.len() || chars[i] != '=' {
            // A new challenge scheme begins: stop at it.
            if key_start == i {
                break;
            }
            break;
        }
        i += 1;
        let mut value = String::new();
        if i < chars.len() && chars[i] == '"' {
            i += 1;
            while i < chars.len() && chars[i] != '"' {
                if chars[i] == '\\' && i + 1 < chars.len() {
                    i += 1;
                }
                value.push(chars[i]);
                i += 1;
            }
            i += 1;
        } else {
            while i < chars.len() && chars[i] != ',' && chars[i] != ' ' {
                value.push(chars[i]);
                i += 1;
            }
        }
        match key.to_ascii_lowercase().as_str() {
            "resource_metadata" => out.resource_metadata = Some(value),
            "scope" if !value.trim().is_empty() => out.scope = Some(value),
            "error" => out.insufficient_scope = value == "insufficient_scope",
            _ => {}
        }
    }
    Some(out)
}

/// Splits `https://host:port/path?query#fragment` into the origin and the path (no query).
fn split_url(url: &str) -> Option<(String, String)> {
    let (scheme, rest) = url.split_once("://")?;
    let scheme = scheme.to_ascii_lowercase();
    let scheme = scheme.as_str();
    let rest = rest.split('#').next()?;
    let rest = rest.split('?').next()?;
    let (authority, path) = match rest.find('/') {
        Some(at) => (&rest[..at], &rest[at..]),
        None => (rest, ""),
    };
    if authority.is_empty() || !matches!(scheme, "http" | "https") {
        return None;
    }
    Some((
        format!(
            "{}://{}",
            scheme.to_ascii_lowercase(),
            authority.to_ascii_lowercase()
        ),
        path.trim_end_matches('/').to_string(),
    ))
}

/// The address of an MCP server as the `resource` parameter wants it (RFC 8707): no fragment, no
/// query, lower-case scheme and host, no trailing slash.
pub fn canonical_resource(url: &str) -> String {
    match split_url(url) {
        Some((origin, path)) => format!("{origin}{path}"),
        None => url.to_string(),
    }
}

/// Where to look for the protected resource metadata (RFC 9728): the address in the challenge, or
/// the well-known address with the server's path, then at the root.
pub fn resource_metadata_urls(mcp_url: &str, from_header: Option<&str>) -> Vec<String> {
    let mut urls = Vec::new();
    if let Some(h) = from_header.filter(|h| !h.is_empty()) {
        urls.push(h.to_string());
    }
    if let Some((origin, path)) = split_url(mcp_url) {
        if !path.is_empty() {
            urls.push(format!(
                "{origin}/.well-known/oauth-protected-resource{path}"
            ));
        }
        urls.push(format!("{origin}/.well-known/oauth-protected-resource"));
    }
    urls.dedup();
    urls
}

/// Which authorization servers guard an MCP server.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ResourceInfo {
    pub authorization_servers: Vec<String>,
    pub scopes_supported: Vec<String>,
}

fn strings(value: &Value) -> Vec<String> {
    value
        .as_array()
        .map(|a| {
            a.iter()
                .filter_map(|v| v.as_str().map(str::to_string))
                .collect()
        })
        .unwrap_or_default()
}

/// Reads protected resource metadata and checks that it describes `mcp_url`.
pub fn parse_resource_metadata(body: &str, mcp_url: &str) -> Result<ResourceInfo, String> {
    let v: Value = serde_json::from_str(body)
        .map_err(|_| "the server's sign-in information is not JSON".to_string())?;
    if let Some(resource) = v["resource"].as_str()
        && canonical_resource(resource) != canonical_resource(mcp_url)
    {
        return Err(format!(
            "the server's sign-in information is for {resource}, not for {mcp_url}"
        ));
    }
    let servers = strings(&v["authorization_servers"]);
    if servers.is_empty() {
        return Err("the server does not say which service signs people in".into());
    }
    Ok(ResourceInfo {
        authorization_servers: servers,
        scopes_supported: strings(&v["scopes_supported"]),
    })
}

/// Where to look for an authorization server's metadata: RFC 8414, then OpenID Connect discovery.
pub fn auth_server_metadata_urls(issuer: &str) -> Vec<String> {
    let Some((origin, path)) = split_url(issuer) else {
        return Vec::new();
    };
    if path.is_empty() {
        return vec![
            format!("{origin}/.well-known/oauth-authorization-server"),
            format!("{origin}/.well-known/openid-configuration"),
        ];
    }
    vec![
        format!("{origin}/.well-known/oauth-authorization-server{path}"),
        format!("{origin}/.well-known/openid-configuration{path}"),
        format!("{origin}{path}/.well-known/openid-configuration"),
    ]
}

/// What the app needs of an authorization server's metadata.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct AuthServer {
    pub issuer: String,
    pub authorization_endpoint: String,
    pub token_endpoint: String,
    pub registration_endpoint: Option<String>,
    pub scopes_supported: Vec<String>,
}

/// Reads authorization server metadata and checks it: the issuer is the one asked, the endpoints
/// are web addresses, and PKCE with S256 is supported (the specification says to refuse otherwise).
pub fn parse_auth_server(body: &str, issuer: &str) -> Result<AuthServer, String> {
    let v: Value = serde_json::from_str(body)
        .map_err(|_| "the sign-in service's information is not JSON".to_string())?;
    let said = v["issuer"].as_str().unwrap_or_default();
    if said.trim_end_matches('/') != issuer.trim_end_matches('/') {
        return Err(format!(
            "the sign-in service says it is {said:?}, not {issuer}"
        ));
    }
    let endpoint = |key: &str| -> Result<String, String> {
        let url = v[key].as_str().unwrap_or_default();
        if split_url(url).is_none() {
            return Err(format!("the sign-in service has no usable {key}"));
        }
        Ok(url.to_string())
    };
    if !strings(&v["code_challenge_methods_supported"])
        .iter()
        .any(|m| m == "S256")
    {
        return Err(
            "the sign-in service does not support PKCE with S256, so Imp will not use it".into(),
        );
    }
    let grants = strings(&v["grant_types_supported"]);
    if !grants.is_empty() && !grants.iter().any(|g| g == "authorization_code") {
        return Err("the sign-in service does not allow the authorization code grant".into());
    }
    Ok(AuthServer {
        issuer: issuer.to_string(),
        authorization_endpoint: endpoint("authorization_endpoint")?,
        token_endpoint: endpoint("token_endpoint")?,
        registration_endpoint: v["registration_endpoint"]
            .as_str()
            .filter(|u| split_url(u).is_some())
            .map(str::to_string),
        scopes_supported: strings(&v["scopes_supported"]),
    })
}

/// The scope to ask for: the challenge's, else all the resource's, else nothing.
pub fn choose_scope(challenge: Option<&str>, supported: &[String]) -> Option<String> {
    challenge
        .map(str::to_string)
        .or_else(|| (!supported.is_empty()).then(|| supported.join(" ")))
}

/// The body of a dynamic client registration (RFC 7591) for a public client.
pub fn registration_body(redirect_uris: &[String]) -> Value {
    json!({
        "client_name": CLIENT_NAME,
        "redirect_uris": redirect_uris,
        "grant_types": ["authorization_code", "refresh_token"],
        "response_types": ["code"],
        "token_endpoint_auth_method": "none",
    })
}

/// The `client_id` from a registration answer.
pub fn parse_registration(status: u16, body: &str) -> Result<String, String> {
    if !(200..300).contains(&status) {
        return Err(match parse_oauth_error(body) {
            Some(e) => format!("the sign-in service refused Imp: {e}"),
            None => format!("the sign-in service refused Imp (HTTP {status})"),
        });
    }
    let v: Value = serde_json::from_str(body)
        .map_err(|_| "the sign-in service's registration answer is not JSON".to_string())?;
    v["client_id"]
        .as_str()
        .filter(|c| !c.is_empty())
        .map(str::to_string)
        .ok_or_else(|| "the sign-in service gave no client id".into())
}

/// A PKCE verifier and its S256 challenge.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Pkce {
    pub verifier: String,
    pub challenge: String,
}

/// The S256 challenge of a verifier.
pub fn pkce_challenge(verifier: &str) -> String {
    URL_SAFE_NO_PAD.encode(Sha256::digest(verifier.as_bytes()))
}

fn random_text() -> String {
    URL_SAFE_NO_PAD.encode(rand::random::<[u8; 32]>())
}

/// A new random verifier (43 characters) with its challenge.
pub fn pkce_new() -> Pkce {
    let verifier = random_text();
    Pkce {
        challenge: pkce_challenge(&verifier),
        verifier,
    }
}

/// A new random `state`.
pub fn random_state() -> String {
    random_text()
}

/// Percent-encodes as `application/x-www-form-urlencoded` does.
pub fn form_encode(pairs: &[(&str, &str)]) -> String {
    pairs
        .iter()
        .map(|(k, v)| format!("{}={}", percent(k), percent(v)))
        .collect::<Vec<_>>()
        .join("&")
}

fn percent(s: &str) -> String {
    s.bytes()
        .map(|b| {
            if b.is_ascii_alphanumeric() || matches!(b, b'-' | b'.' | b'_' | b'~') {
                char::from(b).to_string()
            } else {
                format!("%{b:02X}")
            }
        })
        .collect()
}

fn unpercent(s: &str) -> String {
    let bytes = s.as_bytes();
    let mut out = Vec::new();
    let mut i = 0;
    while i < bytes.len() {
        match bytes[i] {
            b'+' => out.push(b' '),
            b'%' if i + 2 < bytes.len() => {
                match std::str::from_utf8(&bytes[i + 1..i + 3])
                    .ok()
                    .and_then(|h| u8::from_str_radix(h, 16).ok())
                {
                    Some(b) => {
                        out.push(b);
                        i += 2;
                    }
                    None => out.push(b'%'),
                }
            }
            b => out.push(b),
        }
        i += 1;
    }
    String::from_utf8_lossy(&out).into_owned()
}

/// The address to open in the browser (authorization code flow with PKCE, RFC 8707 `resource`).
pub fn authorize_url(
    server: &AuthServer,
    client_id: &str,
    redirect_uri: &str,
    code_challenge: &str,
    state: &str,
    scope: Option<&str>,
    mcp_url: &str,
) -> String {
    let resource = canonical_resource(mcp_url);
    let mut pairs = vec![
        ("response_type", "code"),
        ("client_id", client_id),
        ("redirect_uri", redirect_uri),
        ("code_challenge", code_challenge),
        ("code_challenge_method", "S256"),
        ("state", state),
        ("resource", resource.as_str()),
    ];
    if let Some(scope) = scope.filter(|s| !s.is_empty()) {
        pairs.push(("scope", scope));
    }
    let sep = if server.authorization_endpoint.contains('?') {
        '&'
    } else {
        '?'
    };
    format!(
        "{}{sep}{}",
        server.authorization_endpoint,
        form_encode(&pairs)
    )
}

/// The code from the address the browser was sent back to (or just its query), after checking
/// `state`. The error is a sentence.
pub fn parse_callback(callback: &str, expected_state: &str) -> Result<String, String> {
    let query = callback.split_once('?').map_or(callback, |(_, q)| q);
    let query = query.split('#').next().unwrap_or_default();
    let get = |name: &str| {
        query
            .split('&')
            .filter_map(|p| p.split_once('='))
            .find(|(k, _)| *k == name)
            .map(|(_, v)| unpercent(v))
    };
    if get("state").as_deref() != Some(expected_state) {
        return Err("the sign-in answer did not match this sign-in (wrong state)".into());
    }
    if let Some(error) = get("error") {
        let detail = get("error_description").unwrap_or_default();
        return Err(if error == "access_denied" {
            "the sign-in was cancelled".into()
        } else {
            format!("the sign-in failed: {error} {detail}")
                .trim()
                .to_string()
        });
    }
    get("code")
        .filter(|c| !c.is_empty())
        .ok_or_else(|| "the sign-in answer had no code".into())
}

/// The form body that trades a code for tokens.
pub fn token_request_code(
    client_id: &str,
    code: &str,
    redirect_uri: &str,
    verifier: &str,
    mcp_url: &str,
) -> String {
    let resource = canonical_resource(mcp_url);
    form_encode(&[
        ("grant_type", "authorization_code"),
        ("code", code),
        ("redirect_uri", redirect_uri),
        ("client_id", client_id),
        ("code_verifier", verifier),
        ("resource", resource.as_str()),
    ])
}

/// The form body that trades a refresh token for new tokens.
pub fn token_request_refresh(client_id: &str, refresh_token: &str, mcp_url: &str) -> String {
    let resource = canonical_resource(mcp_url);
    form_encode(&[
        ("grant_type", "refresh_token"),
        ("refresh_token", refresh_token),
        ("client_id", client_id),
        ("resource", resource.as_str()),
    ])
}

/// What an authorization server gave.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TokenGrant {
    pub access_token: String,
    pub refresh_token: Option<String>,
    /// Unix seconds. Nothing when the server did not say.
    pub expires_at: Option<u64>,
    pub scope: Option<String>,
}

/// `error` and `error_description` of an RFC 6749 error body, as one phrase.
pub fn parse_oauth_error(body: &str) -> Option<String> {
    let v: Value = serde_json::from_str(body).ok()?;
    let error = v["error"].as_str()?;
    Some(match v["error_description"].as_str() {
        Some(d) if !d.is_empty() => format!("{error} ({d})"),
        _ => error.to_string(),
    })
}

/// Whether an error body says the refresh token or code is no good any more (`invalid_grant`).
pub fn is_invalid_grant(body: &str) -> bool {
    serde_json::from_str::<Value>(body)
        .ok()
        .and_then(|v| v["error"].as_str().map(|e| e == "invalid_grant"))
        .unwrap_or(false)
}

/// Reads a token endpoint answer. `now` is Unix seconds.
pub fn parse_token_response(status: u16, body: &str, now: u64) -> Result<TokenGrant, String> {
    if !(200..300).contains(&status) {
        return Err(match parse_oauth_error(body) {
            Some(e) => format!("the sign-in service refused: {e}"),
            None => format!("the sign-in service refused (HTTP {status})"),
        });
    }
    let v: Value = serde_json::from_str(body)
        .map_err(|_| "the sign-in service's token answer is not JSON".to_string())?;
    let access = v["access_token"]
        .as_str()
        .filter(|t| !t.is_empty())
        .ok_or("the sign-in service gave no access token")?;
    if let Some(kind) = v["token_type"].as_str()
        && !kind.eq_ignore_ascii_case("bearer")
    {
        return Err(format!(
            "the sign-in service gave a {kind} token, not Bearer"
        ));
    }
    Ok(TokenGrant {
        access_token: access.to_string(),
        refresh_token: v["refresh_token"].as_str().map(str::to_string),
        expires_at: v["expires_in"]
            .as_u64()
            .or_else(|| v["expires_in"].as_f64().map(|f| f.max(0.0) as u64))
            .map(|s| now + s),
        scope: v["scope"].as_str().map(str::to_string),
    })
}

/// What a caller keeps for one MCP server after signing in. It holds secrets: store it privately.
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
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
            .field("client_id", &self.client_id)
            .finish_non_exhaustive()
    }
}

impl McpAuth {
    pub fn new(
        server: &AuthServer,
        client_id: &str,
        redirect_uri: &str,
        grant: TokenGrant,
    ) -> Self {
        Self {
            issuer: server.issuer.clone(),
            token_endpoint: server.token_endpoint.clone(),
            client_id: client_id.to_string(),
            redirect_uri: redirect_uri.to_string(),
            access_token: grant.access_token,
            refresh_token: grant.refresh_token,
            expires_at: grant.expires_at,
            scope: grant.scope,
        }
    }

    /// The record after a refresh. A refresh token that was not rotated stays.
    pub fn refreshed(&self, grant: TokenGrant) -> Self {
        Self {
            access_token: grant.access_token,
            refresh_token: grant.refresh_token.or_else(|| self.refresh_token.clone()),
            expires_at: grant.expires_at,
            scope: grant.scope.or_else(|| self.scope.clone()),
            ..self.clone()
        }
    }

    /// Whether to refresh before the next request: the token has less than a minute left.
    pub fn needs_refresh(&self, now: u64) -> bool {
        self.expires_at
            .is_some_and(|at| at.saturating_sub(now) < REFRESH_MARGIN_SECS)
    }

    /// The header to add to a request.
    pub fn header(&self) -> (String, String) {
        (
            "Authorization".into(),
            format!("Bearer {}", self.access_token),
        )
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn challenge_parsing() {
        let c = parse_challenge(
            r#"Bearer realm="x", resource_metadata="https://a.example/.well-known/oauth-protected-resource/mcp", scope="publish read""#,
        )
        .unwrap();
        assert_eq!(
            c.resource_metadata.as_deref(),
            Some("https://a.example/.well-known/oauth-protected-resource/mcp")
        );
        assert_eq!(c.scope.as_deref(), Some("publish read"));
        assert!(!c.insufficient_scope);
        let c = parse_challenge(r#"bearer error=insufficient_scope, scope="a""#).unwrap();
        assert!(c.insufficient_scope);
        assert_eq!(parse_challenge("Basic realm=x"), None);
        assert_eq!(parse_challenge("Bearer").unwrap(), Challenge::default());
    }

    #[test]
    fn metadata_addresses() {
        assert_eq!(
            resource_metadata_urls("https://A.example/mcp/", None),
            vec![
                "https://a.example/.well-known/oauth-protected-resource/mcp",
                "https://a.example/.well-known/oauth-protected-resource"
            ]
        );
        assert_eq!(
            resource_metadata_urls("https://a.example", Some("https://a.example/m")),
            vec![
                "https://a.example/m",
                "https://a.example/.well-known/oauth-protected-resource"
            ]
        );
        assert_eq!(auth_server_metadata_urls("https://i.example/t/1").len(), 3);
        assert_eq!(
            auth_server_metadata_urls("https://i.example")[1],
            "https://i.example/.well-known/openid-configuration"
        );
        assert_eq!(
            canonical_resource("HTTPS://A.example:8/mcp/?x=1#f"),
            "https://a.example:8/mcp"
        );
    }

    #[test]
    fn resource_and_server_validation() {
        let ok = r#"{"resource":"https://a.example/mcp","authorization_servers":["https://a.example"],"scopes_supported":["publish"]}"#;
        let info = parse_resource_metadata(ok, "https://a.example/mcp").unwrap();
        assert_eq!(info.authorization_servers, ["https://a.example"]);
        assert!(parse_resource_metadata(ok, "https://b.example/mcp").is_err());
        assert!(parse_resource_metadata("{}", "https://a.example/mcp").is_err());

        let meta = |extra: &str| {
            format!(
                r#"{{"issuer":"https://a.example","authorization_endpoint":"https://a.example/a","token_endpoint":"https://a.example/t","registration_endpoint":"https://a.example/r"{extra}}}"#
            )
        };
        let good = meta(r#","code_challenge_methods_supported":["S256"]"#);
        let s = parse_auth_server(&good, "https://a.example").unwrap();
        assert_eq!(
            s.registration_endpoint.as_deref(),
            Some("https://a.example/r")
        );
        assert!(parse_auth_server(&good, "https://evil.example").is_err());
        assert!(parse_auth_server(&meta(""), "https://a.example").is_err());
        assert!(
            parse_auth_server(
                &meta(r#","code_challenge_methods_supported":["plain"]"#),
                "https://a.example"
            )
            .is_err()
        );
    }

    #[test]
    fn pkce_matches_rfc7636_example() {
        assert_eq!(
            pkce_challenge("dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"),
            "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"
        );
        let p = pkce_new();
        assert_eq!(p.verifier.len(), 43);
        assert_eq!(pkce_challenge(&p.verifier), p.challenge);
        assert_ne!(random_state(), random_state());
    }

    #[test]
    fn authorize_url_and_callback() {
        let server = AuthServer {
            issuer: "https://a.example".into(),
            authorization_endpoint: "https://a.example/oauth/authorize".into(),
            token_endpoint: "https://a.example/oauth/token".into(),
            registration_endpoint: None,
            scopes_supported: vec![],
        };
        let url = authorize_url(
            &server,
            "c1",
            "http://127.0.0.1:9/oauth",
            "CH",
            "s t",
            Some("publish"),
            "https://a.example/mcp",
        );
        assert!(url.starts_with("https://a.example/oauth/authorize?response_type=code&client_id=c1&redirect_uri=http%3A%2F%2F127.0.0.1%3A9%2Foauth&"));
        assert!(url.contains("code_challenge_method=S256&state=s%20t&resource=https%3A%2F%2Fa.example%2Fmcp&scope=publish"));

        assert_eq!(
            parse_callback("/oauth?code=abc%2F1&state=s%20t", "s t").unwrap(),
            "abc/1"
        );
        assert!(parse_callback("/oauth?code=abc&state=other", "s t").is_err());
        assert!(
            parse_callback("/oauth?error=access_denied&state=s", "s")
                .unwrap_err()
                .contains("cancelled")
        );
        assert!(parse_callback("/oauth?state=s", "s").is_err());
    }

    #[test]
    fn registration_and_tokens() {
        let body = registration_body(&["http://127.0.0.1:1/oauth".into()]);
        assert_eq!(body["client_name"], "Imp");
        assert_eq!(body["token_endpoint_auth_method"], "none");
        assert_eq!(
            parse_registration(201, r#"{"client_id":"x"}"#).unwrap(),
            "x"
        );
        assert!(
            parse_registration(400, r#"{"error":"invalid_redirect_uri"}"#)
                .unwrap_err()
                .contains("invalid_redirect_uri")
        );

        let body = token_request_code(
            "c",
            "co de",
            "http://127.0.0.1:1/oauth",
            "v",
            "https://a.example/mcp/",
        );
        assert_eq!(
            body,
            "grant_type=authorization_code&code=co%20de&redirect_uri=http%3A%2F%2F127.0.0.1%3A1%2Foauth&client_id=c&code_verifier=v&resource=https%3A%2F%2Fa.example%2Fmcp"
        );
        assert!(
            token_request_refresh("c", "r", "https://a.example/mcp")
                .contains("grant_type=refresh_token&refresh_token=r")
        );

        let grant = parse_token_response(200, r#"{"access_token":"a","token_type":"Bearer","expires_in":3600,"refresh_token":"r","scope":"publish"}"#, 1000).unwrap();
        assert_eq!(grant.expires_at, Some(4600));
        assert!(
            parse_token_response(
                400,
                r#"{"error":"invalid_grant","error_description":"old"}"#,
                0
            )
            .unwrap_err()
            .contains("invalid_grant (old)")
        );
        assert!(is_invalid_grant(r#"{"error":"invalid_grant"}"#));
        assert!(
            parse_token_response(200, r#"{"access_token":"a","token_type":"mac"}"#, 0).is_err()
        );
    }

    #[test]
    fn stored_grant_refresh_rules() {
        let server = AuthServer {
            issuer: "https://a.example".into(),
            authorization_endpoint: "https://a.example/a".into(),
            token_endpoint: "https://a.example/t".into(),
            registration_endpoint: None,
            scopes_supported: vec![],
        };
        let grant = TokenGrant {
            access_token: "a".into(),
            refresh_token: Some("r".into()),
            expires_at: Some(1000),
            scope: None,
        };
        let auth = McpAuth::new(&server, "c", "http://127.0.0.1:1/oauth", grant);
        assert!(!auth.needs_refresh(900));
        assert!(auth.needs_refresh(941));
        assert_eq!(auth.header(), ("Authorization".into(), "Bearer a".into()));
        let next = auth.refreshed(TokenGrant {
            access_token: "b".into(),
            refresh_token: None,
            expires_at: Some(5000),
            scope: None,
        });
        assert_eq!(next.refresh_token.as_deref(), Some("r"));
        assert_eq!(next.access_token, "b");
        assert!(
            !format!("{auth:?}").contains('a') || !format!("{auth:?}").contains("access_token")
        );
    }
}
