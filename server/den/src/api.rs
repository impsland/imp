//! The REST routes of the Den API.

use std::sync::Arc;

use axum::Router;
use axum::extract::State;
use axum::http::header::{CACHE_CONTROL, CONTENT_TYPE, ETAG, IF_NONE_MATCH};
use axum::http::{HeaderMap, HeaderValue, StatusCode};
use axum::response::{IntoResponse, Response};
use axum::routing::{get, post};
use serde::{Deserialize, Serialize};

use crate::den::{Caller, Den, ListQuery};
use crate::error::Error;
use crate::extract::{Json, Path, Query};

const LISTS: &str = "public, max-age=30";
const DOCUMENTS: &str = "public, max-age=300";

pub fn routes() -> Router<Arc<Den>> {
    Router::new()
        .route("/version", get(version))
        .route("/challenge", get(challenge))
        .route("/accounts/{handle}", get(account))
        .route("/items", get(list))
        .route("/items/{handle}/{slug}", get(item))
        .route("/items/{handle}/{slug}/document.json", get(document))
        .route("/items/{handle}/{slug}/installs", post(install))
        .route("/items/{handle}/{slug}/reports", post(report))
        .route("/stats", get(stats))
}

fn reply<T: Serialize>(
    status: StatusCode,
    body: &T,
    cache: Option<&'static str>,
) -> Result<Response, Error> {
    let bytes = serde_json::to_vec(body).map_err(|_| Error::Internal)?;
    let mut response = (status, bytes).into_response();
    response
        .headers_mut()
        .insert(CONTENT_TYPE, HeaderValue::from_static("application/json"));
    if let Some(cache) = cache {
        response
            .headers_mut()
            .insert(CACHE_CONTROL, HeaderValue::from_static(cache));
    }
    Ok(response)
}

/// What this Den speaks, so clients can check before they rely on it.
async fn version() -> Result<Response, Error> {
    reply(
        StatusCode::OK,
        &serde_json::json!({
            "den": env!("CARGO_PKG_VERSION"),
            "api": 1,
            "formats": [crate::kit::MAX_FORMAT],
            "mcp": crate::mcp::PROTOCOL_VERSIONS,
        }),
        Some(LISTS),
    )
}

async fn challenge(State(den): State<Arc<Den>>, caller: Caller) -> Result<Response, Error> {
    reply(StatusCode::OK, &den.challenge(&caller)?, None)
}

async fn account(
    State(den): State<Arc<Den>>,
    caller: Caller,
    Path(handle): Path<String>,
) -> Result<Response, Error> {
    reply(
        StatusCode::OK,
        &den.account(&caller, &handle).await?,
        Some(LISTS),
    )
}

async fn list(
    State(den): State<Arc<Den>>,
    caller: Caller,
    Query(query): Query<ListQuery>,
) -> Result<Response, Error> {
    reply(
        StatusCode::OK,
        &*den.list(&caller, query).await?,
        Some(LISTS),
    )
}

async fn item(
    State(den): State<Arc<Den>>,
    caller: Caller,
    Path((handle, slug)): Path<(String, String)>,
) -> Result<Response, Error> {
    reply(
        StatusCode::OK,
        &den.item(&caller, &handle, &slug).await?,
        Some(LISTS),
    )
}

/// Whether `If-None-Match` lists `etag` (or `*`).
fn matches(headers: &HeaderMap, etag: &str) -> bool {
    headers
        .get(IF_NONE_MATCH)
        .and_then(|v| v.to_str().ok())
        .is_some_and(|v| {
            v.split(',')
                .map(str::trim)
                .any(|candidate| candidate == "*" || candidate.trim_start_matches("W/") == etag)
        })
}

async fn document(
    State(den): State<Arc<Den>>,
    caller: Caller,
    headers: HeaderMap,
    Path((handle, slug)): Path<(String, String)>,
) -> Result<Response, Error> {
    let doc = den.document(&caller, &handle, &slug).await?;
    let etag = HeaderValue::from_str(&doc.etag).map_err(|_| Error::Internal)?;
    let mut response = if matches(&headers, &doc.etag) {
        StatusCode::NOT_MODIFIED.into_response()
    } else {
        let mut ok = (StatusCode::OK, doc.text).into_response();
        ok.headers_mut()
            .insert(CONTENT_TYPE, HeaderValue::from_static("application/json"));
        ok
    };
    response.headers_mut().insert(ETAG, etag);
    response
        .headers_mut()
        .insert(CACHE_CONTROL, HeaderValue::from_static(DOCUMENTS));
    Ok(response)
}

async fn install(
    State(den): State<Arc<Den>>,
    caller: Caller,
    Path((handle, slug)): Path<(String, String)>,
) -> Result<StatusCode, Error> {
    den.install(&caller, &handle, &slug).await?;
    Ok(StatusCode::ACCEPTED)
}

#[derive(Deserialize)]
struct NewReport {
    reason: String,
}

async fn report(
    State(den): State<Arc<Den>>,
    caller: Caller,
    Path((handle, slug)): Path<(String, String)>,
    Json(body): Json<NewReport>,
) -> Result<StatusCode, Error> {
    den.report(&caller, &handle, &slug, &body.reason).await?;
    Ok(StatusCode::ACCEPTED)
}

async fn stats(State(den): State<Arc<Den>>, caller: Caller) -> Result<Response, Error> {
    reply(StatusCode::OK, &*den.stats(&caller).await?, Some(LISTS))
}
