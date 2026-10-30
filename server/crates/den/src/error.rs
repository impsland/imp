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
    HandleTaken,
    TooLarge,
    UnsupportedMedia,
    Invalid(Vec<Violation>),
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
            Error::Forbidden(_) | Error::Quota(_) => StatusCode::FORBIDDEN,
            Error::NotFound => StatusCode::NOT_FOUND,
            Error::MethodNotAllowed => StatusCode::METHOD_NOT_ALLOWED,
            Error::HandleTaken => StatusCode::CONFLICT,
            Error::TooLarge => StatusCode::PAYLOAD_TOO_LARGE,
            Error::UnsupportedMedia => StatusCode::UNSUPPORTED_MEDIA_TYPE,
            Error::Invalid(_) | Error::Challenge(_) => StatusCode::UNPROCESSABLE_ENTITY,
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
            Error::HandleTaken => ("handle-taken", "Handle taken"),
            Error::TooLarge => ("payload-too-large", "Request too large"),
            Error::UnsupportedMedia => ("unsupported-media-type", "Unsupported media type"),
            Error::Invalid(_) => ("validation-failed", "Validation failed"),
            Error::Challenge(_) => ("challenge-failed", "Challenge failed"),
            Error::Quota(_) => ("quota-exceeded", "Quota exceeded"),
            Error::RateLimited(_) => ("rate-limited", "Too many requests"),
            Error::Timeout => ("timeout", "Took too long"),
            Error::Internal => ("internal", "Internal error"),
        }
    }

    pub fn detail(&self) -> String {
        match self {
            Error::BadRequest(d) | Error::Forbidden(d) | Error::Challenge(d) | Error::Quota(d) => {
                d.clone()
            }
            Error::Unauthorized => {
                "Send the account token as `Authorization: Bearer <token>`.".to_owned()
            }
            Error::NotFound => "There is nothing here.".to_owned(),
            Error::MethodNotAllowed => "This path doesn't take that method.".to_owned(),
            Error::HandleTaken => "That handle is already taken.".to_owned(),
            Error::TooLarge => "The request body is larger than 600 KB.".to_owned(),
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
            "type": format!("{origin}/v1/problems/{name}"),
            "title": title,
            "status": self.status().as_u16(),
            "detail": self.detail(),
        });
        if let (Error::Invalid(violations), Some(map)) = (self, doc.as_object_mut()) {
            map.insert("errors".to_owned(), json!(violations));
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
        match &self {
            Error::RateLimited(wait) => {
                response.headers_mut().insert(
                    header::RETRY_AFTER,
                    HeaderValue::from(retry_after(*wait).max(1)),
                );
            }
            Error::Unauthorized => {
                response
                    .headers_mut()
                    .insert(header::WWW_AUTHENTICATE, HeaderValue::from_static("Bearer"));
            }
            _ => {}
        }
        response.extensions_mut().insert(Pending(self));
        response
    }
}
