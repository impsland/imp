//! MCP authorization against a real Den (the reference server), through the core's client.
//!
//! Ignored by default. Start a Den, then run:
//!
//! ```text
//! DEN_E2E_URL=http://localhost:8099 cargo test -p imp-engine --test mcp_oauth -- --ignored --nocapture
//! ```
//!
//! The browser is played by this test: it posts the sign-in form of a new account, solving ALTCHA in
//! code, and catches the redirect.

use altcha::{Payload, SolveChallengeOptions};
use base64::Engine;
use base64::engine::general_purpose::STANDARD;
use imp_engine::mcp::auth::{self, McpAuth};
use imp_engine::mcp::auth_flow;
use imp_engine::{BoxFuture, McpClient, McpError, McpSecrets, McpSignIn};
use serde_json::json;
use std::cell::RefCell;
use std::rc::Rc;
use std::time::Duration;

const REDIRECT: &str = "http://127.0.0.1:8765/oauth";

struct Browserless {
    base: String,
    stored: RefCell<Option<McpAuth>>,
    signed_in: RefCell<u32>,
}

impl Browserless {
    async fn browser(&self, http: &reqwest::Client, address: &str) -> String {
        // The sign-in page's form carries the same parameters, plus the person's choices.
        let query = address.split_once('?').unwrap().1;
        let challenge: altcha::Challenge = http
            .get(format!("{}/challenge", self.base))
            .send()
            .await
            .unwrap()
            .json()
            .await
            .unwrap();
        let solution = altcha::solve_challenge(SolveChallengeOptions::new(&challenge))
            .unwrap()
            .unwrap();
        let proof = STANDARD.encode(
            serde_json::to_vec(&Payload {
                challenge,
                solution,
            })
            .unwrap(),
        );
        let handle = format!("core{}", hex::encode(rand::random::<[u8; 4]>()));
        let body = format!(
            "{query}&{}",
            auth::form_encode(&[("mode", "new"), ("handle", &handle), ("altcha", &proof)])
        );
        let response = http
            .post(format!("{}/oauth/authorize", self.base))
            .header("Content-Type", "application/x-www-form-urlencoded")
            .body(body)
            .send()
            .await
            .unwrap();
        // A new account is shown its key once. The page then continues with that key.
        assert_eq!(response.status().as_u16(), 200, "new account page");
        let page = response.text().await.unwrap();
        let at = page.find("dak_").expect("the account key is shown");
        let key = &page[at..at + 47];
        let body = format!(
            "{query}&{}",
            auth::form_encode(&[("mode", "existing"), ("key", key)])
        );
        let response = http
            .post(format!("{}/oauth/authorize", self.base))
            .header("Content-Type", "application/x-www-form-urlencoded")
            .body(body)
            .send()
            .await
            .unwrap();
        assert_eq!(response.status().as_u16(), 303, "sign-in form");
        response.headers()["location"].to_str().unwrap().to_string()
    }
}

impl McpSignIn for Browserless {
    fn token<'a>(
        &'a self,
        _url: &'a str,
        force_refresh: bool,
    ) -> BoxFuture<'a, Result<Option<String>, McpError>> {
        Box::pin(async move {
            let Some(current) = self.stored.borrow().clone() else {
                return Ok(None);
            };
            if !force_refresh && !current.needs_refresh(auth_flow::now_secs()) {
                return Ok(Some(current.access_token));
            }
            let http = auth_flow::http_client()?;
            let next = auth_flow::refresh(&http, &current, &format!("{}/mcp", self.base))
                .await
                .map_err(|_| McpError::Protocol("refresh failed".into()))?;
            let token = next.access_token.clone();
            *self.stored.borrow_mut() = Some(next);
            Ok(Some(token))
        })
    }

    fn sign_in<'a>(
        &'a self,
        _name: &'a str,
        url: &'a str,
        why: &'a McpError,
    ) -> BoxFuture<'a, Result<(), McpError>> {
        Box::pin(async move {
            let McpError::Unauthorized {
                resource_metadata,
                scope,
                ..
            } = why
            else {
                panic!("expected a sign-in demand, got {why:?}");
            };
            assert!(resource_metadata.is_some(), "the Den names its metadata");
            let http = auth_flow::http_client()?;
            let found =
                auth_flow::discover(&http, url, resource_metadata.as_deref(), scope.as_deref())
                    .await?;
            let client_id = auth_flow::register(&http, &found.server, REDIRECT).await?;
            let pkce = auth::pkce_new();
            let state = auth::random_state();
            let address = auth::authorize_url(
                &found.server,
                &client_id,
                REDIRECT,
                &pkce.challenge,
                &state,
                found.scope.as_deref(),
                url,
            );
            let location = self.browser(&http, &address).await;
            assert!(location.starts_with(REDIRECT), "{location}");
            let code = auth::parse_callback(&location, &state).map_err(McpError::Protocol)?;
            let signed = auth_flow::exchange_code(
                &http,
                &found.server,
                &client_id,
                REDIRECT,
                &code,
                &pkce.verifier,
                url,
            )
            .await?;
            *self.stored.borrow_mut() = Some(signed);
            *self.signed_in.borrow_mut() += 1;
            Ok(())
        })
    }
}

#[tokio::test]
#[ignore = "needs a running Den: set DEN_E2E_URL"]
async fn a_den_signs_the_core_in_and_accepts_a_write() {
    let base = std::env::var("DEN_E2E_URL")
        .expect("set DEN_E2E_URL")
        .trim_end_matches('/')
        .to_string();
    let url = format!("{base}/mcp");
    let signer = Rc::new(Browserless {
        base: base.clone(),
        stored: RefCell::new(None),
        signed_in: RefCell::new(0),
    });
    let client = McpClient::connect_http_with(
        "den",
        &url,
        &McpSecrets::default(),
        Duration::from_secs(30),
        Some(signer.clone()),
    )
    .await
    .expect("connect");
    // The Den lets anyone initialize and read. The write is what asks for a sign-in.
    assert_eq!(*signer.signed_in.borrow(), 0);
    let slug = format!("core-{}", hex::encode(rand::random::<[u8; 3]>()));
    let answer = client
        .call_tool(
            "publish_item",
            json!({ "type": "imp", "slug": slug, "summary": "Published by the core's OAuth test",
                "tags": ["e2e"], "document": { "format": 1, "name": format!("Core {slug}"), "imps": [{ "name": "Zed" }] } }),
            &std::env::temp_dir(),
        )
        .await
        .unwrap();
    assert!(!answer.starts_with("Error:"), "{answer}");
    assert_eq!(*signer.signed_in.borrow(), 1, "signed in once, on demand");

    // A refresh trades the rotating refresh token, and the new access token works.
    let before = signer.stored.borrow().clone().unwrap();
    let http = auth_flow::http_client().unwrap();
    let next = auth_flow::refresh(&http, &before, &url).await.unwrap();
    assert_ne!(next.access_token, before.access_token);
    *signer.stored.borrow_mut() = Some(next);
    let again = McpClient::connect_http_with(
        "den",
        &url,
        &McpSecrets::default(),
        Duration::from_secs(30),
        Some(signer.clone()),
    )
    .await
    .unwrap();
    assert_eq!(*signer.signed_in.borrow(), 1, "no second sign-in");
    assert!(!again.list_tools().await.unwrap().is_empty());
}
