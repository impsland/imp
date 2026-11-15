//! Request limits and the retry policy.

use imp_engine::retry::{self, LimitRange as CoreRange, RequestLimits as CoreLimits};

/// One allowed span for a request limit, and the step its control moves by.
#[derive(Debug, Clone, Copy, PartialEq, uniffi::Record)]
pub struct LimitRange {
    pub min: f64,
    pub max: f64,
    pub step: f64,
}

impl From<CoreRange> for LimitRange {
    fn from(r: CoreRange) -> Self {
        Self {
            min: r.min,
            max: r.max,
            step: r.step,
        }
    }
}

/// How long a model request may take and how it is retried.
#[derive(Debug, Clone, Copy, PartialEq, uniffi::Record)]
pub struct RequestLimits {
    pub timeout_seconds: f64,
    pub retries: i64,
    pub retry_delay_seconds: f64,
    pub backoff: f64,
}

impl From<CoreLimits> for RequestLimits {
    fn from(l: CoreLimits) -> Self {
        Self {
            timeout_seconds: l.timeout_seconds,
            retries: l.retries,
            retry_delay_seconds: l.retry_delay_seconds,
            backoff: l.backoff,
        }
    }
}

impl From<RequestLimits> for CoreLimits {
    fn from(l: RequestLimits) -> Self {
        Self {
            timeout_seconds: l.timeout_seconds,
            retries: l.retries,
            retry_delay_seconds: l.retry_delay_seconds,
            backoff: l.backoff,
        }
    }
}

/// The ranges each limit may take, for the controls that set them.
#[derive(Debug, Clone, Copy, PartialEq, uniffi::Record)]
pub struct RequestLimitRanges {
    pub timeout: LimitRange,
    pub timeout_control_max: f64,
    pub retries: LimitRange,
    pub delay: LimitRange,
    pub backoff: LimitRange,
    pub max_delay: f64,
}

#[uniffi::export]
pub fn request_limits_default() -> RequestLimits {
    CoreLimits::default().into()
}

#[uniffi::export]
pub fn request_limit_ranges() -> RequestLimitRanges {
    RequestLimitRanges {
        timeout: CoreLimits::TIMEOUT.into(),
        timeout_control_max: CoreLimits::TIMEOUT_CONTROL_MAX,
        retries: CoreLimits::RETRIES.into(),
        delay: CoreLimits::DELAY.into(),
        backoff: CoreLimits::BACKOFF.into(),
        max_delay: CoreLimits::MAX_DELAY,
    }
}

/// Every value inside its range.
#[uniffi::export]
pub fn request_limits_clamped(limits: RequestLimits) -> RequestLimits {
    CoreLimits::from(limits).clamped().into()
}

/// When and how often a failed request is tried again. Delays are in seconds.
#[derive(Debug, Clone, Copy, PartialEq, uniffi::Record)]
pub struct RetryPolicy {
    pub retries: u32,
    pub delay: f64,
    pub multiplier: f64,
    pub max_delay: f64,
}

impl From<RetryPolicy> for retry::RetryPolicy {
    fn from(p: RetryPolicy) -> Self {
        retry::RetryPolicy::new(p.retries, p.delay, p.multiplier, p.max_delay)
    }
}

/// The policy `limits` make, after clamping.
#[uniffi::export]
pub fn request_limits_policy(limits: RequestLimits) -> RetryPolicy {
    let l = CoreLimits::from(limits).clamped();
    RetryPolicy {
        retries: l.retries as u32,
        delay: l.retry_delay_seconds,
        multiplier: l.backoff,
        max_delay: CoreLimits::MAX_DELAY,
    }
}

/// The wait in seconds before retry number `retry` (the first retry is 1).
#[uniffi::export]
pub fn retry_policy_delay(policy: RetryPolicy, retry: u32) -> f64 {
    retry::RetryPolicy::from(policy)
        .delay_before_retry(retry)
        .as_secs_f64()
}

/// Whether a service's HTTP status is worth another try.
#[uniffi::export]
pub fn is_retryable_status(status: u16) -> bool {
    retry::is_retryable_status(status)
}
