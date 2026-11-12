//! Request extractors that fail with problem documents.

use std::net::{IpAddr, Ipv4Addr};

use axum::body::Bytes;
use axum::extract::{FromRequest, FromRequestParts, Request};
use axum::http::header::{AUTHORIZATION, CONTENT_TYPE};
use axum::http::request::Parts;
use axum::http::{HeaderMap, StatusCode};
use imp_shared::ip::IpKey;
use serde::de::DeserializeOwned;

use crate::den::Caller;
use crate::error::Error;

/// Who the request really comes from, worked out once per request (see `DEN_TRUSTED_PROXIES`).
#[derive(Debug, Clone, Copy)]
pub struct ClientIp(pub IpKey);

/// The token of an `Authorization: Bearer` header.
pub fn bearer(headers: &HeaderMap) -> Option<String> {
    let value = headers.get(AUTHORIZATION)?.to_str().ok()?;
    let (scheme, token) = value.split_once(' ')?;
    (scheme.eq_ignore_ascii_case("bearer") && token.len() <= 200).then(|| token.trim().to_owned())
}

pub fn caller_of(parts: &Parts) -> Caller {
    let ip = parts
        .extensions
        .get::<ClientIp>()
        .map_or_else(|| IpKey::from(IpAddr::V4(Ipv4Addr::UNSPECIFIED)), |c| c.0);
    Caller {
        ip,
        token: bearer(&parts.headers),
    }
}

impl<S: Send + Sync> FromRequestParts<S> for Caller {
    type Rejection = Error;

    async fn from_request_parts(parts: &mut Parts, _: &S) -> Result<Self, Error> {
        Ok(caller_of(parts))
    }
}

/// A JSON request body.
pub struct Json<T>(pub T);

impl<S: Send + Sync, T: DeserializeOwned> FromRequest<S> for Json<T> {
    type Rejection = Error;

    async fn from_request(req: Request, state: &S) -> Result<Self, Error> {
        let media = req
            .headers()
            .get(CONTENT_TYPE)
            .and_then(|v| v.to_str().ok())
            .and_then(|v| v.split(';').next())
            .map(|v| v.trim().to_ascii_lowercase());
        if !media.is_some_and(|m| m == "application/json" || m.ends_with("+json")) {
            return Err(Error::UnsupportedMedia);
        }
        let bytes = Bytes::from_request(req, state).await.map_err(|rejection| {
            if rejection.status() == StatusCode::PAYLOAD_TOO_LARGE {
                Error::TooLarge
            } else {
                Error::BadRequest("The body couldn't be read.".to_owned())
            }
        })?;
        serde_json::from_slice(&bytes)
            .map(Json)
            .map_err(|e| Error::BadRequest(format!("The body isn't valid for this request: {e}.")))
    }
}

/// A query string.
pub struct Query<T>(pub T);

impl<S: Send + Sync, T: DeserializeOwned + Send> FromRequestParts<S> for Query<T> {
    type Rejection = Error;

    async fn from_request_parts(parts: &mut Parts, state: &S) -> Result<Self, Error> {
        axum::extract::Query::<T>::from_request_parts(parts, state)
            .await
            .map(|q| Query(q.0))
            .map_err(|e| Error::BadRequest(e.body_text()))
    }
}

/// Path segments.
pub struct Path<T>(pub T);

impl<S: Send + Sync, T: DeserializeOwned + Send> FromRequestParts<S> for Path<T> {
    type Rejection = Error;

    async fn from_request_parts(parts: &mut Parts, state: &S) -> Result<Self, Error> {
        axum::extract::Path::<T>::from_request_parts(parts, state)
            .await
            .map(|p| Path(p.0))
            .map_err(|_| Error::BadRequest("The path isn't valid.".to_owned()))
    }
}
