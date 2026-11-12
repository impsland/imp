//! The web gallery: a few files built into the binary.

use std::sync::Arc;

use axum::Router;
use axum::extract::Path;
use axum::http::header::{CACHE_CONTROL, CONTENT_SECURITY_POLICY, CONTENT_TYPE};
use axum::http::{HeaderValue, StatusCode};
use axum::response::{IntoResponse, Response};
use axum::routing::get;

use crate::den::Den;
use crate::error::Error;

const HTML_CSP: &str = "default-src 'none'; script-src 'self'; style-src 'self'; img-src 'self' data:; connect-src 'self'; \
                        base-uri 'none'; form-action 'none'; frame-ancestors 'none'";
const IMAGE_CSP: &str = "default-src 'none'; style-src 'unsafe-inline'; sandbox";

static INDEX: &[u8] = include_bytes!("../web/index.html");
static APP_JS: &[u8] = include_bytes!("../web/assets/app.js");
static IMP_JS: &[u8] = include_bytes!("../web/assets/imp.js");
static SITE_CSS: &[u8] = include_bytes!("../web/assets/site.css");
static FAVICON_PNG: &[u8] = include_bytes!("../web/assets/favicon-32.png");
static ICON_PNG: &[u8] = include_bytes!("../web/assets/imp-icon.png");

pub fn routes() -> Router<Arc<Den>> {
    Router::new()
        .route("/", get(index))
        .route("/i/{handle}/{slug}", get(index))
        .route("/a/{handle}", get(index))
        .route("/assets/{file}", get(asset))
}

fn file(
    bytes: &'static [u8],
    content_type: &'static str,
    cache: &'static str,
    csp: &'static str,
) -> Response {
    let mut response = (StatusCode::OK, bytes).into_response();
    let headers = response.headers_mut();
    headers.insert(CONTENT_TYPE, HeaderValue::from_static(content_type));
    headers.insert(CACHE_CONTROL, HeaderValue::from_static(cache));
    headers.insert(CONTENT_SECURITY_POLICY, HeaderValue::from_static(csp));
    response
}

async fn index() -> Response {
    file(INDEX, "text/html; charset=utf-8", "no-cache", HTML_CSP)
}

async fn asset(Path(name): Path<String>) -> Result<Response, Error> {
    const CACHE: &str = "public, max-age=300";
    match name.as_str() {
        "app.js" => Ok(file(
            APP_JS,
            "text/javascript; charset=utf-8",
            CACHE,
            HTML_CSP,
        )),
        "imp.js" => Ok(file(
            IMP_JS,
            "text/javascript; charset=utf-8",
            CACHE,
            HTML_CSP,
        )),
        "site.css" => Ok(file(SITE_CSS, "text/css; charset=utf-8", CACHE, HTML_CSP)),
        "favicon-32.png" => Ok(file(FAVICON_PNG, "image/png", CACHE, IMAGE_CSP)),
        "imp-icon.png" => Ok(file(ICON_PNG, "image/png", CACHE, IMAGE_CSP)),
        _ => Err(Error::NotFound),
    }
}
