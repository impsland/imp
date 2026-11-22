//! The first run of a build that ships with a model service: a key is issued for it, so the person
//! is not asked for one. Anything that goes wrong asks whether to try again, and "no" is the usual
//! steps, where a service and key are typed.

use crate::strings::{self, Lang};
use imp_engine::issuance::{IssuanceError, ResellerSettings, issue_key};
use std::future::Future;
use std::io::{BufRead, Write};

/// The addresses this build was made with, from `apple/Config/Reseller.xcconfig` or the environment
/// (see `chat/build.rs`). None when they are empty, or are not a pair of valid addresses.
fn built_in() -> Option<ResellerSettings> {
    ResellerSettings::parse(env!("IMP_RESELLER_URL"), env!("IMP_RESELLER_ISSUANCE_URL"))
        .ok()
        .flatten()
}

/// A name `imp.json` accepts for a service, from its host: letters, digits, `-` and `_`.
fn provider_id(host: &str) -> String {
    host.chars()
        .map(|c| {
            if c.is_ascii_alphanumeric() || c == '-' || c == '_' {
                c
            } else {
                '-'
            }
        })
        .collect()
}

/// The service of this build and a key issued for it: its name, address and key. None when the build
/// has no service, or the person gave up.
pub(super) async fn first_key(lang: Lang) -> Option<(String, String, String)> {
    let settings = built_in()?;
    let key = obtain(
        &settings,
        lang,
        |settings| async move { issue_key(&settings).await },
        &mut std::io::stdout(),
        &mut std::io::stdin().lock(),
    )
    .await?;
    Some((provider_id(&settings.host()), settings.base_url, key))
}

/// Issues a key with `issue`, asking on `out` and reading the answer from `input` before each new
/// attempt. A service that will not hand out keys, or a "no", ends it.
async fn obtain<F, Fut>(
    settings: &ResellerSettings,
    lang: Lang,
    issue: F,
    out: &mut impl Write,
    input: &mut impl BufRead,
) -> Option<String>
where
    F: Fn(ResellerSettings) -> Fut,
    Fut: Future<Output = Result<String, IssuanceError>>,
{
    let host = settings.host();
    loop {
        let working = strings::format(lang, "cli.start.issue_working", &[("host", &host)]);
        writeln!(out, "{working}").ok()?;
        let error = match issue(settings.clone()).await {
            Ok(key) => return Some(key),
            Err(error) => error,
        };
        if !error.is_retryable() {
            return None;
        }
        let question = match error.retry_after() {
            Some(seconds) => strings::format(
                lang,
                "cli.start.issue_retry_wait",
                &[("seconds", &seconds.to_string())],
            ),
            None => strings::text(lang, "cli.start.issue_retry").to_string(),
        };
        write!(out, "{question}").ok()?;
        out.flush().ok()?;
        let mut answer = String::new();
        input.read_line(&mut answer).ok()?;
        if answer.trim().to_lowercase().starts_with('n') || answer.is_empty() {
            return None;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::cell::Cell;

    fn settings() -> ResellerSettings {
        ResellerSettings::parse(
            "https://api.example.com/v1",
            "https://api.example.com/v1/signup",
        )
        .unwrap()
        .unwrap()
    }

    async fn run(
        results: Vec<Result<String, IssuanceError>>,
        typed: &str,
    ) -> (Option<String>, String, usize) {
        let calls = Cell::new(0);
        let results = std::sync::Mutex::new(results.into_iter());
        let mut out = Vec::new();
        let key = obtain(
            &settings(),
            Lang::En,
            |_| {
                calls.set(calls.get() + 1);
                let next = results.lock().unwrap().next().unwrap();
                async move { next }
            },
            &mut out,
            &mut typed.as_bytes(),
        )
        .await;
        (key, String::from_utf8(out).unwrap(), calls.get())
    }

    fn down() -> IssuanceError {
        IssuanceError::Network("offline".into())
    }

    #[test]
    fn the_name_of_a_service_is_made_of_its_host() {
        assert_eq!(provider_id("api.example.com"), "api-example-com");
        assert_eq!(provider_id("::1"), "--1");
    }

    #[tokio::test]
    async fn a_key_is_issued_without_a_question() {
        let (key, shown, calls) = run(vec![Ok("sk-res-1".into())], "").await;
        assert_eq!(key.as_deref(), Some("sk-res-1"));
        assert_eq!(shown, "Getting a key for api.example.com...\n");
        assert_eq!(calls, 1);
    }

    #[tokio::test]
    async fn a_failure_asks_and_enter_tries_again() {
        let (key, shown, calls) = run(vec![Err(down()), Ok("sk-res-2".into())], "\n").await;
        assert_eq!(key.as_deref(), Some("sk-res-2"));
        assert!(shown.contains("Could not get a key. Try again? [Y/n] "));
        assert!(!shown.contains("offline"));
        assert_eq!(calls, 2);
    }

    #[tokio::test]
    async fn no_goes_to_the_usual_steps() {
        let (key, _, calls) = run(vec![Err(down())], "n\n").await;
        assert_eq!(key, None);
        assert_eq!(calls, 1);
        let (key, _, _) = run(vec![Err(down())], "").await;
        assert_eq!(key, None);
    }

    #[tokio::test]
    async fn a_limit_says_how_long_to_wait() {
        let limit = IssuanceError::RateLimited {
            retry_after: Some(90),
            message: "no".into(),
        };
        let (key, shown, _) = run(vec![Err(limit), Ok("sk-res-3".into())], "y\n").await;
        assert_eq!(key.as_deref(), Some("sk-res-3"));
        assert!(shown.contains("wait 90 seconds"));
    }

    #[tokio::test]
    async fn a_service_without_signup_is_not_asked_again() {
        let (key, shown, calls) = run(vec![Err(IssuanceError::Disabled("off".into()))], "").await;
        assert_eq!(key, None);
        assert!(!shown.contains("[Y/n]"));
        assert_eq!(calls, 1);
    }
}
