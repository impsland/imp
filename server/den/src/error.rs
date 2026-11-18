//! Errors as RFC 9457 problem details.

use std::time::Duration;

use axum::http::{HeaderValue, StatusCode, header};
use axum::response::{IntoResponse, Response};
use serde::Serialize;
use serde_json::{Value, json};

/// One thing wrong in a request, located by a JSON pointer into it.
#[derive(Debug, Clone, Serialize)]
pub struct Violation {
    pub pointer: String,
    pub detail: String,
}

#[derive(Debug, Clone)]
pub enum Error {
    BadRequest(String),
    Unauthorized,
    Forbidden(String),
    NotFound,
    MethodNotAllowed,
    AccountDeactivated,
    HandleTaken,
    Duplicate(String),
    TooLarge,
    UnsupportedMedia,
    Invalid(Vec<Violation>),
    UnsupportedFormat(String),
    Challenge(String),
    Quota(String),
    RateLimited(Duration),
    Timeout,
    Internal,
}

impl Error {
    pub fn invalid(pointer: &str, detail: impl Into<String>) -> Self {
        Error::Invalid(vec![Violation {
            pointer: pointer.to_owned(),
            detail: detail.into(),
        }])
    }

    pub fn status(&self) -> StatusCode {
        match self {
            Error::BadRequest(_) => StatusCode::BAD_REQUEST,
            Error::Unauthorized => StatusCode::UNAUTHORIZED,
            Error::Forbidden(_) | Error::Quota(_) | Error::AccountDeactivated => {
                StatusCode::FORBIDDEN
            }
            Error::NotFound => StatusCode::NOT_FOUND,
            Error::MethodNotAllowed => StatusCode::METHOD_NOT_ALLOWED,
            Error::HandleTaken | Error::Duplicate(_) => StatusCode::CONFLICT,
            Error::TooLarge => StatusCode::PAYLOAD_TOO_LARGE,
            Error::UnsupportedMedia => StatusCode::UNSUPPORTED_MEDIA_TYPE,
            Error::Invalid(_) | Error::UnsupportedFormat(_) | Error::Challenge(_) => {
                StatusCode::UNPROCESSABLE_ENTITY
            }
            Error::RateLimited(_) => StatusCode::TOO_MANY_REQUESTS,
            Error::Timeout => StatusCode::SERVICE_UNAVAILABLE,
            Error::Internal => StatusCode::INTERNAL_SERVER_ERROR,
        }
    }

    /// The last part of the problem's `type` URI, and its title.
    pub fn name(&self) -> (&'static str, &'static str) {
        match self {
            Error::BadRequest(_) => ("invalid-request", "Invalid request"),
            Error::Unauthorized => ("unauthorized", "Authentication needed"),
            Error::Forbidden(_) => ("forbidden", "Not allowed"),
            Error::NotFound => ("not-found", "Not found"),
            Error::MethodNotAllowed => ("method-not-allowed", "Method not allowed"),
            Error::AccountDeactivated => ("account-deactivated", "Account deactivated"),
            Error::HandleTaken => ("handle-taken", "Handle taken"),
            Error::Duplicate(_) => ("duplicate", "Duplicate"),
            Error::TooLarge => ("payload-too-large", "Request too large"),
            Error::UnsupportedMedia => ("unsupported-media-type", "Unsupported media type"),
            Error::Invalid(_) => ("validation-failed", "Validation failed"),
            Error::UnsupportedFormat(_) => ("unsupported-format", "Unsupported format"),
            Error::Challenge(_) => ("challenge-failed", "Challenge failed"),
            Error::Quota(_) => ("quota-exceeded", "Quota exceeded"),
            Error::RateLimited(_) => ("rate-limited", "Too many requests"),
            Error::Timeout => ("timeout", "Took too long"),
            Error::Internal => ("internal", "Internal error"),
        }
    }

    /// The `detail` member of the problem document: one sentence for the client.
    pub fn detail(&self) -> String {
        match self {
            Error::BadRequest(d)
            | Error::Forbidden(d)
            | Error::Challenge(d)
            | Error::Quota(d)
            | Error::UnsupportedFormat(d) => d.clone(),
            Error::Unauthorized => {
                "Sign in: send a valid access token as `Authorization: Bearer <token>`.".to_owned()
            }
            Error::AccountDeactivated => "This account is deactivated.".to_owned(),
            Error::Duplicate(existing) => {
                format!("The Den already has this exact document as {existing}.")
            }
            Error::NotFound => "There is nothing here.".to_owned(),
            Error::MethodNotAllowed => "This path doesn't take that method.".to_owned(),
            Error::HandleTaken => "That handle is already taken.".to_owned(),
            Error::TooLarge => format!(
                "The request body is larger than {} KB.",
                crate::app::MAX_BODY / 1024
            ),
            Error::UnsupportedMedia => "Send `Content-Type: application/json`.".to_owned(),
            Error::Invalid(v) => format!("{} problem(s) found, see `errors`.", v.len()),
            Error::RateLimited(wait) => format!("Try again in {} seconds.", retry_after(*wait)),
            Error::Timeout => "The request took too long.".to_owned(),
            Error::Internal => "Something went wrong on the server.".to_owned(),
        }
    }

    /// The problem document. `origin` is the Den's public origin.
    pub fn problem(&self, origin: &str) -> Value {
        let (name, title) = self.name();
        let mut doc = json!({
            "type": format!("{origin}/problems/{name}"),
            "title": title,
            "status": self.status().as_u16(),
            "detail": self.detail(),
        });
        if let Some(map) = doc.as_object_mut() {
            match self {
                Error::Invalid(violations) => {
                    map.insert("errors".to_owned(), json!(violations));
                }
                Error::Duplicate(existing) => {
                    map.insert("existing".to_owned(), json!(existing));
                }
                _ => {}
            }
        }
        doc
    }
}

fn retry_after(wait: Duration) -> u64 {
    wait.as_secs() + u64::from(wait.subsec_nanos() > 0)
}

impl From<sqlx::Error> for Error {
    fn from(e: sqlx::Error) -> Self {
        tracing::error!(error = %e, "database error");
        Error::Internal
    }
}

/// Rides on an error response until the outer layer, which knows the public origin, writes the body.
#[derive(Clone)]
pub struct Pending(pub Error);

impl IntoResponse for Error {
    fn into_response(self) -> Response {
        let mut response = self.status().into_response();
        // `WWW-Authenticate` of a 401 names the public address, so the outer layer adds it.
        if let Error::RateLimited(wait) = &self {
            response.headers_mut().insert(
                header::RETRY_AFTER,
                HeaderValue::from(retry_after(*wait).max(1)),
            );
        }
        response.extensions_mut().insert(Pending(self));
        response
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn every_error_maps_to_one_status_and_problem_name() {
        let cases = [
            (Error::BadRequest("x".into()), 400, "invalid-request"),
            (Error::Unauthorized, 401, "unauthorized"),
            (Error::Forbidden("x".into()), 403, "forbidden"),
            (Error::Quota("x".into()), 403, "quota-exceeded"),
            (Error::NotFound, 404, "not-found"),
            (Error::MethodNotAllowed, 405, "method-not-allowed"),
            (Error::HandleTaken, 409, "handle-taken"),
            (Error::Duplicate("a/b".into()), 409, "duplicate"),
            (Error::AccountDeactivated, 403, "account-deactivated"),
            (
                Error::UnsupportedFormat("x".into()),
                422,
                "unsupported-format",
            ),
            (Error::TooLarge, 413, "payload-too-large"),
            (Error::UnsupportedMedia, 415, "unsupported-media-type"),
            (Error::invalid("/a", "x"), 422, "validation-failed"),
            (Error::Challenge("x".into()), 422, "challenge-failed"),
            (
                Error::RateLimited(Duration::from_secs(1)),
                429,
                "rate-limited",
            ),
            (Error::Internal, 500, "internal"),
            (Error::Timeout, 503, "timeout"),
        ];
        for (error, status, name) in cases {
            assert_eq!(error.status().as_u16(), status, "{name}");
            let doc = error.problem("https://den.test");
            assert_eq!(doc["type"], format!("https://den.test/problems/{name}"));
            assert_eq!(doc["status"], status);
        }
    }

    #[test]
    fn retry_after_rounds_up_and_is_at_least_one() {
        let response = Error::RateLimited(Duration::from_millis(1500)).into_response();
        assert_eq!(response.headers()[header::RETRY_AFTER], "2");
        let response = Error::RateLimited(Duration::ZERO).into_response();
        assert_eq!(response.headers()[header::RETRY_AFTER], "1");
    }

    #[test]
    fn a_duplicate_names_the_existing_item() {
        let doc = Error::Duplicate("a-b-c/x".into()).problem("https://den.test");
        assert_eq!(doc["existing"], "a-b-c/x");
        assert!(doc["detail"].as_str().unwrap().contains("a-b-c/x"));
    }

    #[test]
    fn validation_problems_list_their_pointers() {
        let doc = Error::invalid("/name", "too short").problem("https://den.test");
        assert_eq!(doc["errors"][0]["pointer"], "/name");
    }
}
