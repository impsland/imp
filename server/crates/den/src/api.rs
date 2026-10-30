//! The REST routes of Den API v1.

use std::sync::Arc;

use axum::Router;
use axum::extract::State;
use axum::http::header::{CACHE_CONTROL, CONTENT_TYPE, ETAG, IF_NONE_MATCH, LOCATION};
use axum::http::{HeaderMap, HeaderValue, StatusCode};
use axum::response::{IntoResponse, Response};
use axum::routing::{delete, get, post};
use serde::{Deserialize, Serialize};

use crate::den::{Caller, Den, ListQuery, PutItem};
use crate::error::Error;
use crate::extract::{Json, Path, Query};

const LISTS: &str = "public, max-age=30";
const KITS: &str = "public, max-age=300";

pub fn routes() -> Router<Arc<Den>> {
    Router::new()
        .route("/v1/challenge", get(challenge))
        .route("/v1/accounts", post(create_account))
        .route("/v1/accounts/me", delete(delete_account))
        .route("/v1/accounts/{handle}", get(account))
        .route("/v1/items", get(list))
        .route(
            "/v1/items/{handle}/{slug}",
            get(item).put(put_item).delete(delete_item),
        )
        .route("/v1/items/{handle}/{slug}/kit.json", get(kit))
        .route("/v1/items/{handle}/{slug}/installs", post(install))
        .route("/v1/items/{handle}/{slug}/reports", post(report))
        .route("/v1/stats", get(stats))
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

async fn challenge(State(den): State<Arc<Den>>, caller: Caller) -> Result<Response, Error> {
    reply(StatusCode::OK, &den.challenge(&caller)?, None)
}

#[derive(Deserialize)]
struct NewAccount {
    handle: String,
    altcha: String,
}

async fn create_account(
    State(den): State<Arc<Den>>,
    caller: Caller,
    Json(body): Json<NewAccount>,
) -> Result<Response, Error> {
    reply(
        StatusCode::CREATED,
        &den.create_account(&caller, &body.handle, &body.altcha)
            .await?,
        None,
    )
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

async fn delete_account(State(den): State<Arc<Den>>, caller: Caller) -> Result<StatusCode, Error> {
    den.delete_account(&caller).await?;
    Ok(StatusCode::NO_CONTENT)
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

async fn put_item(
    State(den): State<Arc<Den>>,
    caller: Caller,
    Path((handle, slug)): Path<(String, String)>,
    Json(body): Json<PutItem>,
) -> Result<Response, Error> {
    let (created, item) = den.put_item(&caller, &handle, &slug, body).await?;
    let mut response = reply(
        if created {
            StatusCode::CREATED
        } else {
            StatusCode::OK
        },
        &item,
        None,
    )?;
    if created && let Ok(location) = HeaderValue::from_str(&format!("/v1/items/{handle}/{slug}")) {
        response.headers_mut().insert(LOCATION, location);
    }
    Ok(response)
}

async fn delete_item(
    State(den): State<Arc<Den>>,
    caller: Caller,
    Path((handle, slug)): Path<(String, String)>,
) -> Result<StatusCode, Error> {
    den.delete_item(&caller, &handle, &slug).await?;
    Ok(StatusCode::NO_CONTENT)
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

async fn kit(
    State(den): State<Arc<Den>>,
    caller: Caller,
    headers: HeaderMap,
    Path((handle, slug)): Path<(String, String)>,
) -> Result<Response, Error> {
    let doc = den.kit(&caller, &handle, &slug).await?;
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
        .insert(CACHE_CONTROL, HeaderValue::from_static(KITS));
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
