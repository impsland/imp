//! Getting a key from an issuance endpoint, against a local mock server, and reading the answers of a
//! model service from recorded samples in `spec/fixtures/reseller/`. No real service is called.

use base64::{Engine, engine::general_purpose::STANDARD};
use imp_engine::chat::{error_message, is_out_of_credit, parse_model_ids};
use imp_engine::issuance::{IssuanceError, ResellerSettings, issue_key};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::path::Path;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpListener;

struct Mock {
    settings: ResellerSettings,
    count: Arc<AtomicUsize>,
    seen: Arc<Mutex<Vec<String>>>,
}

/// Answers each connection with the next canned response (the last one repeats).
async fn mock(responses: Vec<String>) -> Mock {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let address = listener.local_addr().unwrap();
    let count = Arc::new(AtomicUsize::new(0));
    let seen = Arc::new(Mutex::new(Vec::new()));
    let (c, s) = (count.clone(), seen.clone());
    tokio::spawn(async move {
        loop {
            let Ok((mut socket, _)) = listener.accept().await else {
                return;
            };
            let n = c.fetch_add(1, Ordering::SeqCst);
            let response = responses.get(n).or(responses.last()).unwrap().clone();
            let seen = s.clone();
            tokio::spawn(async move {
                let mut data = Vec::new();
                let mut buf = [0u8; 4096];
                loop {
                    let read = socket.read(&mut buf).await.unwrap_or(0);
                    data.extend_from_slice(&buf[..read]);
                    let text = String::from_utf8_lossy(&data).to_string();
                    if let Some((head, body)) = text.split_once("\r\n\r\n") {
                        let length = head
                            .lines()
                            .find_map(|l| {
                                l.to_ascii_lowercase()
                                    .strip_prefix("content-length:")
                                    .map(|v| v.trim().parse::<usize>().unwrap())
                            })
                            .unwrap_or(0);
                        if body.len() >= length {
                            break;
                        }
                    }
                    if read == 0 {
                        break;
                    }
                }
                seen.lock()
                    .unwrap()
                    .push(String::from_utf8_lossy(&data).to_string());
                let _ = socket.write_all(response.as_bytes()).await;
                let _ = socket.shutdown().await;
            });
        }
    });
    let settings = ResellerSettings::parse(
        &format!("http://{address}/v1"),
        &format!("http://{address}/v1/signup"),
    )
    .unwrap()
    .unwrap();
    Mock {
        settings,
        count,
        seen,
    }
}

fn answer(code: u16, headers: &str, body: &str) -> String {
    format!(
        "HTTP/1.1 {code} X\r\ncontent-type: application/json\r\n{headers}content-length: {}\r\nconnection: close\r\n\r\n{body}",
        body.len()
    )
}

fn ok(body: &str) -> String {
    answer(200, "", body)
}

/// A challenge whose answer is `number`.
fn challenge(number: u64, salt: &str) -> String {
    let salt = format!("{salt}?expires=4102444800");
    let digest = hex::encode(Sha256::digest(format!("{salt}{number}")));
    json!({"algorithm":"SHA-256","challenge":digest,"maxnumber":100000,"salt":salt,"signature":"ab".repeat(32)})
        .to_string()
}

fn error_body(code: &str) -> String {
    json!({"error":{"message":"no","type":"x","param":null,"code":code}}).to_string()
}

fn request(mock: &Mock, n: usize) -> String {
    mock.seen.lock().unwrap()[n].clone()
}

fn json_body(request: &str) -> Value {
    serde_json::from_str(request.split_once("\r\n\r\n").unwrap().1).unwrap()
}

#[tokio::test]
async fn a_solved_challenge_gets_a_key() {
    let mock = mock(vec![
        ok(&challenge(4321, "aa")),
        answer(201, "", r#"{"id":"k1","key":"sk-res-abc","name":"Imp"}"#),
    ])
    .await;
    assert_eq!(issue_key(&mock.settings).await.as_deref(), Ok("sk-res-abc"));
    assert!(request(&mock, 0).starts_with("GET /v1/signup/challenge "));
    let signup = request(&mock, 1);
    assert!(signup.starts_with("POST /v1/signup "));
    let body = json_body(&signup);
    assert_eq!(body["name"], "Imp");
    let solution: Value =
        serde_json::from_slice(&STANDARD.decode(body["altcha"].as_str().unwrap()).unwrap())
            .unwrap();
    assert_eq!(solution["number"], 4321);
}

#[tokio::test]
async fn no_proof_of_work_asks_without_altcha() {
    let mock = mock(vec![
        ok(r#"{"required":false}"#),
        answer(201, "", r#"{"key":"sk-res-abc"}"#),
    ])
    .await;
    assert_eq!(issue_key(&mock.settings).await.as_deref(), Ok("sk-res-abc"));
    assert_eq!(json_body(&request(&mock, 1)), json!({"name": "Imp"}));
}

#[tokio::test]
async fn a_server_that_is_not_there_is_a_network_error() {
    let dead = {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        listener.local_addr().unwrap()
    };
    let settings = ResellerSettings::parse(
        &format!("http://{dead}/v1"),
        &format!("http://{dead}/v1/signup"),
    )
    .unwrap()
    .unwrap();
    let error = issue_key(&settings).await.unwrap_err();
    assert!(matches!(error, IssuanceError::Network(_)), "{error:?}");
    assert!(error.is_retryable());
}

#[tokio::test]
async fn a_server_error_can_be_tried_again() {
    let mock = mock(vec![answer(503, "", "")]).await;
    let error = issue_key(&mock.settings).await.unwrap_err();
    assert!(matches!(error, IssuanceError::Server { status: 503, .. }));
    assert!(error.is_retryable());
    assert_eq!(mock.count.load(Ordering::SeqCst), 1);
}

#[tokio::test]
async fn a_limit_says_how_long_to_wait() {
    for code in ["ip_key_limit", "creation_cooldown"] {
        let mock = mock(vec![
            ok(r#"{"required":false}"#),
            answer(429, "retry-after: 90\r\n", &error_body(code)),
        ])
        .await;
        let error = issue_key(&mock.settings).await.unwrap_err();
        assert_eq!(error.retry_after(), Some(90), "{code}");
        assert!(error.is_retryable());
        assert_eq!(error.to_string(), "no");
    }
}

#[tokio::test]
async fn a_wrong_proof_is_rejected() {
    let mock = mock(vec![
        ok(&challenge(5, "aa")),
        answer(400, "", &error_body("pow_invalid")),
    ])
    .await;
    let error = issue_key(&mock.settings).await.unwrap_err();
    assert!(matches!(error, IssuanceError::Rejected(_)));
    assert!(error.is_retryable());
}

#[tokio::test]
async fn a_retry_after_a_failure_starts_from_a_fresh_challenge() {
    let mock = mock(vec![
        ok(&challenge(11, "aa")),
        answer(503, "", ""),
        ok(&challenge(22, "bb")),
        answer(201, "", r#"{"key":"sk-res-new"}"#),
    ])
    .await;
    assert!(issue_key(&mock.settings).await.is_err());
    assert_eq!(issue_key(&mock.settings).await.as_deref(), Ok("sk-res-new"));
    assert_eq!(mock.count.load(Ordering::SeqCst), 4);
    assert!(request(&mock, 2).starts_with("GET /v1/signup/challenge "));
    let body = json_body(&request(&mock, 3));
    let solution: Value =
        serde_json::from_slice(&STANDARD.decode(body["altcha"].as_str().unwrap()).unwrap())
            .unwrap();
    assert_eq!(solution["number"], 22);
    assert!(solution["salt"].as_str().unwrap().starts_with("bb?"));
}

fn sample(name: &str) -> String {
    let path = Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../spec/fixtures/reseller")
        .join(name);
    std::fs::read_to_string(path).unwrap()
}

#[test]
fn the_model_list_is_read() {
    assert_eq!(
        parse_model_ids(&sample("models.json")),
        ["assistant", "fast"]
    );
}

#[test]
fn a_missing_key_is_not_out_of_credit() {
    let body = sample("error-401.json");
    assert_eq!(
        error_message(&body),
        "Missing bearer authentication in header"
    );
    assert!(!is_out_of_credit(401, &body));
    assert_eq!(
        error_message(&sample("error-401-invalid.json")),
        "Invalid API key"
    );
}

#[test]
fn an_empty_balance_is_out_of_credit_and_a_rate_limit_is_not() {
    let body = sample("error-429-quota.json");
    assert!(error_message(&body).starts_with("You exceeded your current quota."));
    assert!(is_out_of_credit(429, &body));
    assert!(!is_out_of_credit(402, &body));
    assert!(!is_out_of_credit(429, &sample("error-429-rate.json")));
    assert!(!is_out_of_credit(429, "slow down"));
}
