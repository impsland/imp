//! The HTTP application: routes plus the layers every request and response passes through.

use std::net::{IpAddr, Ipv4Addr, SocketAddr};
use std::sync::Arc;
use std::time::{Duration, Instant};

use axum::Router;
use axum::body::Body;
use axum::extract::{ConnectInfo, DefaultBodyLimit, Request, State};
use axum::http::header::{
    CACHE_CONTROL, CONTENT_LENGTH, CONTENT_TYPE, ETAG, IF_NONE_MATCH, REFERRER_POLICY, RETRY_AFTER,
    X_CONTENT_TYPE_OPTIONS, X_FRAME_OPTIONS,
};
use axum::http::{HeaderName, HeaderValue, Method, StatusCode};
use axum::middleware::{self, Next};
use axum::response::{IntoResponse, Response};
use imp_shared::ip::IpKey;
use tower_http::cors::{Any, CorsLayer};

use crate::den::Den;
use crate::error::{Error, Pending};
use crate::extract::ClientIp;
use crate::{api, mcp, web};

const MAX_BODY: usize = 600 * 1024;
const REQUEST_TIMEOUT: Duration = Duration::from_secs(15);
static REQUEST_ID: HeaderName = HeaderName::from_static("x-request-id");

pub fn router(den: Arc<Den>) -> Router {
    let cors = CorsLayer::new()
        .allow_origin(Any)
        .allow_methods([Method::GET, Method::HEAD])
        .allow_headers([IF_NONE_MATCH, CONTENT_TYPE])
        .expose_headers([ETAG, RETRY_AFTER, REQUEST_ID.clone()])
        .max_age(Duration::from_secs(86_400));
    Router::new()
        .route("/healthz", axum::routing::get(healthz))
        .merge(api::routes())
        .merge(web::routes())
        .nest_service("/v1/mcp", mcp::service(Arc::clone(&den)))
        .fallback(|| async { Error::NotFound })
        .layer(DefaultBodyLimit::max(MAX_BODY))
        .layer(middleware::from_fn(timeout))
        .layer(cors)
        .layer(middleware::from_fn_with_state(Arc::clone(&den), finish))
        .layer(middleware::from_fn_with_state(Arc::clone(&den), identify))
        .with_state(den)
}

async fn healthz(State(den): State<Arc<Den>>) -> Result<&'static str, Error> {
    den.ping().await?;
    Ok("ok")
}

/// Works out the client's address key and keeps it with the request.
async fn identify(State(den): State<Arc<Den>>, mut req: Request, next: Next) -> Response {
    let ip = {
        let peer = req
            .extensions()
            .get::<ConnectInfo<SocketAddr>>()
            .map_or(IpAddr::V4(Ipv4Addr::UNSPECIFIED), |c| c.0.ip());
        let forwarded = req
            .headers()
            .get_all("x-forwarded-for")
            .iter()
            .filter_map(|v| v.to_str().ok());
        den.config.trusted_proxies.client_ip(peer, forwarded)
    };
    req.extensions_mut().insert(ClientIp(IpKey::from(ip)));
    next.run(req).await
}

async fn timeout(req: Request, next: Next) -> Response {
    match tokio::time::timeout(REQUEST_TIMEOUT, next.run(req)).await {
        Ok(response) => response,
        Err(_) => Error::Timeout.into_response(),
    }
}

/// The error a bare status stands for, when something other than our handlers produced it.
fn error_for(status: StatusCode) -> Error {
    match status {
        StatusCode::NOT_FOUND => Error::NotFound,
        StatusCode::METHOD_NOT_ALLOWED => Error::MethodNotAllowed,
        StatusCode::PAYLOAD_TOO_LARGE => Error::TooLarge,
        StatusCode::UNSUPPORTED_MEDIA_TYPE => Error::UnsupportedMedia,
        StatusCode::REQUEST_TIMEOUT
        | StatusCode::SERVICE_UNAVAILABLE
        | StatusCode::GATEWAY_TIMEOUT => Error::Timeout,
        s if s.is_server_error() => Error::Internal,
        _ => Error::BadRequest("The request couldn't be processed.".to_owned()),
    }
}

/// Outermost layer: request id, problem bodies, security and cache headers, and the access log.
async fn finish(State(den): State<Arc<Den>>, req: Request, next: Next) -> Response {
    let started = Instant::now();
    let id = hex::encode(rand::random::<[u8; 8]>());
    let method = req.method().clone();
    let path = req.uri().path().to_owned();
    let is_mcp = path.starts_with("/v1/mcp");
    let client = req
        .extensions()
        .get::<ClientIp>()
        .map_or_else(String::new, |c| c.0.log_tag());

    let mut response = next.run(req).await;

    let pending = response.extensions_mut().remove::<Pending>().map(|p| p.0);
    let bare = !is_mcp
        && (response.status().is_client_error() || response.status().is_server_error())
        && !response.headers().contains_key(CONTENT_TYPE);
    let error = pending.or_else(|| bare.then(|| error_for(response.status())));
    if let Some(error) = error {
        let (mut parts, _) = response.into_parts();
        parts.headers.remove(CONTENT_LENGTH);
        parts.headers.insert(
            CONTENT_TYPE,
            HeaderValue::from_static("application/problem+json"),
        );
        let body =
            serde_json::to_vec(&error.problem(&den.config.public.origin)).unwrap_or_default();
        response = Response::from_parts(parts, Body::from(body));
    }

    let status = response.status();
    let headers = response.headers_mut();
    if let Ok(value) = HeaderValue::from_str(&id) {
        headers.insert(REQUEST_ID.clone(), value);
    }
    headers.insert(X_CONTENT_TYPE_OPTIONS, HeaderValue::from_static("nosniff"));
    headers.insert(REFERRER_POLICY, HeaderValue::from_static("no-referrer"));
    headers.insert(X_FRAME_OPTIONS, HeaderValue::from_static("DENY"));
    if !headers.contains_key(CACHE_CONTROL)
        && !headers.contains_key(ETAG)
        && (path.starts_with("/v1/") || path == "/healthz")
    {
        headers.insert(CACHE_CONTROL, HeaderValue::from_static("no-store"));
    }

    let elapsed_ms = u64::try_from(started.elapsed().as_millis()).unwrap_or(u64::MAX);
    if path == "/healthz" || path.starts_with("/assets/") {
        tracing::debug!(%id, %method, %path, status = status.as_u16(), elapsed_ms, client, "request");
    } else {
        tracing::info!(%id, %method, %path, status = status.as_u16(), elapsed_ms, client, "request");
    }
    response
}
