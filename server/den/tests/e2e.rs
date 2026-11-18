//! End-to-end test of a running Den over real HTTP, for example the Docker image.
//!
//! Ignored by default. Start a Den, then run:
//!
//! ```text
//! DEN_E2E_URL=http://localhost:8099 cargo test -p imp-den --test e2e -- --ignored --nocapture
//! ```
//!
//! `full_flow` signs up a new account, exercises OAuth, MCP and the read API, and writes the handle and
//! a fresh access token to `DEN_E2E_STATE` (default `.agent-logs/e2e-session.json` in the workspace).
//! After `den admin deactivate <handle>` on the server, `deactivated_account_is_refused` checks that the
//! token now gets 401 on an MCP write. Run them one after the other, not together.

use std::io::{Read, Write};
use std::net::TcpStream;
use std::time::{Duration, Instant};

use altcha::{Payload, SolveChallengeOptions};
use base64::Engine;
use base64::engine::general_purpose::{STANDARD, URL_SAFE_NO_PAD};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};

const REDIRECT: &str = "http://127.0.0.1:8765/oauth";

struct Resp {
    status: u16,
    headers: Vec<(String, String)>,
    body: Vec<u8>,
}

impl Resp {
    fn header(&self, name: &str) -> Option<&str> {
        self.headers
            .iter()
            .find(|(k, _)| k == name)
            .map(|(_, v)| v.as_str())
    }
    fn text(&self) -> String {
        String::from_utf8_lossy(&self.body).into_owned()
    }
    fn json(&self) -> Value {
        serde_json::from_slice(&self.body)
            .unwrap_or_else(|e| panic!("not JSON ({e}): {}", self.text()))
    }
}

struct Den {
    base: String,
    authority: String,
}

fn den() -> Den {
    let base = std::env::var("DEN_E2E_URL")
        .expect("set DEN_E2E_URL, for example http://localhost:8099")
        .trim_end_matches('/')
        .to_owned();
    let authority = base
        .strip_prefix("http://")
        .expect("DEN_E2E_URL must be http://host:port")
        .to_owned();
    Den { base, authority }
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

fn dechunk(mut raw: &[u8]) -> Vec<u8> {
    let mut out = Vec::new();
    loop {
        let Some(at) = raw.windows(2).position(|w| w == b"\r\n") else {
            return out;
        };
        let size = usize::from_str_radix(
            std::str::from_utf8(&raw[..at])
                .unwrap()
                .split(';')
                .next()
                .unwrap()
                .trim(),
            16,
        )
        .unwrap();
        raw = &raw[at + 2..];
        if size == 0 {
            return out;
        }
        out.extend_from_slice(&raw[..size]);
        raw = &raw[size + 2..];
    }
}

impl Den {
    /// One HTTP/1.1 request on its own connection, so no client library is needed.
    fn send(&self, method: &str, path: &str, headers: &[(&str, &str)], body: &str) -> Resp {
        let mut stream = TcpStream::connect(&self.authority).expect("the Den is not reachable");
        stream
            .set_read_timeout(Some(Duration::from_secs(30)))
            .unwrap();
        let mut head = format!(
            "{method} {path} HTTP/1.1\r\nHost: {}\r\nConnection: close\r\nContent-Length: {}\r\n",
            self.authority,
            body.len()
        );
        for (k, v) in headers {
            head.push_str(&format!("{k}: {v}\r\n"));
        }
        head.push_str("\r\n");
        stream.write_all(head.as_bytes()).unwrap();
        stream.write_all(body.as_bytes()).unwrap();
        let mut raw = Vec::new();
        stream.read_to_end(&mut raw).unwrap();
        let split = raw
            .windows(4)
            .position(|w| w == b"\r\n\r\n")
            .expect("no headers");
        let head = String::from_utf8_lossy(&raw[..split]).into_owned();
        let mut lines = head.split("\r\n");
        let status = lines
            .next()
            .unwrap()
            .split(' ')
            .nth(1)
            .unwrap()
            .parse()
            .unwrap();
        let headers: Vec<(String, String)> = lines
            .filter_map(|l| l.split_once(':'))
            .map(|(k, v)| (k.trim().to_ascii_lowercase(), v.trim().to_owned()))
            .collect();
        let rest = &raw[split + 4..];
        let chunked = headers
            .iter()
            .any(|(k, v)| k == "transfer-encoding" && v.contains("chunked"));
        let body = if chunked {
            dechunk(rest)
        } else {
            rest.to_vec()
        };
        Resp {
            status,
            headers,
            body,
        }
    }

    fn get(&self, path: &str) -> Resp {
        self.send("GET", path, &[], "")
    }

    fn post_form(&self, path: &str, pairs: &[(&str, &str)]) -> Resp {
        self.send(
            "POST",
            path,
            &[("Content-Type", "application/x-www-form-urlencoded")],
            &form(pairs),
        )
    }

    fn mcp(&self, token: Option<&str>, method: &str, params: Value) -> Resp {
        let body = json!({ "jsonrpc": "2.0", "id": 1, "method": method, "params": params });
        let bearer = token.map(|t| format!("Bearer {t}"));
        let origin = self.base.clone();
        let mut headers = vec![
            ("Content-Type", "application/json"),
            ("Accept", "application/json, text/event-stream"),
            ("MCP-Protocol-Version", "2025-11-25"),
            ("Origin", origin.as_str()),
        ];
        if let Some(b) = &bearer {
            headers.push(("Authorization", b.as_str()));
        }
        self.send("POST", "/mcp", &headers, &body.to_string())
    }

    /// Calls one tool. Returns the HTTP status, whether the tool failed, and its structured answer.
    fn tool(&self, token: Option<&str>, name: &str, arguments: Value) -> (u16, bool, Value) {
        let r = self.mcp(
            token,
            "tools/call",
            json!({ "name": name, "arguments": arguments }),
        );
        if r.status != 200 {
            return (r.status, true, Value::Null);
        }
        let body = r.json();
        let result = &body["result"];
        (
            200,
            result["isError"] == true,
            result["structuredContent"].clone(),
        )
    }

    fn publish(
        &self,
        token: &str,
        kind: &str,
        slug: &str,
        tag: &str,
        document: Value,
    ) -> (bool, Value) {
        let (status, failed, answer) = self.tool(
            Some(token),
            "publish_item",
            json!({ "type": kind, "slug": slug, "summary": format!("An e2e {kind}"), "tags": [tag, "e2e"], "document": document }),
        );
        assert_eq!(status, 200, "publish {slug}");
        (failed, answer)
    }

    fn solved(&self) -> String {
        let r = self.get("/challenge");
        assert_eq!(r.status, 200, "{}", r.text());
        let challenge: altcha::Challenge = serde_json::from_value(r.json()).unwrap();
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

    fn register(&self, name: &str) -> String {
        let r = self.send(
            "POST",
            "/oauth/register",
            &[("Content-Type", "application/json")],
            &json!({ "client_name": name, "redirect_uris": [REDIRECT] }).to_string(),
        );
        assert_eq!(r.status, 201, "{}", r.text());
        r.json()["client_id"].as_str().unwrap().to_owned()
    }

    /// Posts the sign-in form. `extra` carries the mode and its fields.
    fn authorize(&self, client_id: &str, verifier: &str, extra: &[(&str, &str)]) -> Resp {
        let challenge = URL_SAFE_NO_PAD.encode(Sha256::digest(verifier.as_bytes()));
        let resource = format!("{}/mcp", self.base);
        let mut pairs = vec![
            ("response_type", "code"),
            ("client_id", client_id),
            ("redirect_uri", REDIRECT),
            ("code_challenge", challenge.as_str()),
            ("code_challenge_method", "S256"),
            ("state", "e2e state"),
            ("scope", "publish"),
            ("resource", resource.as_str()),
        ];
        pairs.extend_from_slice(extra);
        self.post_form("/oauth/authorize", &pairs)
    }

    /// Signs in with an account key and exchanges the code. Returns (access, refresh).
    fn sign_in(&self, client_id: &str, key: &str) -> (String, String) {
        let verifier = format!(
            "verifier-{}-0123456789-abcdefghijklmnop",
            hex::encode(rand::random::<[u8; 8]>())
        );
        let r = self.authorize(client_id, &verifier, &[("mode", "existing"), ("key", key)]);
        assert_eq!(r.status, 303, "{}", r.text());
        let location = r.header("location").unwrap().to_owned();
        assert!(
            location.starts_with("http://127.0.0.1:8765/oauth?code="),
            "{location}"
        );
        assert!(location.ends_with("&state=e2e%20state"), "{location}");
        let code = location
            .split("code=")
            .nth(1)
            .unwrap()
            .split('&')
            .next()
            .unwrap();
        let r = self.post_form(
            "/oauth/token",
            &[
                ("grant_type", "authorization_code"),
                ("code", code),
                ("client_id", client_id),
                ("redirect_uri", REDIRECT),
                ("code_verifier", &verifier),
            ],
        );
        assert_eq!(r.status, 200, "{}", r.text());
        let t = r.json();
        assert_eq!(t["token_type"], "Bearer");
        // A code works once.
        let again = self.post_form(
            "/oauth/token",
            &[
                ("grant_type", "authorization_code"),
                ("code", code),
                ("client_id", client_id),
                ("redirect_uri", REDIRECT),
                ("code_verifier", &verifier),
            ],
        );
        assert_eq!(again.status, 400);
        assert_eq!(again.json()["error"], "invalid_grant");
        (
            t["access_token"].as_str().unwrap().to_owned(),
            t["refresh_token"].as_str().unwrap().to_owned(),
        )
    }
}

fn state_path() -> std::path::PathBuf {
    std::env::var("DEN_E2E_STATE")
        .map(Into::into)
        .unwrap_or_else(|_| {
            std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
                .join("../../.agent-logs/e2e-session.json")
        })
}

fn names(v: &Value) -> Vec<String> {
    v["items"]
        .as_array()
        .unwrap()
        .iter()
        .map(|i| i["slug"].as_str().unwrap().to_owned())
        .collect()
}

#[test]
#[ignore = "needs a running Den: set DEN_E2E_URL"]
fn full_flow() {
    let d = den();
    let origin = &d.base;

    // Version, health and discovery.
    let r = d.get("/healthz");
    assert_eq!(r.status, 200);
    let v = d.get("/version").json();
    assert_eq!(v["api"], 1);
    let r = d.get("/.well-known/oauth-protected-resource/mcp");
    assert_eq!(r.status, 200);
    let prm = r.json();
    assert_eq!(prm["resource"], format!("{origin}/mcp"));
    assert_eq!(prm["authorization_servers"][0], *origin);
    let r = d.get("/.well-known/oauth-authorization-server");
    assert_eq!(r.status, 200);
    let meta = r.json();
    assert_eq!(meta["issuer"], *origin);
    assert_eq!(
        meta["authorization_endpoint"],
        format!("{origin}/oauth/authorize")
    );
    assert_eq!(meta["token_endpoint"], format!("{origin}/oauth/token"));
    assert_eq!(
        meta["registration_endpoint"],
        format!("{origin}/oauth/register")
    );
    assert_eq!(meta["code_challenge_methods_supported"][0], "S256");

    // Unauthenticated writes are told how to sign in.
    let r = d.mcp(
        None,
        "tools/call",
        json!({ "name": "publish_item", "arguments": {} }),
    );
    assert_eq!(r.status, 401);
    assert!(
        r.header("www-authenticate")
            .unwrap()
            .contains("resource_metadata=")
    );

    // Registration with a loopback redirect, then the sign-in page.
    let client_id = d.register("E2E host");
    let bad = d.send(
        "POST",
        "/oauth/register",
        &[("Content-Type", "application/json")],
        &json!({ "client_name": "x", "redirect_uris": ["http://evil.example/cb"] }).to_string(),
    );
    assert_eq!(bad.status, 400, "{}", bad.text());
    let challenge = URL_SAFE_NO_PAD.encode(Sha256::digest(b"page"));
    let page = d.get(&format!(
        "/oauth/authorize?response_type=code&client_id={client_id}&redirect_uri={}&code_challenge={challenge}&code_challenge_method=S256&state=s",
        encode(REDIRECT)
    ));
    assert_eq!(page.status, 200);
    assert!(page.text().contains("E2E host"));
    assert!(
        page.header("content-security-policy")
            .unwrap()
            .contains("script-src")
    );

    // A new account: solve ALTCHA, post the form, get the key page, continue to the code.
    let handle = format!("e2e-{}", hex::encode(rand::random::<[u8; 4]>()));
    let proof = d.solved();
    let verifier = "a-verifier-of-more-than-forty-three-characters-0123456789";
    let r = d.authorize(
        &client_id,
        verifier,
        &[("mode", "new"), ("handle", &handle), ("altcha", &proof)],
    );
    assert_eq!(r.status, 200, "{}", r.text());
    let page = r.text();
    let at = page.find("dak_").expect("the key is shown");
    let key = page[at..at + 47].to_owned();
    // The same solved challenge is not accepted twice.
    let replay = d.authorize(
        &client_id,
        verifier,
        &[
            ("mode", "new"),
            ("handle", "e2e-replay"),
            ("altcha", &proof),
        ],
    );
    assert_eq!(replay.status, 422);
    let (mut access, refresh) = d.sign_in(&client_id, &key);
    assert!(access.starts_with("dat_") && refresh.starts_with("drt_"));

    // MCP handshake.
    let r = d.mcp(
        None,
        "initialize",
        json!({ "protocolVersion": "2025-11-25", "capabilities": {}, "clientInfo": { "name": "e2e", "version": "1" } }),
    );
    assert_eq!(r.status, 200, "{}", r.text());
    let init = r.json();
    assert_eq!(init["result"]["protocolVersion"], "2025-11-25");
    assert!(init["result"]["serverInfo"]["version"].is_string());
    let tools = d.mcp(None, "tools/list", json!({})).json();
    let listed: Vec<&str> = tools["result"]["tools"]
        .as_array()
        .unwrap()
        .iter()
        .map(|t| t["name"].as_str().unwrap())
        .collect();
    for name in [
        "search_items",
        "get_item",
        "download_item",
        "publish_item",
        "delete_item",
    ] {
        assert!(listed.contains(&name), "missing tool {name}");
    }

    // Publish one item of each type.
    let docs = [
        (
            "imp",
            "zed-imp",
            json!({ "format": 1, "name": format!("Zed imp {handle}"), "imps": [{ "name": "Zed" }] }),
        ),
        (
            "animation",
            "wave-anim",
            json!({ "format": 1, "name": format!("Wave {handle}"), "animations": [{ "name": "Wave", "beats": [{ "duration": 0.5, "mood": "happy" }] }] }),
        ),
        (
            "trigger",
            "wake-trigger",
            json!({ "format": 1, "name": format!("Wake {handle}"), "triggers": [{ "name": "Wake", "on": "wake", "do": [{ "act": "say", "value": "Hi" }] }] }),
        ),
        (
            "tool",
            "echo-tool",
            json!({ "format": 1, "name": format!("Echo {handle}"), "mcpServers": { "echo": { "url": "https://echo.example/mcp" } } }),
        ),
        (
            "kit",
            "pack-kit",
            json!({ "format": 1, "name": format!("Pack {handle}"), "imps": [{ "name": "Pack imp" }], "skills": [{ "name": "pdf", "source": "anthropics/skills/skills/pdf" }] }),
        ),
    ];
    for (kind, slug, doc) in &docs {
        let (failed, item) = d.publish(&access, kind, slug, "demo", doc.clone());
        assert!(!failed, "{kind}: {item}");
        assert_eq!(item["type"], *kind);
        assert_eq!(item["revision"], 1);
    }
    // A mismatched document is refused.
    let (failed, problem) = d.publish(&access, "animation", "bad-type", "demo", docs[0].2.clone());
    assert!(failed);
    assert_eq!(problem["status"], 422, "{problem}");

    // The same document under another slug is a duplicate.
    let (failed, problem) = d.publish(&access, "animation", "wave-copy", "demo", docs[1].2.clone());
    assert!(failed);
    assert_eq!(problem["status"], 409, "{problem}");
    assert_eq!(problem["existing"], format!("{handle}/wave-anim"));

    // Search: type, keyword, sort and pagination, over MCP and the REST API.
    let all = d.get(&format!("/items?handle={handle}")).json();
    assert_eq!(names(&all).len(), 5);
    let anims = d
        .get(&format!("/items?handle={handle}&type=animation"))
        .json();
    assert_eq!(names(&anims), ["wave-anim"]);
    let q = d.get(&format!("/items?handle={handle}&q=ECHO")).json();
    assert_eq!(names(&q), ["echo-tool"]);
    let by_name = d.get(&format!("/items?handle={handle}&sort=name")).json();
    let expected = [
        "echo-tool",
        "pack-kit",
        "wake-trigger",
        "wave-anim",
        "zed-imp",
    ];
    assert_eq!(names(&by_name), expected);
    let mut seen = Vec::new();
    let mut cursor: Option<String> = None;
    loop {
        let mut path = format!("/items?handle={handle}&sort=name&limit=2");
        if let Some(c) = &cursor {
            path.push_str(&format!("&cursor={}", encode(c)));
        }
        let page = d.get(&path).json();
        assert!(page["items"].as_array().unwrap().len() <= 2);
        seen.extend(names(&page));
        match page["next_cursor"].as_str() {
            Some(c) => cursor = Some(c.to_owned()),
            None => break,
        }
    }
    assert_eq!(
        seen,
        expected.to_vec(),
        "pagination covers the sorted list once"
    );
    let (status, failed, found) = d.tool(
        None,
        "search_items",
        json!({ "type": "kit", "q": "pack", "handle": handle, "sort": "popular", "limit": 5 }),
    );
    assert!(status == 200 && !failed, "{found}");
    assert_eq!(names(&found), ["pack-kit"]);

    // get_item and download_item; the document round-trips.
    let (_, failed, got) = d.tool(
        None,
        "get_item",
        json!({ "handle": handle, "slug": "pack-kit" }),
    );
    assert!(!failed);
    assert_eq!(got["counts"]["skills"], 1);
    let (_, failed, downloaded) = d.tool(
        None,
        "download_item",
        json!({ "handle": handle, "slug": "pack-kit" }),
    );
    assert!(!failed);
    assert_eq!(downloaded["document"], docs[4].2);
    let item = d.get(&format!("/items/{handle}/pack-kit")).json();
    // Install counts are batched by the Den, so only their shape is checked here.
    assert!(item["installs"].is_u64());
    assert!(
        item["open_url"]
            .as_str()
            .unwrap()
            .starts_with("imp://add?url=")
    );
    assert_eq!(
        item["document_url"],
        format!("{origin}/items/{handle}/pack-kit/document.json")
    );

    // document.json with its ETag.
    let path = format!("/items/{handle}/pack-kit/document.json");
    let r = d.get(&path);
    assert_eq!(r.status, 200);
    let etag = r.header("etag").expect("an ETag").to_owned();
    assert_eq!(
        hex::encode(Sha256::digest(&r.body)),
        item["sha256"].as_str().unwrap()
    );
    let cached = d.send("GET", &path, &[("If-None-Match", &etag)], "");
    assert_eq!(cached.status, 304);

    // Accounts and stats.
    let account = d.get(&format!("/accounts/{handle}")).json();
    assert_eq!(account["items"].as_array().unwrap().len(), 5);
    assert!(d.get("/stats").json()["items"].as_u64().unwrap() >= 5);
    let (_, failed, mine) = d.tool(Some(&access), "my_account", json!({}));
    assert!(!failed);
    assert_eq!(mine["handle"], handle);

    // Delete one item.
    let (status, failed, gone) =
        d.tool(Some(&access), "delete_item", json!({ "slug": "echo-tool" }));
    assert!(status == 200 && !failed, "{gone}");
    assert_eq!(gone["deleted"], true);
    assert_eq!(d.get(&format!("/items/{handle}/echo-tool")).status, 404);

    // The gallery and an asset. The page may use only its own scripts and styles.
    let home = d.get("/");
    assert_eq!(home.status, 200);
    assert!(home.text().contains("/assets/app.js"));
    let csp = home.header("content-security-policy").unwrap();
    assert!(csp.contains("script-src 'self'") && csp.contains("connect-src 'self'"));
    for (path, kind, needle) in [
        ("/assets/app.js", "javascript", "document.json"),
        ("/assets/imp.js", "javascript", "drawImp"),
        ("/assets/site.css", "css", "--"),
    ] {
        let r = d.get(path);
        assert_eq!(r.status, 200, "{path}");
        assert!(r.header("content-type").unwrap().contains(kind), "{path}");
        assert!(r.text().contains(needle), "{path}");
    }
    assert_eq!(d.get(&format!("/i/{handle}/pack-kit")).status, 200);
    assert_eq!(d.get(&format!("/a/{handle}")).status, 200);

    // Refresh tokens rotate; reusing an old one revokes the grant.
    let refreshed = d.post_form(
        "/oauth/token",
        &[
            ("grant_type", "refresh_token"),
            ("refresh_token", &refresh),
            ("client_id", &client_id),
        ],
    );
    assert_eq!(refreshed.status, 200, "{}", refreshed.text());
    let t = refreshed.json();
    let (new_access, new_refresh) = (
        t["access_token"].as_str().unwrap().to_owned(),
        t["refresh_token"].as_str().unwrap().to_owned(),
    );
    assert_ne!(new_refresh, refresh);
    assert_eq!(d.tool(Some(&new_access), "my_account", json!({})).0, 200);
    let reuse = d.post_form(
        "/oauth/token",
        &[
            ("grant_type", "refresh_token"),
            ("refresh_token", &refresh),
            ("client_id", &client_id),
        ],
    );
    assert_eq!(reuse.status, 400);
    assert_eq!(reuse.json()["error"], "invalid_grant");
    let after = d.post_form(
        "/oauth/token",
        &[
            ("grant_type", "refresh_token"),
            ("refresh_token", &new_refresh),
            ("client_id", &client_id),
        ],
    );
    assert_eq!(after.status, 400, "the whole grant is revoked");
    assert_eq!(d.tool(Some(&new_access), "my_account", json!({})).0, 401);

    // Sign in again with the account key for the deactivation phase.
    let (fresh, _) = d.sign_in(&client_id, &key);
    access = fresh;
    assert_eq!(d.tool(Some(&access), "my_account", json!({})).0, 200);
    let path = state_path();
    std::fs::write(
        &path,
        json!({ "handle": handle, "access": access }).to_string(),
    )
    .unwrap();
    println!("e2e account {handle}; state written to {}", path.display());
}

#[test]
#[ignore = "needs a running Den and a deactivated account: run after full_flow and `den admin deactivate`"]
fn deactivated_account_is_refused() {
    let d = den();
    let state: Value =
        serde_json::from_str(&std::fs::read_to_string(state_path()).unwrap()).unwrap();
    let handle = state["handle"].as_str().unwrap();
    let access = state["access"].as_str().unwrap();
    // Caches turn over within 30 seconds.
    let start = Instant::now();
    let write = json!({ "slug": "pack-kit" });
    loop {
        let (status, _, _) = d.tool(Some(access), "delete_item", write.clone());
        if status == 401 {
            break;
        }
        assert!(
            start.elapsed() < Duration::from_secs(60),
            "token still works after deactivation (status {status})"
        );
        std::thread::sleep(Duration::from_secs(2));
    }
    println!("token refused after {:?}", start.elapsed());
    // The items are hidden.
    assert_eq!(d.get(&format!("/items/{handle}/pack-kit")).status, 404);
    // Reads still work for everyone.
    assert_eq!(d.get("/healthz").status, 200);
}
