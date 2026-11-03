//! When and how often a failed request is tried again. Follows Swift `RetryPolicy`.

use std::future::Future;
use std::time::Duration;

/// What a retry attempt tells the caller before it waits.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct RetryNotice {
    /// This retry, counted from 1.
    pub attempt: u32,
    /// How many retries there are in all.
    pub of: u32,
    /// How long it waits before trying again.
    pub delay: Duration,
}

impl RetryNotice {
    pub fn text(&self) -> String {
        format!("Retrying {} of {}", self.attempt, self.of)
    }
}

/// Errors that know whether trying again could help.
pub trait Retryable {
    fn is_retryable(&self) -> bool;
}

/// Whether an HTTP status is worth another try: 408, 429 and every 5xx. Other 4xx never.
pub fn is_retryable_status(status: u16) -> bool {
    status == 408 || status == 429 || (500..600).contains(&status)
}

/// Tries after the first one, the first wait, the growth per retry and the longest wait.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct RetryPolicy {
    retries: u32,
    delay: f64,
    multiplier: f64,
    max_delay: f64,
}

impl RetryPolicy {
    /// Delays are in seconds. Negative values count as zero and a multiplier below 1 counts as 1.
    pub fn new(retries: u32, delay: f64, multiplier: f64, max_delay: f64) -> Self {
        let clean = |v: f64| if v.is_finite() { v } else { 0.0 };
        Self {
            retries,
            delay: clean(delay).max(0.0),
            multiplier: clean(multiplier).max(1.0),
            max_delay: clean(max_delay).max(0.0),
        }
    }

    /// A policy from stored request limits, which are clamped first: retries 0 to 10, the first
    /// delay 0 to 60 seconds, the growth 1 to 10. The longest wait is 60 seconds.
    pub fn from_limits(retries: i64, delay_seconds: f64, backoff: f64) -> Self {
        let clamp = |v: f64, lo: f64, hi: f64| if v.is_finite() { v.clamp(lo, hi) } else { lo };
        Self::new(
            retries.clamp(0, 10) as u32,
            clamp(delay_seconds, 0.0, 60.0),
            clamp(backoff, 1.0, 10.0),
            60.0,
        )
    }

    /// No retries at all.
    pub fn none() -> Self {
        Self::new(0, 0.0, 1.0, 60.0)
    }

    pub fn retries(&self) -> u32 {
        self.retries
    }

    /// The wait before retry number `retry` (the first retry is 1): the first delay, then longer
    /// by the multiplier each time, never beyond the cap.
    pub fn delay_before_retry(&self, retry: u32) -> Duration {
        let exponent = retry.saturating_sub(1).min(i32::MAX as u32) as i32;
        let seconds = (self.delay * self.multiplier.powi(exponent)).min(self.max_delay);
        Duration::from_secs_f64(seconds.max(0.0))
    }

    /// Runs `operation`, trying again after a failure that is retryable. `on_retry` hears each retry
    /// before its wait. `can_retry` can veto one (the answer already started showing). The last
    /// error comes back as it was. Dropping the returned future cancels it, also during a wait.
    pub async fn run<T, E, Fut>(
        &self,
        mut operation: impl FnMut() -> Fut,
        mut can_retry: impl FnMut() -> bool,
        mut on_retry: impl FnMut(RetryNotice),
    ) -> Result<T, E>
    where
        E: Retryable,
        Fut: Future<Output = Result<T, E>>,
    {
        let mut retry = 0;
        loop {
            match operation().await {
                Ok(value) => return Ok(value),
                Err(error) => {
                    if retry >= self.retries || !error.is_retryable() || !can_retry() {
                        return Err(error);
                    }
                    retry += 1;
                    let wait = self.delay_before_retry(retry);
                    on_retry(RetryNotice {
                        attempt: retry,
                        of: self.retries,
                        delay: wait,
                    });
                    tokio::time::sleep(wait).await;
                }
            }
        }
    }
}

impl Default for RetryPolicy {
    /// Three retries, a second apart at first, doubling, at most 20 seconds.
    fn default() -> Self {
        Self::new(3, 1.0, 2.0, 20.0)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::cell::Cell;

    #[derive(Debug, PartialEq)]
    struct Oops(bool);
    impl Retryable for Oops {
        fn is_retryable(&self) -> bool {
            self.0
        }
    }

    #[test]
    fn status_rules() {
        for s in [408, 429, 500, 503, 599] {
            assert!(is_retryable_status(s), "{s}");
        }
        for s in [400, 401, 403, 404, 422, 200, 600] {
            assert!(!is_retryable_status(s), "{s}");
        }
    }

    #[test]
    fn delays_grow_and_cap() {
        let p = RetryPolicy::new(5, 1.0, 2.0, 5.0);
        let d: Vec<f64> = (1..=5)
            .map(|r| p.delay_before_retry(r).as_secs_f64())
            .collect();
        assert_eq!(d, [1.0, 2.0, 4.0, 5.0, 5.0]);
    }

    #[test]
    fn values_are_clamped() {
        let p = RetryPolicy::new(1, -3.0, 0.2, 10.0);
        assert_eq!(p.delay_before_retry(3), Duration::ZERO);
        assert_eq!(RetryPolicy::none().retries(), 0);
    }

    #[tokio::test]
    async fn retries_then_succeeds() {
        let policy = RetryPolicy::new(3, 0.0, 1.0, 0.0);
        let calls = Cell::new(0);
        let mut notices = Vec::new();
        let out: Result<u32, Oops> = policy
            .run(
                || {
                    calls.set(calls.get() + 1);
                    let n = calls.get();
                    async move { if n < 3 { Err(Oops(true)) } else { Ok(n) } }
                },
                || true,
                |n| notices.push(n.attempt),
            )
            .await;
        assert_eq!(out, Ok(3));
        assert_eq!(notices, [1, 2]);
    }

    #[tokio::test]
    async fn stops_on_permanent_errors_and_when_vetoed_and_at_the_limit() {
        let policy = RetryPolicy::new(2, 0.0, 1.0, 0.0);
        let calls = Cell::new(0);
        let op = || {
            calls.set(calls.get() + 1);
            async { Err::<(), _>(Oops(false)) }
        };
        assert!(policy.run(op, || true, |_| {}).await.is_err());
        assert_eq!(calls.get(), 1);

        calls.set(0);
        let op = || {
            calls.set(calls.get() + 1);
            async { Err::<(), _>(Oops(true)) }
        };
        assert!(policy.run(op, || false, |_| {}).await.is_err());
        assert_eq!(calls.get(), 1);

        calls.set(0);
        let op = || {
            calls.set(calls.get() + 1);
            async { Err::<(), _>(Oops(true)) }
        };
        assert!(policy.run(op, || true, |_| {}).await.is_err());
        assert_eq!(calls.get(), 3);
    }

    #[tokio::test]
    async fn dropping_cancels_during_a_wait() {
        let policy = RetryPolicy::new(3, 60.0, 1.0, 60.0);
        let run = policy.run(|| async { Err::<(), _>(Oops(true)) }, || true, |_| {});
        let timed = tokio::time::timeout(Duration::from_millis(50), run).await;
        assert!(
            timed.is_err(),
            "the long wait was cut short by dropping the future"
        );
    }

    fn fixture() -> serde_json::Value {
        let path = concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/../../../Tests/Fixtures/retry-policy.json"
        );
        serde_json::from_str(&std::fs::read_to_string(path).expect("fixture")).expect("json")
    }

    fn policy_of(v: &serde_json::Value) -> RetryPolicy {
        RetryPolicy::new(
            v["retries"].as_u64().unwrap() as u32,
            v["delay"].as_f64().unwrap(),
            v["multiplier"].as_f64().unwrap(),
            v["maxDelay"].as_f64().unwrap_or(60.0),
        )
    }

    #[test]
    fn delays_match_the_vectors() {
        let f = fixture();
        let rows = f["delays"].as_array().unwrap();
        assert!(!rows.is_empty());
        for row in rows {
            let got = policy_of(&row["policy"])
                .delay_before_retry(row["retry"].as_u64().unwrap() as u32)
                .as_secs_f64();
            assert_eq!(got, row["wait"].as_f64().unwrap(), "{row}");
        }
    }

    #[test]
    fn limits_match_the_vectors() {
        let f = fixture();
        for row in f["limits"].as_array().unwrap() {
            let s = &row["stored"];
            let got = RetryPolicy::from_limits(
                s["retries"].as_i64().unwrap(),
                s["retryDelaySeconds"].as_f64().unwrap(),
                s["backoff"].as_f64().unwrap(),
            );
            assert_eq!(got, policy_of(&row["policy"]), "{}", row["name"]);
        }
    }

    #[test]
    fn errors_match_the_vectors() {
        use crate::chat::ChatError;
        let f = fixture();
        let transport = [
            "timedOut",
            "networkConnectionLost",
            "notConnectedToInternet",
            "cannotConnectToHost",
            "cannotFindHost",
            "dnsLookupFailed",
            "secureConnectionFailed",
        ];
        for row in f["errors"].as_array().unwrap() {
            let e = &row["error"];
            let error = match e["kind"].as_str().unwrap() {
                "http" => ChatError::Http {
                    status: e["status"].as_u64().unwrap() as u16,
                    message: String::new(),
                },
                "url" if transport.contains(&e["code"].as_str().unwrap()) => {
                    ChatError::Network(String::new())
                }
                _ => ChatError::Protocol(String::new()),
            };
            assert_eq!(
                error.is_retryable(),
                row["retryable"].as_bool().unwrap(),
                "{row}"
            );
        }
    }
}
