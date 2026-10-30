use std::path::PathBuf;
use std::sync::Arc;

use altcha::{Payload, SolveChallengeOptions};
use axum::Router;
use axum::body::Body;
use axum::http::{Method, Request, Response, StatusCode};
use base64::Engine;
use base64::engine::general_purpose::STANDARD;
use den::Den;
use den::config::{Config, PublicUrl};
use serde_json::{Value, json};
use tower::ServiceExt;

const KIT: &str = include_str!("fixtures/moody-moves.json");

struct Harness {
    app: Router,
    den: Arc<Den>,
    database: PathBuf,
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
        let pool = den::db::open(&path).await.unwrap();
        let den = Den::new(config, pool).await;
        Self {
            app: den::router(Arc::clone(&den)),
            den,
            database,
        }
    }

    async fn send(
        &self,
        method: Method,
        uri: &str,
        ip: &str,
        token: Option<&str>,
        body: Option<Value>,
    ) -> Response<Body> {
        let mut request = Request::builder()
            .method(method)
            .uri(uri)
            .header("host", "den.test")
            .header("x-forwarded-for", ip);
        if let Some(token) = token {
            request = request.header("authorization", format!("Bearer {token}"));
        }
        let request = match body {
            Some(body) => request
                .header("content-type", "application/json")
                .body(Body::from(body.to_string())),
            None => request.body(Body::empty()),
        };
        self.app.clone().oneshot(request.unwrap()).await.unwrap()
    }

    async fn json(
        &self,
        method: Method,
        uri: &str,
        token: Option<&str>,
        body: Option<Value>,
    ) -> (StatusCode, Value) {
        let response = self.send(method, uri, "10.0.0.1", token, body).await;
        let status = response.status();
        (status, read_json(response).await)
    }

    async fn solved(&self, ip: &str) -> String {
        let response = self
            .send(Method::GET, "/v1/challenge", ip, None, None)
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

    async fn account(&self, handle: &str, ip: &str) -> String {
        let proof = self.solved(ip).await;
        let response = self
            .send(
                Method::POST,
                "/v1/accounts",
                ip,
                None,
                Some(json!({ "handle": handle, "altcha": proof })),
            )
            .await;
        assert_eq!(response.status(), StatusCode::CREATED);
        read_json(response).await["token"]
            .as_str()
            .unwrap()
            .to_owned()
    }
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

async fn read_bytes(response: Response<Body>) -> Vec<u8> {
    axum::body::to_bytes(response.into_body(), usize::MAX)
        .await
        .unwrap()
        .to_vec()
}

async fn read_json(response: Response<Body>) -> Value {
    serde_json::from_slice(&read_bytes(response).await).unwrap_or(Value::Null)
}

fn put_body() -> Value {
    json!({
        "summary": "A moody little Imp",
        "tags": ["mood", "demo"],
        "kit": serde_json::from_str::<Value>(KIT).unwrap(),
    })
}

fn assert_problem(response: &Response<Body>, status: StatusCode) {
    assert_eq!(response.status(), status);
    assert_eq!(
        response.headers()["content-type"],
        "application/problem+json"
    );
    assert!(response.headers().contains_key("x-request-id"));
}

#[tokio::test]
async fn full_lifecycle() {
    let h = Harness::new().await;
    let token = h.account("moody-fan", "10.0.0.1").await;
    assert!(token.starts_with("den_") && token.len() == 47);

    let uri = "/v1/items/moody-fan/moody-moves";
    let (status, created) = h
        .json(Method::PUT, uri, Some(&token), Some(put_body()))
        .await;
    assert_eq!(status, StatusCode::CREATED);
    assert_eq!(created["handle"], "moody-fan");
    assert_eq!(created["revision"], 1);
    assert_eq!(
        created["kit_url"],
        format!("https://den.test{uri}/kit.json")
    );
    assert!(created["sha256"].as_str().unwrap().len() == 64);
    assert!(created["created_at"].as_str().unwrap().ends_with('Z'));

    let (status, updated) = h
        .json(Method::PUT, uri, Some(&token), Some(put_body()))
        .await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(updated["revision"], 2);

    let (status, list) = h
        .json(Method::GET, "/v1/items?q=moody&sort=popular", None, None)
        .await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(list["items"].as_array().unwrap().len(), 1);
    assert!(list["next_cursor"].is_null());
    let (_, none) = h.json(Method::GET, "/v1/items?q=zzzz", None, None).await;
    assert!(none["items"].as_array().unwrap().is_empty());
    let (status, _) = h.json(Method::GET, "/v1/items?limit=51", None, None).await;
    assert_eq!(status, StatusCode::BAD_REQUEST);

    let (status, account) = h
        .json(Method::GET, "/v1/accounts/moody-fan", None, None)
        .await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(account["items"].as_array().unwrap().len(), 1);

    let kit = h
        .send(
            Method::GET,
            &format!("{uri}/kit.json"),
            "10.0.0.1",
            None,
            None,
        )
        .await;
    assert_eq!(kit.status(), StatusCode::OK);
    let etag = kit.headers()["etag"].to_str().unwrap().to_owned();
    assert_eq!(kit.headers()["cache-control"], "public, max-age=300");
    let stored: Value = serde_json::from_slice(&read_bytes(kit).await).unwrap();
    assert!(stored.get("registry").is_none());

    let request = Request::builder()
        .uri(format!("{uri}/kit.json"))
        .header("host", "den.test")
        .header("if-none-match", &etag)
        .body(Body::empty())
        .unwrap();
    let cached = h.app.clone().oneshot(request).await.unwrap();
    assert_eq!(cached.status(), StatusCode::NOT_MODIFIED);

    for _ in 0..3 {
        let response = h
            .send(
                Method::POST,
                &format!("{uri}/installs"),
                "10.0.0.2",
                None,
                None,
            )
            .await;
        assert_eq!(response.status(), StatusCode::ACCEPTED);
    }
    h.send(
        Method::POST,
        &format!("{uri}/installs"),
        "10.0.0.3",
        None,
        None,
    )
    .await;
    h.den.flush_installs().await;
    let (_, item) = h.json(Method::GET, uri, None, None).await;
    assert_eq!(item["installs"], 2);

    let response = h
        .send(
            Method::POST,
            &format!("{uri}/reports"),
            "10.0.0.2",
            None,
            Some(json!({ "reason": "spam" })),
        )
        .await;
    assert_eq!(response.status(), StatusCode::ACCEPTED);

    let (_, stats) = h.json(Method::GET, "/v1/stats", None, None).await;
    assert_eq!(stats["accounts"], 1);
    assert_eq!(stats["items"], 1);
    assert_eq!(stats["by_kind"]["kit"], 1);
    assert_eq!(stats["by_kind"]["animation"], 0);

    let hidden = den::admin::run(
        &h.database.to_string_lossy(),
        &["hide".to_owned(), "moody-fan/moody-moves".to_owned()],
    )
    .await;
    assert_eq!(hidden, std::process::ExitCode::SUCCESS);
    let response = h.send(Method::GET, uri, "10.0.0.1", None, None).await;
    assert_problem(&response, StatusCode::NOT_FOUND);

    den::admin::run(
        &h.database.to_string_lossy(),
        &["unhide".to_owned(), "moody-fan/moody-moves".to_owned()],
    )
    .await;
    let (status, _) = h.json(Method::GET, uri, None, None).await;
    assert_eq!(status, StatusCode::OK);

    let (status, _) = h.json(Method::DELETE, uri, Some(&token), None).await;
    assert_eq!(status, StatusCode::NO_CONTENT);
    let (status, _) = h.json(Method::GET, uri, None, None).await;
    assert_eq!(status, StatusCode::NOT_FOUND);
    let (status, _) = h
        .json(Method::DELETE, "/v1/accounts/me", Some(&token), None)
        .await;
    assert_eq!(status, StatusCode::NO_CONTENT);
}

#[tokio::test]
async fn authorization_and_validation() {
    let h = Harness::new().await;
    let uri = "/v1/items/moody-fan/moody-moves";
    let token = h.account("moody-fan", "10.0.0.1").await;
    let other = h.account("someone-else", "10.0.0.9").await;

    let response = h
        .send(Method::PUT, uri, "10.0.0.1", None, Some(put_body()))
        .await;
    assert_problem(&response, StatusCode::UNAUTHORIZED);
    assert_eq!(response.headers()["www-authenticate"], "Bearer");
    let response = h
        .send(
            Method::PUT,
            uri,
            "10.0.0.1",
            Some("den_nope"),
            Some(put_body()),
        )
        .await;
    assert_eq!(response.status(), StatusCode::UNAUTHORIZED);
    let response = h
        .send(Method::PUT, uri, "10.0.0.1", Some(&other), Some(put_body()))
        .await;
    assert_problem(&response, StatusCode::FORBIDDEN);

    let mut body = put_body();
    body["summary"] = json!("x".repeat(121));
    body["tags"] = json!(["Bad Tag"]);
    let response = h
        .send(Method::PUT, uri, "10.0.0.1", Some(&token), Some(body))
        .await;
    assert_problem(&response, StatusCode::UNPROCESSABLE_ENTITY);
    let problem = read_json(response).await;
    assert_eq!(
        problem["type"],
        "https://den.test/v1/problems/validation-failed"
    );
    let pointers: Vec<&str> = problem["errors"]
        .as_array()
        .unwrap()
        .iter()
        .map(|e| e["pointer"].as_str().unwrap())
        .collect();
    assert!(pointers.contains(&"/summary"), "{pointers:?}");
    assert!(
        pointers.iter().any(|p| p.starts_with("/tags")),
        "{pointers:?}"
    );

    let mut body = put_body();
    body["kit"]["imps"][0]["chats"] = json!([{ "title": "private" }]);
    let response = h
        .send(Method::PUT, uri, "10.0.0.1", Some(&token), Some(body))
        .await;
    assert_eq!(response.status(), StatusCode::UNPROCESSABLE_ENTITY);

    let mut body = put_body();
    body["kit"]["mcpServers"] =
        json!([{ "name": "x", "command": "echo", "env": { "KEY": "secret" } }]);
    let response = h
        .send(Method::PUT, uri, "10.0.0.1", Some(&token), Some(body))
        .await;
    assert_eq!(response.status(), StatusCode::UNPROCESSABLE_ENTITY);
}

#[tokio::test]
async fn errors_are_problem_json() {
    let h = Harness::new().await;
    let response = h
        .send(Method::GET, "/v1/nothing", "10.0.0.1", None, None)
        .await;
    assert_problem(&response, StatusCode::NOT_FOUND);
    let response = h
        .send(Method::POST, "/v1/stats", "10.0.0.1", None, None)
        .await;
    assert_problem(&response, StatusCode::METHOD_NOT_ALLOWED);
    let request = Request::builder()
        .method(Method::POST)
        .uri("/v1/accounts")
        .header("content-type", "text/plain")
        .body(Body::from("hi"))
        .unwrap();
    let response = h.app.clone().oneshot(request).await.unwrap();
    assert_problem(&response, StatusCode::UNSUPPORTED_MEDIA_TYPE);
    let request = Request::builder()
        .method(Method::POST)
        .uri("/v1/accounts")
        .header("content-type", "application/json")
        .body(Body::from("{not json"))
        .unwrap();
    let response = h.app.clone().oneshot(request).await.unwrap();
    assert_eq!(
        response.headers()["content-type"],
        "application/problem+json"
    );
    assert!(response.status().is_client_error());
    let request = Request::builder()
        .method(Method::POST)
        .uri("/v1/accounts")
        .header("content-type", "application/json")
        .body(Body::from(vec![b' '; 700 * 1024]))
        .unwrap();
    let response = h.app.clone().oneshot(request).await.unwrap();
    assert_problem(&response, StatusCode::PAYLOAD_TOO_LARGE);
    let problem = read_json(response).await;
    assert_eq!(problem["status"], 413);
    assert_eq!(
        problem["type"],
        "https://den.test/v1/problems/payload-too-large"
    );
}

#[tokio::test]
async fn replayed_challenge_is_refused() {
    let h = Harness::new().await;
    let proof = h.solved("10.0.0.1").await;
    let create = |handle: &'static str| {
        let proof = proof.clone();
        let h = &h;
        async move {
            h.send(
                Method::POST,
                "/v1/accounts",
                "10.0.0.1",
                None,
                Some(json!({ "handle": handle, "altcha": proof })),
            )
            .await
        }
    };
    assert_eq!(create("first-one").await.status(), StatusCode::CREATED);
    let response = create("second-one").await;
    assert_problem(&response, StatusCode::UNPROCESSABLE_ENTITY);
    assert_eq!(
        read_json(response).await["type"],
        "https://den.test/v1/problems/challenge-failed"
    );
    let proof = h.solved("10.0.0.5").await;
    let response = h
        .send(
            Method::POST,
            "/v1/accounts",
            "10.0.0.5",
            None,
            Some(json!({ "handle": "first-one", "altcha": proof })),
        )
        .await;
    assert_problem(&response, StatusCode::CONFLICT);
}

#[tokio::test]
async fn rate_limit_answers_429_with_retry_after() {
    let h = Harness::new().await;
    let mut last = StatusCode::OK;
    for _ in 0..21 {
        let response = h
            .send(Method::GET, "/v1/challenge", "10.0.0.7", None, None)
            .await;
        last = response.status();
        if last == StatusCode::TOO_MANY_REQUESTS {
            assert_problem(&response, last);
            let seconds: u64 = response.headers()["retry-after"]
                .to_str()
                .unwrap()
                .parse()
                .unwrap();
            assert!(seconds >= 1);
            return;
        }
    }
    panic!("never limited, last status {last}");
}

#[tokio::test]
async fn web_ui_and_headers() {
    let h = Harness::new().await;
    for path in ["/", "/i/someone/thing", "/a/someone"] {
        let response = h.send(Method::GET, path, "10.0.0.1", None, None).await;
        assert_eq!(response.status(), StatusCode::OK, "{path}");
        let headers = response.headers();
        assert_eq!(headers["cache-control"], "no-cache");
        assert_eq!(
            headers["content-security-policy"],
            "default-src 'none'; script-src 'self'; style-src 'self'; img-src 'self' data:; connect-src 'self'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'"
        );
        assert_eq!(headers["x-content-type-options"], "nosniff");
        assert_eq!(headers["referrer-policy"], "no-referrer");
        assert_eq!(headers["x-frame-options"], "DENY");
        assert!(
            headers["content-type"]
                .to_str()
                .unwrap()
                .starts_with("text/html")
        );
        assert!(headers.contains_key("x-request-id"));
    }
    for file in ["app.js", "imp.js", "site.css", "favicon.svg"] {
        let response = h
            .send(
                Method::GET,
                &format!("/assets/{file}"),
                "10.0.0.1",
                None,
                None,
            )
            .await;
        assert_eq!(response.status(), StatusCode::OK, "{file}");
    }
    let response = h
        .send(Method::GET, "/assets/nope.js", "10.0.0.1", None, None)
        .await;
    assert_problem(&response, StatusCode::NOT_FOUND);
    let response = h
        .send(Method::GET, "/healthz", "10.0.0.1", None, None)
        .await;
    assert_eq!(response.status(), StatusCode::OK);
    let response = h
        .send(Method::GET, "/v1/stats", "10.0.0.1", None, None)
        .await;
    assert_eq!(response.headers()["access-control-allow-origin"], "*");
    assert_eq!(response.headers()["cache-control"], "public, max-age=30");
}

async fn mcp(h: &Harness, token: Option<&str>, method: &str, params: Value) -> (StatusCode, Value) {
    let mut params = params;
    params["_meta"] = json!({
        "io.modelcontextprotocol/protocolVersion": "2026-07-28",
        "io.modelcontextprotocol/clientCapabilities": {},
    });
    let body = json!({ "jsonrpc": "2.0", "id": 1, "method": method, "params": params });
    let mut request = Request::builder()
        .method(Method::POST)
        .uri("/v1/mcp")
        .header("host", "den.test")
        .header("origin", "https://den.test")
        .header("content-type", "application/json")
        .header("accept", "application/json, text/event-stream")
        .header("mcp-protocol-version", "2026-07-28")
        .header("mcp-method", method);
    if let Some(name) = params.get("name").and_then(Value::as_str) {
        request = request.header("mcp-name", name);
    }
    if let Some(token) = token {
        request = request.header("authorization", format!("Bearer {token}"));
    }
    let response = h
        .app
        .clone()
        .oneshot(request.body(Body::from(body.to_string())).unwrap())
        .await
        .unwrap();
    let status = response.status();
    (status, read_json(response).await)
}

#[tokio::test]
async fn mcp_lists_and_calls_tools() {
    let h = Harness::new().await;
    let (status, listed) = mcp(&h, None, "tools/list", json!({})).await;
    assert_eq!(status, StatusCode::OK, "{listed}");
    let names: Vec<&str> = listed["result"]["tools"]
        .as_array()
        .unwrap()
        .iter()
        .map(|t| t["name"].as_str().unwrap())
        .collect();
    for tool in [
        "search_items",
        "get_item",
        "get_kit",
        "get_challenge",
        "create_account",
        "publish_item",
        "delete_item",
    ] {
        assert!(names.contains(&tool), "{tool} missing in {names:?}");
    }

    let (status, called) = mcp(
        &h,
        None,
        "tools/call",
        json!({ "name": "search_items", "arguments": { "q": "moody" } }),
    )
    .await;
    assert_eq!(status, StatusCode::OK, "{called}");
    assert!(called["result"]["structuredContent"]["items"].is_array());

    let (_, denied) = mcp(
        &h,
        None,
        "tools/call",
        json!({ "name": "delete_item", "arguments": { "handle": "a-b-c", "slug": "x" } }),
    )
    .await;
    assert_eq!(denied["result"]["isError"], true);

    let token = h.account("mcp-fan", "10.0.0.1").await;
    let mut arguments = put_body();
    arguments["handle"] = json!("mcp-fan");
    arguments["slug"] = json!("moody-moves");
    let (_, published) = mcp(
        &h,
        Some(&token),
        "tools/call",
        json!({ "name": "publish_item", "arguments": arguments }),
    )
    .await;
    assert_ne!(published["result"]["isError"], true, "{published}");
    assert_eq!(published["result"]["structuredContent"]["revision"], 1);

    let response = h
        .app
        .clone()
        .oneshot(
            Request::builder()
                .method(Method::POST)
                .uri("/v1/mcp")
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
