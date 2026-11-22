//! Getting a key from the endpoint a build was made with. The apps send the requests with their own
//! HTTP client and call these functions for every rule: which settings are valid, what the challenge
//! asks, how it is solved and what each answer means.

use imp_engine::issuance::{self, IssuanceError, ResellerSettings as Settings, SettingsProblem};

/// The addresses a build was made with.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct ResellerSettings {
    /// The model service, without a trailing slash. It is where the chat requests go.
    pub base_url: String,
    /// The endpoint that hands out keys.
    pub issuance_url: String,
    /// The host of the service, which names it in the app.
    pub host: String,
}

/// The build settings are wrong.
#[derive(Debug, uniffi::Error)]
pub enum ResellerSettingsError {
    /// What is wrong and what to fix, as a sentence.
    Invalid { message: String },
}

impl std::fmt::Display for ResellerSettingsError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        let Self::Invalid { message } = self;
        f.write_str(message)
    }
}

impl From<SettingsProblem> for ResellerSettingsError {
    fn from(problem: SettingsProblem) -> Self {
        Self::Invalid {
            message: problem.to_string(),
        }
    }
}

/// Why a key could not be issued.
#[derive(Debug, uniffi::Error)]
pub enum IssuanceFailure {
    /// A limit was reached. `retry_after` is the seconds to wait, when the service said so.
    RateLimited {
        retry_after: Option<u64>,
        message: String,
    },
    /// The service does not hand out keys. Asking again changes nothing.
    Disabled { message: String },
    /// The proof of work was missing, wrong or used. A new attempt starts from a new challenge.
    Rejected { message: String },
    /// The service failed.
    Server { status: u16, message: String },
    /// An answer that is not a challenge or a key. Asking again changes nothing.
    Malformed { message: String },
    /// The connection failed or timed out. The apps raise it themselves.
    Network { message: String },
}

impl std::fmt::Display for IssuanceFailure {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::RateLimited { message, .. }
            | Self::Disabled { message }
            | Self::Rejected { message }
            | Self::Server { message, .. }
            | Self::Malformed { message }
            | Self::Network { message } => f.write_str(message),
        }
    }
}

impl From<IssuanceError> for IssuanceFailure {
    fn from(error: IssuanceError) -> Self {
        let message = error.to_string();
        match error {
            IssuanceError::RateLimited { retry_after, .. } => Self::RateLimited {
                retry_after,
                message,
            },
            IssuanceError::Disabled(_) => Self::Disabled { message },
            IssuanceError::Rejected(_) => Self::Rejected { message },
            IssuanceError::Server { status, .. } => Self::Server { status, message },
            IssuanceError::Malformed(_) => Self::Malformed { message },
            IssuanceError::Network(_) => Self::Network { message },
        }
    }
}

/// A proof-of-work challenge, as the endpoint serves it.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct IssuanceChallenge {
    pub algorithm: String,
    pub challenge: String,
    pub maxnumber: u64,
    pub salt: String,
    pub signature: String,
}

impl From<issuance::Challenge> for IssuanceChallenge {
    fn from(c: issuance::Challenge) -> Self {
        Self {
            algorithm: c.algorithm,
            challenge: c.challenge,
            maxnumber: c.maxnumber,
            salt: c.salt,
            signature: c.signature,
        }
    }
}

impl From<IssuanceChallenge> for issuance::Challenge {
    fn from(c: IssuanceChallenge) -> Self {
        Self {
            algorithm: c.algorithm,
            challenge: c.challenge,
            maxnumber: c.maxnumber,
            salt: c.salt,
            signature: c.signature,
        }
    }
}

/// The settings of a build from its two addresses. Both empty is `nil`: the person adds a service by
/// hand. One empty or a bad address is an error that says what to fix.
#[uniffi::export]
pub fn parse_reseller_settings(
    base: String,
    issuance: String,
) -> Result<Option<ResellerSettings>, ResellerSettingsError> {
    Ok(
        Settings::parse(&base, &issuance)?.map(|settings| ResellerSettings {
            host: settings.host(),
            base_url: settings.base_url,
            issuance_url: settings.issuance_url,
        }),
    )
}

/// The address to `GET` for a challenge.
#[uniffi::export]
pub fn issuance_challenge_url(issuance_url: String) -> String {
    format!("{}/challenge", issuance_url.trim_end_matches('/'))
}

/// The challenge in the answer to the challenge request, or `nil` when none is required.
#[uniffi::export]
pub fn parse_issuance_challenge(
    status: u16,
    body: String,
    retry_after: Option<String>,
) -> Result<Option<IssuanceChallenge>, IssuanceFailure> {
    Ok(issuance::parse_challenge(status, &body, retry_after.as_deref())?.map(Into::into))
}

/// The JSON body of the request for a key, with the challenge solved. Solving takes a moment of
/// work, so call it off the main thread.
#[uniffi::export]
pub fn issuance_signup_body(
    challenge: Option<IssuanceChallenge>,
) -> Result<String, IssuanceFailure> {
    let challenge = challenge.map(issuance::Challenge::from);
    Ok(issuance::signup_body(challenge.as_ref())?)
}

/// The key in the answer to the request for a key.
#[uniffi::export]
pub fn parse_issued_key(
    status: u16,
    body: String,
    retry_after: Option<String>,
) -> Result<String, IssuanceFailure> {
    Ok(issuance::parse_issued(
        status,
        &body,
        retry_after.as_deref(),
    )?)
}

/// Whether asking again can work. A service with signup off, or one whose answers are not
/// understood, will not change by itself.
#[uniffi::export]
pub fn issuance_failure_is_retryable(failure: &IssuanceFailure) -> bool {
    !matches!(
        failure,
        IssuanceFailure::Disabled { .. } | IssuanceFailure::Malformed { .. }
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn settings_cross_as_records() {
        assert_eq!(
            parse_reseller_settings(String::new(), String::new()).unwrap(),
            None
        );
        let settings = parse_reseller_settings(
            "https://api.example.com/v1/".into(),
            "https://api.example.com/v1/signup".into(),
        )
        .unwrap()
        .unwrap();
        assert_eq!(settings.host, "api.example.com");
        assert_eq!(settings.base_url, "https://api.example.com/v1");
        assert!(
            parse_reseller_settings("https://api.example.com/v1".into(), String::new()).is_err()
        );
    }

    #[test]
    fn the_challenge_address_and_the_failures_cross() {
        assert_eq!(
            issuance_challenge_url("https://api.example.com/v1/signup/".into()),
            "https://api.example.com/v1/signup/challenge"
        );
        let failure = parse_issued_key(
            429,
            r#"{"error":{"message":"wait"}}"#.into(),
            Some("30".into()),
        )
        .unwrap_err();
        assert!(matches!(
            &failure,
            IssuanceFailure::RateLimited {
                retry_after: Some(30),
                ..
            }
        ));
        assert!(issuance_failure_is_retryable(&failure));
        let final_failure = parse_issued_key(200, "{}".into(), None).unwrap_err();
        assert!(!issuance_failure_is_retryable(&final_failure));
        assert_eq!(
            parse_issuance_challenge(200, r#"{"required":false}"#.into(), None).unwrap(),
            None
        );
        assert_eq!(issuance_signup_body(None).unwrap(), r#"{"name":"Imp"}"#);
    }
}
