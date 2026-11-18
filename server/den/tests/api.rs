//! In-process tests of the Den: OAuth, MCP, the read API and the limits. No network, no browser.

use std::path::PathBuf;
use std::sync::Arc;

use altcha::{Payload, SolveChallengeOptions};
use axum::Router;
use axum::body::Body;
use axum::http::{Method, Request, Response, StatusCode};
use base64::Engine;
use base64::engine::general_purpose::{STANDARD, URL_SAFE_NO_PAD};
use imp_den::Den;
use imp_den::config::{Config, PublicUrl};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use tower::ServiceExt;

const KIT: &str = include_str!("fixtures/moody-moves.json");
const REDIRECT: &str = "http://127.0.0.1:8765/oauth";
const VERIFIER: &str = "a-verifier-of-more-than-forty-three-characters-0123456789";

struct Harness {
    app: Router,
    den: Arc<Den>,
    database: PathBuf,
}

/// A signed-in account: its key and the tokens of one grant.
struct Session {
    client_id: String,
    handle: String,
    key: String,
    access: String,
    refresh: String,
}

impl Drop for Harness {
    fn drop(&mut self) {
        for suffix in ["", "-wal", "-shm"] {
            let mut name = self.database.clone().into_os_string();
            name.push(suffix);
            let _ = std::fs::remove_file(name);
        }
    }
}

fn encode(s: &str) -> String {
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

fn form(pairs: &[(&str, &str)]) -> String {
    pairs
        .iter()
        .map(|(k, v)| format!("{k}={}", encode(v)))
        .collect::<Vec<_>>()
        .join("&")
}

fn challenge_of(verifier: &str) -> String {
    URL_SAFE_NO_PAD.encode(Sha256::digest(verifier.as_bytes()))
}

async fn read_bytes(response: Response<Body>) -> Vec<u8> {
    axum::body::to_bytes(response.into_body(), usize::MAX)
        .await
        .unwrap()
        .to_vec()
}

async fn read_json(response: Response<Body>) -> Value {
    serde_json::from_slice(&read_bytes(response).await).unwrap_or(Value::Null)
}

async fn read_text(response: Response<Body>) -> String {
    String::from_utf8(read_bytes(response).await).unwrap()
}

impl Harness {
    async fn new() -> Self {
        let database = std::env::temp_dir().join(format!(
            "den-test-{}.sqlite",
            hex::encode(rand::random::<[u8; 8]>())
        ));
        let path = database.to_string_lossy().into_owned();
        let config = Config {
            addr: "127.0.0.1:0".parse().unwrap(),
            database: path.clone(),
            secret: "a-test-secret-of-at-least-32-bytes!".to_owned(),
            public: PublicUrl::parse("https://den.test").unwrap(),
            trusted_proxies: "0.0.0.0/32".parse().unwrap(),
            altcha_cost: 10,
            json_logs: false,
        };
        let pool = imp_den::db::open(&path).await.unwrap();
        let den = Den::new(config, pool).await;
        Self {
            app: imp_den::router(Arc::clone(&den)),
            den,
            database,
        }
    }

    async fn request(
        &self,
        method: Method,
        uri: &str,
        ip: &str,
        content_type: Option<&str>,
        body: String,
    ) -> Response<Body> {
        let mut request = Request::builder()
            .method(method)
            .uri(uri)
            .header("host", "den.test")
            .header("x-forwarded-for", ip);
        if let Some(content_type) = content_type {
            request = request.header("content-type", content_type);
        }
        self.app
            .clone()
            .oneshot(request.body(Body::from(body)).unwrap())
            .await
            .unwrap()
    }

    async fn get(&self, uri: &str) -> (StatusCode, Value) {
        let response = self
            .request(Method::GET, uri, "10.0.0.1", None, String::new())
            .await;
        (response.status(), read_json(response).await)
    }

    async fn post_json(&self, uri: &str, ip: &str, body: &Value) -> Response<Body> {
        self.request(
            Method::POST,
            uri,
            ip,
            Some("application/json"),
            body.to_string(),
        )
        .await
    }

    async fn post_form(&self, uri: &str, ip: &str, pairs: &[(&str, &str)]) -> Response<Body> {
        self.request(
            Method::POST,
            uri,
            ip,
            Some("application/x-www-form-urlencoded"),
            form(pairs),
        )
        .await
    }

    async fn solved(&self, ip: &str) -> String {
        let response = self
            .request(Method::GET, "/challenge", ip, None, String::new())
            .await;
        assert_eq!(response.status(), StatusCode::OK);
        let challenge: altcha::Challenge =
            serde_json::from_value(read_json(response).await).unwrap();
        let solution = altcha::solve_challenge(SolveChallengeOptions::new(&challenge))
            .unwrap()
            .unwrap();
        STANDARD.encode(
            serde_json::to_vec(&Payload {
                challenge,
                solution,
            })
            .unwrap(),
        )
    }

    async fn register(&self, ip: &str) -> String {
        let response = self
            .post_json(
                "/oauth/register",
                ip,
                &json!({ "client_name": "Test host", "redirect_uris": [REDIRECT] }),
            )
            .await;
        assert_eq!(response.status(), StatusCode::CREATED);
        read_json(response).await["client_id"]
            .as_str()
            .unwrap()
            .to_owned()
    }

    fn authorize_pairs<'a>(client_id: &'a str, challenge: &'a str) -> Vec<(&'a str, &'a str)> {
        vec![
            ("response_type", "code"),
            ("client_id", client_id),
            ("redirect_uri", REDIRECT),
            ("code_challenge", challenge),
            ("code_challenge_method", "S256"),
            ("state", "st 1"),
            ("scope", "publish"),
            ("resource", "https://den.test/mcp"),
        ]
    }

    /// Runs the authorize form with `extra` fields and returns the response.
    async fn authorize(&self, client_id: &str, ip: &str, extra: &[(&str, &str)]) -> Response<Body> {
        let challenge = challenge_of(VERIFIER);
        let mut pairs = Self::authorize_pairs(client_id, &challenge);
        pairs.extend_from_slice(extra);
        self.post_form("/oauth/authorize", ip, &pairs).await
    }

    async fn token(&self, ip: &str, pairs: &[(&str, &str)]) -> (StatusCode, Value) {
        let response = self.post_form("/oauth/token", ip, pairs).await;
        (response.status(), read_json(response).await)
    }

    /// New account through the whole flow: register, sign-up page, key page, code, token.
    async fn sign_up(&self, handle: &str, ip: &str) -> Session {
        let client_id = self.register(ip).await;
        let proof = self.solved(ip).await;
        let response = self
            .authorize(
                &client_id,
                ip,
                &[("mode", "new"), ("handle", handle), ("altcha", &proof)],
            )
            .await;
        assert_eq!(response.status(), StatusCode::OK);
        let page = read_text(response).await;
        let at = page.find("dak_").expect("the key is shown");
        let key = page[at..at + 47].to_owned();
        let mut session = Session {
            client_id,
            handle: handle.to_owned(),
            key,
            access: String::new(),
            refresh: String::new(),
        };
        self.sign_in(&mut session, ip).await;
        session
    }

    async fn sign_in(&self, s: &mut Session, ip: &str) {
        let response = self
            .authorize(&s.client_id, ip, &[("mode", "existing"), ("key", &s.key)])
            .await;
        assert_eq!(response.status(), StatusCode::SEE_OTHER);
        let location = response.headers()["location"].to_str().unwrap().to_owned();
        assert!(location.starts_with("http://127.0.0.1:8765/oauth?code="));
        assert!(location.ends_with("&state=st%201"));
        let code = location
            .split("code=")
            .nth(1)
            .unwrap()
            .split('&')
            .next()
            .unwrap();
        let (status, tokens) = self
            .token(
                ip,
                &[
                    ("grant_type", "authorization_code"),
                    ("code", code),
                    ("client_id", &s.client_id),
                    ("redirect_uri", REDIRECT),
                    ("code_verifier", VERIFIER),
                ],
            )
            .await;
        assert_eq!(status, StatusCode::OK, "{tokens}");
        assert_eq!(tokens["token_type"], "Bearer");
        assert_eq!(tokens["expires_in"], 3600);
        s.access = tokens["access_token"].as_str().unwrap().to_owned();
        s.refresh = tokens["refresh_token"].as_str().unwrap().to_owned();
        assert!(s.access.starts_with("dat_") && s.access.len() == 47);
        assert!(s.refresh.starts_with("drt_") && s.refresh.len() == 47);
    }

    async fn mcp_raw(&self, token: Option<&str>, method: &str, params: Value) -> Response<Body> {
        let body = json!({ "jsonrpc": "2.0", "id": 1, "method": method, "params": params });
        let mut request = Request::builder()
            .method(Method::POST)
            .uri("/mcp")
            .header("host", "den.test")
            .header("origin", "https://den.test")
            .header("content-type", "application/json")
            .header("accept", "application/json, text/event-stream")
            .header(
                "mcp-protocol-version",
                params["protocolVersion"].as_str().unwrap_or("2025-11-25"),
            );
        if let Some(token) = token {
            request = request.header("authorization", format!("Bearer {token}"));
        }
        self.app
            .clone()
            .oneshot(request.body(Body::from(body.to_string())).unwrap())
            .await
            .unwrap()
    }

    /// A 2026-07-28 request: no `initialize`, the revision and capabilities travel in `_meta`.
    async fn mcp_stateless(
        &self,
        method: &str,
        name: Option<&str>,
        mut params: Value,
    ) -> Response<Body> {
        params["_meta"] = json!({
            "io.modelcontextprotocol/protocolVersion": "2026-07-28",
            "io.modelcontextprotocol/clientCapabilities": {},
            "io.modelcontextprotocol/clientInfo": { "name": "t", "version": "1" }
        });
        let body = json!({ "jsonrpc": "2.0", "id": 1, "method": method, "params": params });
        let mut request = Request::builder()
            .method(Method::POST)
            .uri("/mcp")
            .header("host", "den.test")
            .header("origin", "https://den.test")
            .header("content-type", "application/json")
            .header("accept", "application/json, text/event-stream")
            .header("mcp-protocol-version", "2026-07-28")
            .header("mcp-method", method);
        if let Some(name) = name {
            request = request.header("mcp-name", name);
        }
        self.app
            .clone()
            .oneshot(request.body(Body::from(body.to_string())).unwrap())
            .await
            .unwrap()
    }

    /// Calls one tool. Returns the HTTP status, whether the tool failed, and its structured answer.
    async fn tool(
        &self,
        token: Option<&str>,
        name: &str,
        arguments: Value,
    ) -> (StatusCode, bool, Value) {
        let response = self
            .mcp_raw(
                token,
                "tools/call",
                json!({ "name": name, "arguments": arguments }),
            )
            .await;
        let status = response.status();
        let body = read_json(response).await;
        let result = &body["result"];
        (
            status,
            result["isError"] == true,
            result["structuredContent"].clone(),
        )
    }

    async fn publish(&self, s: &Session, kind: &str, slug: &str, document: Value) -> (bool, Value) {
        let (status, failed, answer) = self
            .tool(
                Some(&s.access),
                "publish_item",
                json!({ "type": kind, "slug": slug, "summary": "A small thing", "tags": ["demo"], "document": document }),
            )
            .await;
        assert_eq!(status, StatusCode::OK);
        (failed, answer)
    }
}

fn imp_doc(name: &str) -> Value {
    json!({ "format": 1, "name": name, "imps": [{ "name": name, "on": "wake", "do": [{ "act": "say", "value": "Hi" }] }] })
}
fn animation_doc(name: &str) -> Value {
    json!({ "format": 1, "name": name, "animations": [{ "name": name, "beats": [{ "duration": 0.5, "mood": "happy" }] }] })
}
fn trigger_doc(name: &str) -> Value {
    json!({ "format": 1, "name": name, "triggers": [{ "name": name, "on": "wake", "do": [{ "act": "say", "value": "Hi" }] }] })
}
fn tool_doc(name: &str) -> Value {
    json!({ "format": 1, "name": name, "mcpServers": { name: { "url": format!("https://{name}.example/mcp") } } })
}
fn kit_doc(name: &str) -> Value {
    json!({ "format": 1, "name": name, "imps": [{ "name": name, "on": "wake", "do": [{ "act": "say", "value": "Hi" }] }], "animations": [{ "name": name, "beats": [{ "duration": 1 }] }] })
}

#[tokio::test]
async fn discovery_documents() {
    let h = Harness::new().await;
    for path in [
        "/.well-known/oauth-protected-resource",
        "/.well-known/oauth-protected-resource/mcp",
    ] {
        let (status, doc) = h.get(path).await;
        assert_eq!(status, StatusCode::OK);
        assert_eq!(doc["resource"], "https://den.test/mcp");
        assert_eq!(doc["authorization_servers"], json!(["https://den.test"]));
        assert_eq!(doc["scopes_supported"], json!(["publish"]));
        assert_eq!(doc["bearer_methods_supported"], json!(["header"]));
    }
    let (_, meta) = h.get("/.well-known/oauth-authorization-server").await;
    assert_eq!(meta["issuer"], "https://den.test");
    assert_eq!(
        meta["authorization_endpoint"],
        "https://den.test/oauth/authorize"
    );
    assert_eq!(meta["token_endpoint"], "https://den.test/oauth/token");
    assert_eq!(
        meta["registration_endpoint"],
        "https://den.test/oauth/register"
    );
    assert_eq!(meta["revocation_endpoint"], "https://den.test/oauth/revoke");
    assert_eq!(meta["code_challenge_methods_supported"], json!(["S256"]));
    assert_eq!(
        meta["token_endpoint_auth_methods_supported"],
        json!(["none"])
    );
    assert_eq!(
        meta["grant_types_supported"],
        json!(["authorization_code", "refresh_token"])
    );

    let (_, version) = h.get("/version").await;
    assert_eq!(version["api"], 1);
    assert_eq!(version["formats"], json!([1]));
    assert_eq!(
        version["mcp"],
        json!(["2026-07-28", "2025-11-25", "2025-06-18"])
    );
}

#[tokio::test]
async fn client_registration_rules() {
    let h = Harness::new().await;
    for uri in [
        "https://app.example/cb",
        "http://localhost:3000/cb",
        "http://[::1]:4000/cb",
        "app.imp:/oauth",
    ] {
        let response = h
            .post_json(
                "/oauth/register",
                "10.0.0.2",
                &json!({ "client_name": "x", "redirect_uris": [uri] }),
            )
            .await;
        assert_eq!(response.status(), StatusCode::CREATED, "{uri}");
        let doc = read_json(response).await;
        assert!(doc["client_id"].as_str().is_some_and(|id| !id.is_empty()));
        assert_eq!(doc["token_endpoint_auth_method"], "none");
    }
    for uri in [
        "http://example.com/cb",
        "javascript:alert(1)",
        "myapp:/cb",
        "https://a.example/cb#frag",
    ] {
        let response = h
            .post_json(
                "/oauth/register",
                "10.0.0.2",
                &json!({ "client_name": "x", "redirect_uris": [uri] }),
            )
            .await;
        assert_eq!(response.status(), StatusCode::BAD_REQUEST, "{uri}");
        assert_eq!(
            read_json(response).await["error"],
            "invalid_redirect_uri",
            "{uri}"
        );
    }
    let response = h
        .post_json(
            "/oauth/register",
            "10.0.0.2",
            &json!({ "client_name": "x", "redirect_uris": [REDIRECT], "token_endpoint_auth_method": "client_secret_basic" }),
        )
        .await;
    assert_eq!(response.status(), StatusCode::BAD_REQUEST);
}

#[tokio::test]
async fn sign_in_page_and_flow() {
    let h = Harness::new().await;
    let client_id = h.register("10.0.0.3").await;
    let challenge = challenge_of(VERIFIER);
    let query = form(&Harness::authorize_pairs(&client_id, &challenge));
    let response = h
        .request(
            Method::GET,
            &format!("/oauth/authorize?{query}"),
            "10.0.0.3",
            None,
            String::new(),
        )
        .await;
    assert_eq!(response.status(), StatusCode::OK);
    assert!(response.headers().get("set-cookie").is_none());
    let csp = response.headers()["content-security-policy"]
        .to_str()
        .unwrap()
        .to_owned();
    assert!(csp.contains("default-src 'none'") && csp.contains("worker-src blob:"));
    assert!(!csp.contains("unsafe-inline") && !csp.contains("http"));
    let page = read_text(response).await;
    assert!(page.contains("Test host") && page.contains("127.0.0.1:8765"));
    assert!(page.contains("New account") && page.contains("dak_"));
    assert!(!page.contains("src=\"http"));

    // A new account: the key shows once, continuing gives a code.
    let session = h.sign_up("fresh-hand", "10.0.0.3").await;
    assert_eq!(session.handle, "fresh-hand");
    assert_eq!(session.key.len(), 47);
    let (status, view) = h.get("/accounts/fresh-hand").await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(view["handle"], "fresh-hand");

    // A challenge is accepted once; a taken handle and a bad handle are refused.
    let proof = h.solved("10.0.0.4").await;
    let used = |handle: &'static str, proof: String| {
        let h = &h;
        let client_id = client_id.clone();
        async move {
            h.authorize(
                &client_id,
                "10.0.0.4",
                &[("mode", "new"), ("handle", handle), ("altcha", &proof)],
            )
            .await
        }
    };
    assert_eq!(
        used("second-one", proof.clone()).await.status(),
        StatusCode::OK
    );
    assert_eq!(
        used("third-one", proof).await.status(),
        StatusCode::UNPROCESSABLE_ENTITY
    );
    let fresh = h.solved("10.0.0.4").await;
    assert_eq!(
        used("fresh-hand", fresh).await.status(),
        StatusCode::CONFLICT
    );
    let fresh = h.solved("10.0.0.4").await;
    assert_eq!(
        used("Admin", fresh).await.status(),
        StatusCode::UNPROCESSABLE_ENTITY
    );

    // Wrong key.
    let wrong = h
        .authorize(
            &client_id,
            "10.0.0.3",
            &[("mode", "existing"), ("key", "dak_nope")],
        )
        .await;
    assert_eq!(wrong.status(), StatusCode::FORBIDDEN);

    // Unknown redirect address and plain PKCE show an error page and redirect nowhere.
    let mut pairs = Harness::authorize_pairs(&client_id, &challenge);
    pairs[2].1 = "http://127.0.0.1:1/other";
    let response = h.post_form("/oauth/authorize", "10.0.0.3", &pairs).await;
    assert_eq!(response.status(), StatusCode::BAD_REQUEST);
    assert!(response.headers().get("location").is_none());
    let mut pairs = Harness::authorize_pairs(&client_id, &challenge);
    pairs[4].1 = "plain";
    let response = h.post_form("/oauth/authorize", "10.0.0.3", &pairs).await;
    assert_eq!(response.status(), StatusCode::BAD_REQUEST);
    // A loopback port may differ.
    let mut pairs = Harness::authorize_pairs(&client_id, &challenge);
    pairs[2].1 = "http://127.0.0.1:50000/oauth";
    pairs.extend_from_slice(&[("mode", "existing"), ("key", &session.key)]);
    let response = h.post_form("/oauth/authorize", "10.0.0.3", &pairs).await;
    assert_eq!(response.status(), StatusCode::SEE_OTHER);
    assert!(
        response.headers()["location"]
            .to_str()
            .unwrap()
            .starts_with("http://127.0.0.1:50000/oauth?code=")
    );
}

/// Gets a code and exchanges it twice with `verifier`. Returns both answers.
async fn exchange_twice(
    h: &Harness,
    s: &Session,
    ip: &str,
    verifier: &str,
) -> ((StatusCode, Value), (StatusCode, Value)) {
    let response = h
        .authorize(&s.client_id, ip, &[("mode", "existing"), ("key", &s.key)])
        .await;
    let location = response.headers()["location"].to_str().unwrap().to_owned();
    let code = location
        .split("code=")
        .nth(1)
        .unwrap()
        .split('&')
        .next()
        .unwrap()
        .to_owned();
    let pairs = [
        ("grant_type", "authorization_code"),
        ("code", code.as_str()),
        ("client_id", s.client_id.as_str()),
        ("redirect_uri", REDIRECT),
        ("code_verifier", verifier),
    ];
    (h.token(ip, &pairs).await, h.token(ip, &pairs).await)
}

#[tokio::test]
async fn token_exchange_rules() {
    let h = Harness::new().await;
    let ip = "10.0.1.1";
    let s = h.sign_up("pkce-fan", ip).await;
    // A wrong verifier fails, and the code is spent by the attempt.
    let ((status, body), _) = exchange_twice(
        &h,
        &s,
        ip,
        "a-different-verifier-of-more-than-forty-three-characters",
    )
    .await;
    assert_eq!(status, StatusCode::BAD_REQUEST);
    assert_eq!(body["error"], "invalid_grant");
    // The right one works once, a second use fails.
    let ((status, _), (again, body)) = exchange_twice(&h, &s, ip, VERIFIER).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(again, StatusCode::BAD_REQUEST);
    assert_eq!(body["error"], "invalid_grant");
    let (status, body) = h.token(ip, &[("grant_type", "password")]).await;
    assert_eq!(status, StatusCode::BAD_REQUEST);
    assert_eq!(body["error"], "unsupported_grant_type");
}

#[tokio::test]
async fn refresh_rotates_and_reuse_revokes_the_grant() {
    let h = Harness::new().await;
    let ip = "10.0.2.1";
    let s = h.sign_up("refresher", ip).await;
    let (status, fresh) = h
        .token(
            ip,
            &[
                ("grant_type", "refresh_token"),
                ("refresh_token", &s.refresh),
                ("client_id", &s.client_id),
            ],
        )
        .await;
    assert_eq!(status, StatusCode::OK, "{fresh}");
    let new_access = fresh["access_token"].as_str().unwrap().to_owned();
    let new_refresh = fresh["refresh_token"].as_str().unwrap().to_owned();
    assert_ne!(new_refresh, s.refresh);
    let (_, failed, _) = h.tool(Some(&new_access), "my_account", json!({})).await;
    assert!(!failed);

    // The old refresh token again: refused, and the whole grant ends.
    let (status, body) = h
        .token(
            ip,
            &[
                ("grant_type", "refresh_token"),
                ("refresh_token", &s.refresh),
                ("client_id", &s.client_id),
            ],
        )
        .await;
    assert_eq!(status, StatusCode::BAD_REQUEST);
    assert_eq!(body["error"], "invalid_grant");
    let response = h
        .mcp_raw(
            Some(&new_access),
            "tools/call",
            json!({ "name": "my_account", "arguments": {} }),
        )
        .await;
    assert_eq!(response.status(), StatusCode::UNAUTHORIZED);
    let (status, _) = h
        .token(
            ip,
            &[
                ("grant_type", "refresh_token"),
                ("refresh_token", &new_refresh),
                ("client_id", &s.client_id),
            ],
        )
        .await;
    assert_eq!(status, StatusCode::BAD_REQUEST);
}

#[tokio::test]
async fn revoking_ends_the_grant() {
    let h = Harness::new().await;
    let s = h.sign_up("revoker", "10.0.2.2").await;
    let response = h
        .post_form("/oauth/revoke", "10.0.2.2", &[("token", &s.refresh)])
        .await;
    assert_eq!(response.status(), StatusCode::OK);
    let response = h
        .mcp_raw(
            Some(&s.access),
            "tools/call",
            json!({ "name": "my_account", "arguments": {} }),
        )
        .await;
    assert_eq!(response.status(), StatusCode::UNAUTHORIZED);
    let response = h
        .post_form("/oauth/revoke", "10.0.2.2", &[("token", "dat_unknown")])
        .await;
    assert_eq!(response.status(), StatusCode::OK);
}

#[tokio::test]
async fn mcp_2026_07_28_works_without_initialize() {
    let h = Harness::new().await;
    let response = h.mcp_stateless("tools/list", None, json!({})).await;
    assert_eq!(response.status(), StatusCode::OK);
    let listed = read_json(response).await;
    assert_eq!(
        listed["result"]["tools"].as_array().unwrap().len(),
        7,
        "{listed}"
    );

    let response = h
        .mcp_stateless(
            "tools/call",
            Some("search_items"),
            json!({ "name": "search_items", "arguments": { "q": "moody" } }),
        )
        .await;
    assert_eq!(response.status(), StatusCode::OK);
    let called = read_json(response).await;
    assert_ne!(called["result"]["isError"], true, "{called}");
    assert!(
        called["result"]["structuredContent"]["items"].is_array(),
        "{called}"
    );

    let response = h
        .mcp_stateless(
            "tools/call",
            Some("publish_item"),
            json!({ "name": "publish_item", "arguments": {} }),
        )
        .await;
    assert_eq!(response.status(), StatusCode::UNAUTHORIZED);
    assert!(
        response.headers()["www-authenticate"]
            .to_str()
            .unwrap()
            .starts_with("Bearer resource_metadata=")
    );
}

#[tokio::test]
async fn mcp_reads_are_open_and_writes_need_a_token() {
    let h = Harness::new().await;
    let response = h.mcp_raw(None, "tools/list", json!({})).await;
    assert_eq!(response.status(), StatusCode::OK);
    let listed = read_json(response).await;
    let names: Vec<&str> = listed["result"]["tools"]
        .as_array()
        .unwrap()
        .iter()
        .map(|t| t["name"].as_str().unwrap())
        .collect();
    for tool in [
        "search_items",
        "get_item",
        "download_item",
        "publish_item",
        "delete_item",
        "my_account",
        "delete_account",
    ] {
        assert!(names.contains(&tool), "{tool} missing in {names:?}");
    }
    assert_eq!(names.len(), 7);
    let (status, failed, answer) = h.tool(None, "search_items", json!({ "q": "moody" })).await;
    assert_eq!((status, failed), (StatusCode::OK, false));
    assert!(answer["items"].is_array());

    for token in [None, Some("dat_unknown"), Some("garbage")] {
        let response = h
            .mcp_raw(
                token,
                "tools/call",
                json!({ "name": "publish_item", "arguments": {} }),
            )
            .await;
        assert_eq!(response.status(), StatusCode::UNAUTHORIZED);
        assert_eq!(
            response.headers()["www-authenticate"],
            "Bearer resource_metadata=\"https://den.test/.well-known/oauth-protected-resource/mcp\", scope=\"publish\""
        );
        assert_eq!(
            response.headers()["content-type"],
            "application/problem+json"
        );
    }
    // A batch with a write is guarded too.
    let batch = json!([
        { "jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": { "name": "search_items", "arguments": {} } },
        { "jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": { "name": "delete_account", "arguments": { "confirm": "x" } } },
    ]);
    let response = h
        .app
        .clone()
        .oneshot(
            Request::builder()
                .method(Method::POST)
                .uri("/mcp")
                .header("host", "den.test")
                .header("content-type", "application/json")
                .header("accept", "application/json, text/event-stream")
                .body(Body::from(batch.to_string()))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::UNAUTHORIZED);

    let response = h
        .app
        .clone()
        .oneshot(
            Request::builder()
                .method(Method::POST)
                .uri("/mcp")
                .header("host", "evil.example")
                .header("content-type", "application/json")
                .header("accept", "application/json, text/event-stream")
                .body(Body::from("{}"))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::FORBIDDEN);
}

#[tokio::test]
async fn protocol_revisions_are_negotiated() {
    let h = Harness::new().await;
    for (asked, expected) in [
        ("2025-06-18", "2025-06-18"),
        ("2025-11-25", "2025-11-25"),
        ("2026-07-28", "2025-11-25"),
        ("2024-01-01", "2025-11-25"),
    ] {
        let response = h
            .mcp_raw(
                None,
                "initialize",
                json!({ "protocolVersion": asked, "capabilities": {}, "clientInfo": { "name": "t", "version": "1" } }),
            )
            .await;
        assert_eq!(response.status(), StatusCode::OK, "{asked}");
        let body = read_json(response).await;
        assert_eq!(
            body["result"]["protocolVersion"], expected,
            "{asked}: {body}"
        );
        assert_eq!(
            body["result"]["serverInfo"]["version"],
            env!("CARGO_PKG_VERSION")
        );
    }
}

#[tokio::test]
async fn publish_each_type_and_refuse_mismatches() {
    let h = Harness::new().await;
    let s = h.sign_up("maker", "10.0.3.1").await;
    for (kind, doc) in [
        ("imp", imp_doc("Pip")),
        ("animation", animation_doc("Wave")),
        ("trigger", trigger_doc("On wake")),
        ("tool", tool_doc("lookup")),
        ("kit", kit_doc("Bundle")),
    ] {
        let (failed, item) = h.publish(&s, kind, &format!("my-{kind}"), doc).await;
        assert!(!failed, "{kind}: {item}");
        assert_eq!(item["type"], kind);
        assert_eq!(item["handle"], "maker");
        assert_eq!(item["revision"], 1);
        assert_eq!(item["runs_programs"], false);
    }
    let (_, stats) = h.get("/stats").await;
    assert_eq!(stats["items"], 5);
    assert_eq!(stats["by_type"]["kit"], 1);

    // A type that does not match the document.
    let (failed, problem) = h.publish(&s, "animation", "wrong", imp_doc("Other")).await;
    assert!(failed);
    assert_eq!(problem["status"], 422);
    assert!(
        problem["type"]
            .as_str()
            .unwrap()
            .ends_with("/problems/validation-failed")
    );
    assert!(
        problem["errors"][0]["pointer"]
            .as_str()
            .unwrap()
            .starts_with('/')
    );
    // Format: required, an integer, and not newer than the Den's.
    let mut no_format = animation_doc("NoFormat");
    no_format.as_object_mut().unwrap().remove("format");
    let (failed, problem) = h.publish(&s, "animation", "nf", no_format).await;
    assert!(failed);
    assert_eq!(problem["errors"][0]["pointer"], "/format");
    let mut newer = animation_doc("Newer");
    newer["format"] = json!(2);
    let (failed, problem) = h.publish(&s, "animation", "newer", newer).await;
    assert!(failed);
    assert!(
        problem["type"]
            .as_str()
            .unwrap()
            .ends_with("/problems/unsupported-format")
    );
    // Bad animation vocabulary and secrets.
    let mut bad = animation_doc("Bad");
    bad["animations"][0]["beats"][0]["mood"] = json!("furious");
    assert!(h.publish(&s, "animation", "bad", bad).await.0);
    let mut secret = tool_doc("secretive");
    secret["mcpServers"]["secretive"]["headers"] = json!({ "Authorization": "Bearer x" });
    assert!(h.publish(&s, "tool", "secret", secret).await.0);
    // Skills only in kits, and they mark the item.
    let mut skills = imp_doc("Skilled");
    skills["skills"] = json!([{ "name": "pdf", "source": "anthropics/skills/skills/pdf" }]);
    assert!(h.publish(&s, "imp", "skilled-imp", skills.clone()).await.0);
    let (failed, item) = h.publish(&s, "kit", "skilled-kit", skills).await;
    assert!(!failed, "{item}");
    assert_eq!(item["runs_programs"], true);
    // A program in a tool marks it too; the oversize check holds.
    let mut program = tool_doc("prog");
    program["mcpServers"]["prog"] = json!({ "command": "npx", "args": ["x"] });
    let (failed, item) = h.publish(&s, "tool", "prog", program).await;
    assert!(!failed);
    assert_eq!(item["runs_programs"], true);
    let mut big = animation_doc("Big");
    big["about"] = json!("x".repeat(70_000));
    assert!(h.publish(&s, "animation", "big", big).await.0);
    // The real fixture is a kit.
    let doc: Value = serde_json::from_str(KIT).unwrap();
    let (failed, item) = h.publish(&s, "kit", "moody-moves", doc).await;
    assert!(!failed, "{item}");
}

#[tokio::test]
async fn duplicates_republishing_and_revisions() {
    let h = Harness::new().await;
    let a = h.sign_up("dup-a", "10.0.4.1").await;
    let b = h.sign_up("dup-b", "10.0.4.2").await;
    let (failed, first) = h
        .publish(&a, "animation", "wave", animation_doc("Wave"))
        .await;
    assert!(!failed);
    assert_eq!(first["revision"], 1);
    // The same document to the same item: no new revision.
    let (failed, same) = h
        .publish(&a, "animation", "wave", animation_doc("Wave"))
        .await;
    assert!(!failed);
    assert_eq!(same["revision"], 1);
    // The same document anywhere else is a duplicate.
    for (who, slug) in [(&a, "wave-2"), (&b, "wave")] {
        let (failed, problem) = h
            .publish(who, "animation", slug, animation_doc("Wave"))
            .await;
        assert!(failed);
        assert_eq!(problem["status"], 409);
        assert_eq!(problem["existing"], "dup-a/wave");
        assert!(
            problem["type"]
                .as_str()
                .unwrap()
                .ends_with("/problems/duplicate")
        );
    }
    // A changed document is revision 2.
    let (_, second) = h
        .publish(&a, "animation", "wave", animation_doc("Wave again"))
        .await;
    assert_eq!(second["revision"], 2);
    let (_, item) = h.get("/items/dup-a/wave").await;
    assert_eq!(item["revision"], 2);
    assert_eq!(item["name"], "Wave again");
    // Once it is deleted its document can be published again.
    let (_, failed, _) = h
        .tool(Some(&a.access), "delete_item", json!({ "slug": "wave" }))
        .await;
    assert!(!failed);
    assert!(
        !h.publish(&b, "animation", "wave", animation_doc("Wave again"))
            .await
            .0
    );
}

#[tokio::test]
async fn quotas() {
    let h = Harness::new().await;
    let s = h.sign_up("quota-fan", "10.0.5.1").await;
    for n in 0..20 {
        let (failed, item) = h
            .publish(
                &s,
                "animation",
                &format!("a-{n}"),
                animation_doc(&format!("A{n}")),
            )
            .await;
        assert!(!failed, "{n}: {item}");
    }
    let (failed, problem) = h
        .publish(&s, "animation", "a-20", animation_doc("A20"))
        .await;
    assert!(failed);
    assert_eq!(problem["status"], 403);
    assert!(
        problem["type"]
            .as_str()
            .unwrap()
            .ends_with("/problems/quota-exceeded")
    );
    // Updating an existing item is still fine, and deleting does not give the day's allowance back.
    assert!(
        !h.publish(&s, "animation", "a-0", animation_doc("Changed"))
            .await
            .0
    );
    let (_, _, _) = h
        .tool(Some(&s.access), "delete_item", json!({ "slug": "a-1" }))
        .await;
    assert!(
        h.publish(&s, "animation", "a-21", animation_doc("A21"))
            .await
            .0
    );
    let (_, failed, mine) = h.tool(Some(&s.access), "my_account", json!({})).await;
    assert!(!failed);
    assert_eq!(mine["handle"], "quota-fan");
    assert_eq!(mine["quota"]["items"], 19);
    assert_eq!(mine["quota"]["items_left"], 81);
    assert_eq!(mine["quota"]["new_today_left"], 0);
    assert_eq!(mine["items"].as_array().unwrap().len(), 19);
}

#[tokio::test]
async fn search_filters_sort_and_pages() {
    let h = Harness::new().await;
    let a = h.sign_up("finder-a", "10.0.6.1").await;
    let b = h.sign_up("finder-b", "10.0.6.2").await;
    for (who, kind, slug, doc, tag) in [
        (&a, "animation", "zeta", animation_doc("Zeta wave"), "dance"),
        (
            &a,
            "animation",
            "alpha",
            animation_doc("Alpha wave"),
            "calm",
        ),
        (&a, "imp", "mid", imp_doc("Middle"), "calm"),
        (&b, "tool", "tooly", tool_doc("tooly"), "calm"),
        (&b, "kit", "pack", kit_doc("Pack"), "dance"),
    ] {
        let (_, failed, item) = h
            .tool(
                Some(&who.access),
                "publish_item",
                json!({ "type": kind, "slug": slug, "summary": "Summary", "tags": [tag], "document": doc }),
            )
            .await;
        assert!(!failed, "{item}");
    }
    let names = |v: &Value| -> Vec<String> {
        v["items"]
            .as_array()
            .unwrap()
            .iter()
            .map(|i| i["slug"].as_str().unwrap().to_owned())
            .collect()
    };
    let (_, all) = h.get("/items").await;
    assert_eq!(names(&all), ["pack", "tooly", "mid", "alpha", "zeta"]);
    assert!(all["next_cursor"].is_null());
    assert_eq!(
        names(&h.get("/items?type=animation").await.1),
        ["alpha", "zeta"]
    );
    assert_eq!(
        names(&h.get("/items?handle=finder-b").await.1),
        ["pack", "tooly"]
    );
    assert_eq!(names(&h.get("/items?tag=dance").await.1), ["pack", "zeta"]);
    assert_eq!(names(&h.get("/items?q=ALPHA").await.1), ["alpha"]);
    assert_eq!(
        names(&h.get("/items?sort=name").await.1),
        ["alpha", "mid", "pack", "tooly", "zeta"]
    );

    // Pages by cursor, through REST and MCP alike.
    let (_, first) = h.get("/items?sort=name&limit=2").await;
    assert_eq!(names(&first), ["alpha", "mid"]);
    let cursor = first["next_cursor"].as_str().unwrap().to_owned();
    let (_, second) = h
        .get(&format!(
            "/items?sort=name&limit=2&cursor={}",
            encode(&cursor)
        ))
        .await;
    assert_eq!(names(&second), ["pack", "tooly"]);
    let (_, _, via_mcp) = h
        .tool(
            None,
            "search_items",
            json!({ "sort": "name", "limit": 2, "cursor": second["next_cursor"] }),
        )
        .await;
    assert_eq!(names(&via_mcp), ["zeta"]);
    assert!(via_mcp["next_cursor"].is_null());

    for bad in [
        "limit=0",
        "limit=51",
        "sort=best",
        "type=song",
        "tag=Not%20ok",
    ] {
        let (status, problem) = h.get(&format!("/items?{bad}")).await;
        assert_eq!(status, StatusCode::BAD_REQUEST, "{bad}");
        assert!(
            problem["type"]
                .as_str()
                .unwrap()
                .ends_with("/problems/invalid-request")
        );
    }
    let (_, failed, problem) = h.tool(None, "search_items", json!({ "limit": 0 })).await;
    assert!(failed);
    assert_eq!(problem["status"], 400);

    // Popular puts the installed item first.
    let (_, _, downloaded) = h
        .tool(
            None,
            "download_item",
            json!({ "handle": "finder-a", "slug": "mid" }),
        )
        .await;
    assert_eq!(downloaded["item"]["slug"], "mid");
    h.den.flush_installs().await;
    let (_, popular) = h.get("/items?sort=popular").await;
    assert_eq!(names(&popular)[0], "mid");
    assert_eq!(popular["items"][0]["installs"], 1);
}

#[tokio::test]
async fn read_api_download_and_methods() {
    let h = Harness::new().await;
    let s = h.sign_up("reader", "10.0.7.1").await;
    let doc: Value = serde_json::from_str(KIT).unwrap();
    assert!(!h.publish(&s, "kit", "moody", doc.clone()).await.0);

    let (status, item) = h.get("/items/reader/moody").await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(item["type"], "kit");
    assert_eq!(item["format"], 1);
    assert_eq!(
        item["document_url"],
        "https://den.test/items/reader/moody/document.json"
    );
    assert!(item["open_url"].as_str().unwrap().starts_with(
        "imp://add?url=https%3A%2F%2Fden.test%2Fitems%2Freader%2Fmoody%2Fdocument.json"
    ));
    assert!(item["counts"]["animations"].as_u64().unwrap() > 0);
    assert_eq!(item["sha256"].as_str().unwrap().len(), 64);

    let response = h
        .request(
            Method::GET,
            "/items/reader/moody/document.json",
            "10.0.7.1",
            None,
            String::new(),
        )
        .await;
    assert_eq!(response.status(), StatusCode::OK);
    let etag = response.headers()["etag"].to_str().unwrap().to_owned();
    assert_eq!(response.headers()["cache-control"], "public, max-age=300");
    let stored = read_text(response).await;
    assert!(!stored.contains("\n ") && stored.starts_with("{\""));
    assert_eq!(
        hex::encode(Sha256::digest(stored.as_bytes())),
        item["sha256"].as_str().unwrap()
    );
    assert_eq!(stored.len() as u64, item["size"].as_u64().unwrap());
    let cached = h
        .app
        .clone()
        .oneshot(
            Request::builder()
                .uri("/items/reader/moody/document.json")
                .header("host", "den.test")
                .header("if-none-match", &etag)
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(cached.status(), StatusCode::NOT_MODIFIED);

    // download_item returns the document and counts an install.
    let (_, failed, downloaded) = h
        .tool(
            None,
            "download_item",
            json!({ "handle": "reader", "slug": "moody" }),
        )
        .await;
    assert!(!failed);
    assert_eq!(downloaded["document"]["format"], 1);
    assert_eq!(downloaded["item"]["slug"], "moody");

    // Reports, installs, unknown things, methods.
    let response = h
        .post_json("/items/reader/moody/installs", "10.0.7.9", &json!({}))
        .await;
    assert_eq!(response.status(), StatusCode::ACCEPTED);
    let response = h
        .post_json(
            "/items/reader/moody/reports",
            "10.0.7.9",
            &json!({ "reason": "spam" }),
        )
        .await;
    assert_eq!(response.status(), StatusCode::ACCEPTED);
    assert_eq!(
        h.get("/items/reader/nothing").await.0,
        StatusCode::NOT_FOUND
    );
    for method in [Method::PUT, Method::DELETE, Method::PATCH] {
        let response = h
            .request(
                method.clone(),
                "/items/reader/moody",
                "10.0.7.1",
                Some("application/json"),
                "{}".to_owned(),
            )
            .await;
        assert_eq!(
            response.status(),
            StatusCode::METHOD_NOT_ALLOWED,
            "{method}"
        );
        assert_eq!(
            response.headers()["content-type"],
            "application/problem+json"
        );
    }
    let response = h
        .post_json(
            "/accounts",
            "10.0.7.1",
            &json!({ "handle": "x", "altcha": "y" }),
        )
        .await;
    assert!(matches!(
        response.status(),
        StatusCode::NOT_FOUND | StatusCode::METHOD_NOT_ALLOWED
    ));
    let response = h
        .request(Method::GET, "/healthz", "10.0.7.1", None, String::new())
        .await;
    assert_eq!(response.status(), StatusCode::OK);
    // The gallery is still served.
    let response = h
        .request(Method::GET, "/", "10.0.7.1", None, String::new())
        .await;
    assert_eq!(response.status(), StatusCode::OK);
    // Old bearer tokens are gone: a dak_ key is not an access token.
    let (status, failed, _) = h.tool(Some(&s.key), "my_account", json!({})).await;
    let _ = failed;
    assert_eq!(status, StatusCode::UNAUTHORIZED);
}

#[tokio::test]
async fn deleting_items_and_accounts() {
    let h = Harness::new().await;
    let a = h.sign_up("owner-a", "10.0.8.1").await;
    let b = h.sign_up("owner-b", "10.0.8.2").await;
    assert!(
        !h.publish(&a, "animation", "mine", animation_doc("Mine"))
            .await
            .0
    );
    assert!(
        !h.publish(&b, "animation", "yours", animation_doc("Yours"))
            .await
            .0
    );

    // Another account's item can't be deleted, naming it or not.
    let (_, failed, problem) = h
        .tool(
            Some(&b.access),
            "delete_item",
            json!({ "handle": "owner-a", "slug": "mine" }),
        )
        .await;
    assert!(failed);
    assert_eq!(problem["status"], 403);
    let (_, failed, problem) = h
        .tool(Some(&b.access), "delete_item", json!({ "slug": "mine" }))
        .await;
    assert!(failed);
    assert_eq!(problem["status"], 404);
    assert_eq!(h.get("/items/owner-a/mine").await.0, StatusCode::OK);
    let (_, failed, done) = h
        .tool(Some(&a.access), "delete_item", json!({ "slug": "mine" }))
        .await;
    assert!(!failed);
    assert_eq!(done["deleted"], true);
    assert_eq!(h.get("/items/owner-a/mine").await.0, StatusCode::NOT_FOUND);

    // delete_account needs the handle as confirmation.
    let (_, failed, problem) = h
        .tool(
            Some(&b.access),
            "delete_account",
            json!({ "confirm": "owner-a" }),
        )
        .await;
    assert!(failed);
    assert_eq!(problem["status"], 400);
    let (_, failed, done) = h
        .tool(
            Some(&b.access),
            "delete_account",
            json!({ "confirm": "owner-b" }),
        )
        .await;
    assert!(!failed, "{done}");
    assert_eq!(done["deleted"], true);
    assert_eq!(h.get("/accounts/owner-b").await.0, StatusCode::NOT_FOUND);
    assert_eq!(h.get("/items/owner-b/yours").await.0, StatusCode::NOT_FOUND);
    let response = h
        .mcp_raw(
            Some(&b.access),
            "tools/call",
            json!({ "name": "my_account", "arguments": {} }),
        )
        .await;
    assert_eq!(response.status(), StatusCode::UNAUTHORIZED);
    let mut gone = Session {
        client_id: b.client_id.clone(),
        handle: b.handle.clone(),
        key: b.key.clone(),
        access: String::new(),
        refresh: String::new(),
    };
    let response = h
        .authorize(
            &gone.client_id,
            "10.0.8.2",
            &[("mode", "existing"), ("key", &gone.key)],
        )
        .await;
    assert_eq!(response.status(), StatusCode::FORBIDDEN);
    gone.handle.clear();
}

#[tokio::test]
async fn deactivated_accounts_cannot_sign_in_and_hide_their_items() {
    let h = Harness::new().await;
    let s = h.sign_up("suspect", "10.0.9.1").await;
    assert!(
        !h.publish(&s, "animation", "shown", animation_doc("Shown"))
            .await
            .0
    );
    assert_eq!(h.get("/items/suspect/shown").await.0, StatusCode::OK);

    let path = h.database.to_string_lossy().into_owned();
    let run = |args: &'static [&'static str]| {
        let path = path.clone();
        async move {
            let args: Vec<String> = args.iter().map(|a| (*a).to_owned()).collect();
            imp_den::admin::run(&path, &args).await;
        }
    };
    run(&["deactivate", "suspect"]).await;

    let response = h
        .mcp_raw(
            Some(&s.access),
            "tools/call",
            json!({ "name": "my_account", "arguments": {} }),
        )
        .await;
    assert_eq!(response.status(), StatusCode::UNAUTHORIZED);
    assert_eq!(h.get("/items/suspect/shown").await.0, StatusCode::NOT_FOUND);
    let response = h
        .authorize(
            &s.client_id,
            "10.0.9.1",
            &[("mode", "existing"), ("key", &s.key)],
        )
        .await;
    assert_eq!(response.status(), StatusCode::FORBIDDEN);
    assert!(read_text(response).await.contains("deactivated"));
    let (status, body) = h
        .token(
            "10.0.9.1",
            &[
                ("grant_type", "refresh_token"),
                ("refresh_token", &s.refresh),
                ("client_id", &s.client_id),
            ],
        )
        .await;
    assert_eq!(status, StatusCode::BAD_REQUEST, "{body}");

    run(&["reactivate", "suspect"]).await;
    assert_eq!(h.get("/items/suspect/shown").await.0, StatusCode::OK);
    let mut again = Session {
        client_id: s.client_id.clone(),
        handle: s.handle.clone(),
        key: s.key.clone(),
        access: String::new(),
        refresh: String::new(),
    };
    h.sign_in(&mut again, "10.0.9.1").await;
    let (_, failed, mine) = h.tool(Some(&again.access), "my_account", json!({})).await;
    assert!(!failed);
    assert_eq!(mine["handle"], "suspect");

    run(&["hide", "suspect/shown"]).await;
    assert_eq!(h.get("/items/suspect/shown").await.0, StatusCode::NOT_FOUND);
    run(&["unhide", "suspect/shown"]).await;
    assert_eq!(h.get("/items/suspect/shown").await.0, StatusCode::OK);
    run(&["remove-account", "suspect"]).await;
    assert_eq!(h.get("/accounts/suspect").await.0, StatusCode::NOT_FOUND);
}

#[tokio::test]
async fn rate_limits_answer_429_with_retry_after() {
    let h = Harness::new().await;
    let mut last = None;
    for _ in 0..22 {
        last = Some(
            h.request(Method::GET, "/challenge", "10.0.10.1", None, String::new())
                .await,
        );
    }
    let last = last.unwrap();
    assert_eq!(last.status(), StatusCode::TOO_MANY_REQUESTS);
    assert!(last.headers().contains_key("retry-after"));
    assert_eq!(last.headers()["content-type"], "application/problem+json");
}
