//! A build can ship with a model service address and an endpoint that hands out API keys. The first
//! run then gets a key without the person typing anything. This module holds every rule of it: which
//! build settings are valid, how an anonymous signup with proof of work is solved and read, and what
//! each refusal means. The apps move the bytes and call these functions. The command line app does
//! both with [`issue_key`].
//!
//! The service keeps its own limits (a monthly allowance per address, a cooldown between keys, a cap
//! per hour). Nothing here tries to get around them: one request asks for one key, every attempt
//! starts from a fresh challenge, and a refusal says how long to wait.

use base64::{Engine, engine::general_purpose::STANDARD};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};

use crate::chat::error_message;

/// The name a new key is given. It is only a label the service shows next to the key.
const KEY_NAME: &str = "Imp";

/// The algorithm of the challenges this module can solve.
const ALGORITHM: &str = "SHA-256";

/// The most numbers a challenge may ask to try. A service asks for a hundred thousand. A larger
/// number would make the device work for a long time, so it is refused as malformed.
const MAX_NUMBER: u64 = 5_000_000;

/// The addresses a build was made with.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ResellerSettings {
    /// The model service, such as `https://api.example.com/v1`, without a trailing slash.
    pub base_url: String,
    /// The endpoint that hands out keys. `{issuance_url}/challenge` serves the challenge.
    pub issuance_url: String,
}

/// What is wrong with the build settings. Each one says what to fix.
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum SettingsProblem {
    /// Only one of the two addresses is set.
    #[error("only one of the service address and the key endpoint is set: set both or neither")]
    Incomplete,
    /// An address is not an http or https address with a host.
    #[error("the {which} is not an http or https address")]
    BadAddress { which: &'static str },
}

impl ResellerSettings {
    /// The settings a build was made with. Both empty is no reseller (`Ok(None)`: the person adds a
    /// service by hand). Both valid is `Ok(Some(..))`. Anything else says what is wrong.
    pub fn parse(base: &str, issuance: &str) -> Result<Option<Self>, SettingsProblem> {
        let (base, issuance) = (base.trim(), issuance.trim());
        match (base.is_empty(), issuance.is_empty()) {
            (true, true) => return Ok(None),
            (false, false) => {}
            _ => return Err(SettingsProblem::Incomplete),
        }
        let base_url = address(base).ok_or(SettingsProblem::BadAddress {
            which: "service address",
        })?;
        let issuance_url = address(issuance).ok_or(SettingsProblem::BadAddress {
            which: "key endpoint",
        })?;
        Ok(Some(Self {
            base_url,
            issuance_url,
        }))
    }

    /// The host of the service, which names it in the app. Never empty.
    pub fn host(&self) -> String {
        host_of(&self.base_url).unwrap_or_default().to_string()
    }
}

/// `text` as an address to keep: http or https, with a host, and no trailing slash.
fn address(text: &str) -> Option<String> {
    host_of(text)?;
    Some(text.trim_end_matches('/').to_string())
}

/// The host of an http or https address, or none when it is another kind of address or has no host.
fn host_of(url: &str) -> Option<&str> {
    let lower = url.get(..8).unwrap_or(url).to_ascii_lowercase();
    let rest = if lower.starts_with("https://") {
        &url[8..]
    } else if lower.starts_with("http://") {
        &url[7..]
    } else {
        return None;
    };
    if rest.chars().any(char::is_whitespace) {
        return None;
    }
    let authority = rest.split(['/', '?', '#']).next().unwrap_or_default();
    let host_port = authority.rsplit('@').next().unwrap_or_default();
    let host = match host_port.strip_prefix('[') {
        Some(inside) => inside.split(']').next().unwrap_or_default(),
        None => host_port.split(':').next().unwrap_or_default(),
    };
    (!host.is_empty()).then_some(host)
}

/// Why a key could not be issued. [`Self::retry_after`] and [`Self::is_retryable`] say what to do next.
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum IssuanceError {
    /// The service refuses for now: a limit was reached. `retry_after` is how many seconds to wait,
    /// when the service said so.
    #[error("{message}")]
    RateLimited {
        retry_after: Option<u64>,
        message: String,
    },
    /// The service does not hand out keys at all (anonymous signup is switched off).
    #[error("{0}")]
    Disabled(String),
    /// The proof of work was missing, wrong or already used. A new attempt starts from a new challenge.
    #[error("{0}")]
    Rejected(String),
    /// The service failed or answered something this module does not know.
    #[error("the service answered {status}: {message}")]
    Server { status: u16, message: String },
    /// An answer that is not a challenge or a key, or a challenge that asks for too much or cannot be solved.
    #[error("unexpected answer: {0}")]
    Malformed(String),
    /// The connection failed or timed out.
    #[error("could not reach the service: {0}")]
    Network(String),
}

impl IssuanceError {
    /// Seconds to wait before asking again, when the service said.
    pub fn retry_after(&self) -> Option<u64> {
        match self {
            Self::RateLimited { retry_after, .. } => *retry_after,
            _ => None,
        }
    }

    /// Whether asking again later can work. A service with signup switched off, or one whose answers
    /// are not understood, will not change by itself.
    pub fn is_retryable(&self) -> bool {
        !matches!(self, Self::Disabled(_) | Self::Malformed(_))
    }

    /// The error of an answer with an error status. `retry_after` is the value of the `Retry-After`
    /// header: a number of seconds (a date is not read).
    fn from_answer(status: u16, body: &str, retry_after: Option<&str>) -> Self {
        let message = error_message(body);
        match status {
            429 => Self::RateLimited {
                retry_after: retry_after.and_then(|v| v.trim().parse().ok()),
                message,
            },
            403 => Self::Disabled(message),
            400 | 409 => Self::Rejected(message),
            _ => Self::Server { status, message },
        }
    }
}

/// A proof-of-work challenge (ALTCHA version 1, SHA-256), as the service serves it.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Challenge {
    pub algorithm: String,
    pub challenge: String,
    pub maxnumber: u64,
    pub salt: String,
    pub signature: String,
}

impl Challenge {
    /// The number whose digest (`hex(sha256(salt + decimal(number)))`) is the challenge.
    pub fn solve(&self) -> Option<u64> {
        let mut base = Sha256::new();
        base.update(self.salt.as_bytes());
        (0..=self.maxnumber).find(|number| {
            let mut hasher = base.clone();
            hasher.update(number.to_string().as_bytes());
            hex::encode(hasher.finalize()) == self.challenge
        })
    }
}

/// The challenge in the answer to `GET {issuance}/challenge`: none when the service says a proof of
/// work is not required.
pub fn parse_challenge(
    status: u16,
    body: &str,
    retry_after: Option<&str>,
) -> Result<Option<Challenge>, IssuanceError> {
    if !(200..300).contains(&status) {
        return Err(IssuanceError::from_answer(status, body, retry_after));
    }
    let malformed =
        || IssuanceError::Malformed("the challenge is not one this app can solve".into());
    let value: Value = serde_json::from_str(body).map_err(|_| malformed())?;
    if value.get("required").and_then(Value::as_bool) == Some(false) {
        return Ok(None);
    }
    let challenge: Challenge = serde_json::from_value(value).map_err(|_| malformed())?;
    if challenge.algorithm != ALGORITHM || challenge.maxnumber > MAX_NUMBER {
        return Err(malformed());
    }
    Ok(Some(challenge))
}

/// The JSON body that asks for a key: with the solved challenge as base64 when one was served.
/// A challenge no number solves is an error.
pub fn signup_body(challenge: Option<&Challenge>) -> Result<String, IssuanceError> {
    let mut body = json!({ "name": KEY_NAME });
    if let Some(challenge) = challenge {
        let number = challenge
            .solve()
            .ok_or_else(|| IssuanceError::Malformed("the challenge has no solution".into()))?;
        let solution = json!({
            "algorithm": challenge.algorithm,
            "challenge": challenge.challenge,
            "number": number,
            "salt": challenge.salt,
            "signature": challenge.signature,
        });
        body["altcha"] = Value::String(STANDARD.encode(solution.to_string()));
    }
    Ok(body.to_string())
}

/// The key in the answer to `POST {issuance}`. Every other field of the answer is ignored.
pub fn parse_issued(
    status: u16,
    body: &str,
    retry_after: Option<&str>,
) -> Result<String, IssuanceError> {
    if !(200..300).contains(&status) {
        return Err(IssuanceError::from_answer(status, body, retry_after));
    }
    serde_json::from_str::<Value>(body)
        .ok()
        .and_then(|v| {
            v.get("key")
                .and_then(Value::as_str)
                .map(|k| k.trim().to_string())
        })
        .filter(|key| !key.is_empty())
        .ok_or_else(|| IssuanceError::Malformed("the answer holds no key".into()))
}

/// Asks the endpoint of `settings` for a key: the challenge, its solution, then the signup. One call
/// is one attempt with a fresh challenge. The caller decides when to try again, and not before
/// [`IssuanceError::retry_after`].
#[cfg(feature = "io")]
pub async fn issue_key(settings: &ResellerSettings) -> Result<String, IssuanceError> {
    let http = reqwest::Client::builder()
        .connect_timeout(std::time::Duration::from_secs(15))
        .timeout(std::time::Duration::from_secs(60))
        .build()
        .map_err(|e| IssuanceError::Network(e.without_url().to_string()))?;
    let (status, retry_after, body) =
        send(http.get(format!("{}/challenge", settings.issuance_url))).await?;
    let challenge = parse_challenge(status, &body, retry_after.as_deref())?;
    let (status, retry_after, body) = send(
        http.post(&settings.issuance_url)
            .header("content-type", "application/json")
            .body(signup_body(challenge.as_ref())?),
    )
    .await?;
    parse_issued(status, &body, retry_after.as_deref())
}

/// Sends a request and reads the status, the `Retry-After` header and the body.
#[cfg(feature = "io")]
async fn send(
    request: reqwest::RequestBuilder,
) -> Result<(u16, Option<String>, String), IssuanceError> {
    let network = |e: reqwest::Error| IssuanceError::Network(e.without_url().to_string());
    let response = request.send().await.map_err(network)?;
    let status = response.status().as_u16();
    let retry_after = response
        .headers()
        .get(reqwest::header::RETRY_AFTER)
        .and_then(|v| v.to_str().ok())
        .map(String::from);
    let body = response.text().await.map_err(network)?;
    Ok((status, retry_after, body))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn challenge_for(number: u64, maxnumber: u64) -> Challenge {
        let salt = "0a1b2c?expires=4102444800".to_string();
        let mut hasher = Sha256::new();
        hasher.update(format!("{salt}{number}"));
        Challenge {
            algorithm: ALGORITHM.into(),
            challenge: hex::encode(hasher.finalize()),
            maxnumber,
            salt,
            signature: "ab".repeat(32),
        }
    }

    #[test]
    fn empty_settings_mean_no_reseller() {
        assert_eq!(ResellerSettings::parse("", ""), Ok(None));
        assert_eq!(ResellerSettings::parse("  ", "\n"), Ok(None));
    }

    #[test]
    fn two_valid_addresses_are_the_settings() {
        let settings = ResellerSettings::parse(
            " https://api.example.com/v1/ ",
            "http://localhost:8080/signup",
        )
        .unwrap()
        .unwrap();
        assert_eq!(settings.base_url, "https://api.example.com/v1");
        assert_eq!(settings.issuance_url, "http://localhost:8080/signup");
        assert_eq!(settings.host(), "api.example.com");
    }

    #[test]
    fn one_address_alone_is_incomplete() {
        let one = ResellerSettings::parse("https://api.example.com/v1", "");
        assert_eq!(one, Err(SettingsProblem::Incomplete));
        let other = ResellerSettings::parse("", "https://api.example.com/keys");
        assert_eq!(other, Err(SettingsProblem::Incomplete));
    }

    #[test]
    fn an_address_must_be_http_or_https_with_a_host() {
        for bad in [
            "ftp://api.example.com",
            "api.example.com/v1",
            "https://",
            "https:///v1",
            "https://a b/v1",
        ] {
            assert!(
                matches!(
                    ResellerSettings::parse(bad, "https://api.example.com/keys"),
                    Err(SettingsProblem::BadAddress {
                        which: "service address"
                    })
                ),
                "{bad}"
            );
        }
        assert!(matches!(
            ResellerSettings::parse("https://api.example.com/v1", "mailto:a@b"),
            Err(SettingsProblem::BadAddress {
                which: "key endpoint"
            })
        ));
    }

    #[test]
    fn the_host_skips_the_port_and_the_user() {
        for (url, host) in [
            ("https://user:pw@api.example.com:8443/v1", "api.example.com"),
            ("HTTP://API.example.com", "API.example.com"),
            ("http://[::1]:8080/v1", "::1"),
        ] {
            assert_eq!(host_of(url), Some(host), "{url}");
        }
    }

    #[test]
    fn a_challenge_is_solved_by_its_number() {
        let challenge = challenge_for(4321, 100_000);
        assert_eq!(challenge.solve(), Some(4321));
        assert_eq!(challenge_for(0, 0).solve(), Some(0));
        let unsolvable = Challenge {
            maxnumber: 10,
            ..challenge_for(4321, 100_000)
        };
        assert_eq!(unsolvable.solve(), None);
    }

    #[test]
    fn a_served_challenge_is_read() {
        let challenge = challenge_for(7, 100_000);
        let body = serde_json::to_string(&challenge).unwrap();
        assert_eq!(parse_challenge(200, &body, None), Ok(Some(challenge)));
    }

    #[test]
    fn no_proof_of_work_needed() {
        assert_eq!(
            parse_challenge(200, r#"{"required":false}"#, None),
            Ok(None)
        );
        let body = signup_body(None).unwrap();
        assert_eq!(
            serde_json::from_str::<Value>(&body).unwrap(),
            json!({"name": "Imp"})
        );
    }

    #[test]
    fn a_challenge_that_asks_too_much_or_is_unknown_is_refused() {
        let hard = Challenge {
            maxnumber: MAX_NUMBER + 1,
            ..challenge_for(1, 10)
        };
        let other = Challenge {
            algorithm: "SHA-512".into(),
            ..challenge_for(1, 10)
        };
        for challenge in [hard, other] {
            let body = serde_json::to_string(&challenge).unwrap();
            assert!(matches!(
                parse_challenge(200, &body, None),
                Err(IssuanceError::Malformed(_))
            ));
        }
        assert!(matches!(
            parse_challenge(200, "nope", None),
            Err(IssuanceError::Malformed(_))
        ));
        assert!(matches!(
            parse_challenge(200, "{}", None),
            Err(IssuanceError::Malformed(_))
        ));
    }

    #[test]
    fn the_signup_carries_the_solution_as_base64() {
        let challenge = challenge_for(99, 1000);
        let body: Value = serde_json::from_str(&signup_body(Some(&challenge)).unwrap()).unwrap();
        assert_eq!(body["name"], "Imp");
        let payload = STANDARD.decode(body["altcha"].as_str().unwrap()).unwrap();
        let solution: Value = serde_json::from_slice(&payload).unwrap();
        assert_eq!(solution["number"], 99);
        assert_eq!(solution["algorithm"], "SHA-256");
        assert_eq!(solution["challenge"], challenge.challenge);
        assert_eq!(solution["salt"], challenge.salt);
        assert_eq!(solution["signature"], challenge.signature);
    }

    #[test]
    fn an_unsolvable_challenge_makes_no_signup() {
        let challenge = Challenge {
            maxnumber: 3,
            ..challenge_for(500, 1000)
        };
        assert!(matches!(
            signup_body(Some(&challenge)),
            Err(IssuanceError::Malformed(_))
        ));
    }

    #[test]
    fn the_key_is_all_that_is_kept_of_the_answer() {
        let body = r#"{"id":"k1","key":"sk-res-abc","name":"Imp","balance":{"amount":"1.00"}}"#;
        assert_eq!(parse_issued(201, body, None), Ok("sk-res-abc".into()));
        assert!(matches!(
            parse_issued(200, r#"{"id":"k1"}"#, None),
            Err(IssuanceError::Malformed(_))
        ));
        assert!(matches!(
            parse_issued(200, r#"{"key":" "}"#, None),
            Err(IssuanceError::Malformed(_))
        ));
    }

    fn refusal(status: u16, code: &str, retry_after: Option<&str>) -> IssuanceError {
        let body = json!({"error": {"message": "no", "type": "x", "param": null, "code": code}})
            .to_string();
        parse_issued(status, &body, retry_after).unwrap_err()
    }

    #[test]
    fn refusals_say_what_to_do() {
        for code in [
            "ip_key_limit",
            "creation_cooldown",
            "creation_rate_limited",
            "challenge_rate_limited",
        ] {
            let error = refusal(429, code, Some("120"));
            assert_eq!(error.retry_after(), Some(120), "{code}");
            assert!(error.is_retryable());
        }
        assert_eq!(refusal(429, "ip_key_limit", None).retry_after(), None);
        assert_eq!(
            refusal(429, "ip_key_limit", Some("Wed, 21 Oct 2026 07:28:00 GMT")).retry_after(),
            None
        );
        for (status, code) in [
            (400, "pow_required"),
            (400, "pow_invalid"),
            (409, "pow_replayed"),
        ] {
            let error = refusal(status, code, None);
            assert!(matches!(error, IssuanceError::Rejected(_)), "{code}");
            assert!(error.is_retryable());
        }
        let disabled = refusal(403, "signup_disabled", None);
        assert!(matches!(disabled, IssuanceError::Disabled(_)));
        assert!(!disabled.is_retryable());
        assert!(matches!(
            refusal(503, "unavailable", None),
            IssuanceError::Server { status: 503, .. }
        ));
        assert!(matches!(
            parse_issued(502, "<html>bad gateway</html>", None),
            Err(IssuanceError::Server { status: 502, .. })
        ));
    }

    #[test]
    fn the_challenge_request_has_the_same_refusals() {
        let body = r#"{"error":{"message":"slow down","type":"rate_limit_error","param":null,"code":"challenge_rate_limited"}}"#;
        assert_eq!(
            parse_challenge(429, body, Some("30")),
            Err(IssuanceError::RateLimited {
                retry_after: Some(30),
                message: "slow down".into()
            })
        );
    }
}
