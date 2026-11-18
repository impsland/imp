//! The OAuth 2.1 endpoints of the Den as its own authorization server: discovery documents (RFC 9728,
//! RFC 8414), dynamic registration (RFC 7591), the sign-in page, the token endpoint and revocation.
//!
//! The sign-in page is server-rendered HTML. Its only script solves an ALTCHA challenge with WebCrypto
//! in a Web Worker. It loads nothing from elsewhere, sets no cookie and keeps nothing in the browser.

use std::collections::HashMap;
use std::sync::Arc;

use axum::Router;
use axum::extract::rejection::FormRejection;
use axum::extract::{Form, State};
use axum::http::header::{
    CACHE_CONTROL, CONTENT_SECURITY_POLICY, CONTENT_TYPE, LOCATION, RETRY_AFTER,
};
use axum::http::{HeaderValue, StatusCode};
use axum::response::{IntoResponse, Response};
use axum::routing::{get, post};
use base64::Engine;
use base64::engine::general_purpose::STANDARD;
use serde_json::{Value, json};
use sha2::{Digest, Sha256};

use crate::den::{AuthRequest, Caller, Den, OAuthError, SCOPE};
use crate::error::Error;
use crate::extract::Json;
use crate::meta::percent_encode;

pub fn routes() -> Router<Arc<Den>> {
    Router::new()
        .route("/.well-known/oauth-protected-resource", get(resource))
        .route("/.well-known/oauth-protected-resource/mcp", get(resource))
        .route("/.well-known/oauth-authorization-server", get(server))
        .route("/oauth/register", post(register))
        .route("/oauth/authorize", get(authorize_page).post(authorize_post))
        .route("/oauth/token", post(token))
        .route("/oauth/revoke", post(revoke))
}

/// The value of `WWW-Authenticate` for a request that needs a sign-in.
pub fn challenge_header(origin: &str) -> String {
    format!(
        "Bearer resource_metadata=\"{origin}/.well-known/oauth-protected-resource/mcp\", scope=\"{}\"",
        SCOPE
    )
}

fn json_reply(status: StatusCode, body: &Value, cache: &'static str) -> Response {
    let mut response = (status, body.to_string()).into_response();
    let headers = response.headers_mut();
    headers.insert(CONTENT_TYPE, HeaderValue::from_static("application/json"));
    headers.insert(CACHE_CONTROL, HeaderValue::from_static(cache));
    response
}

async fn resource(State(den): State<Arc<Den>>) -> Response {
    let origin = &den.config.public.origin;
    json_reply(
        StatusCode::OK,
        &json!({
            "resource": format!("{origin}/mcp"),
            "authorization_servers": [origin],
            "scopes_supported": [SCOPE],
            "bearer_methods_supported": ["header"],
        }),
        "public, max-age=300",
    )
}

async fn server(State(den): State<Arc<Den>>) -> Response {
    let origin = &den.config.public.origin;
    json_reply(
        StatusCode::OK,
        &json!({
            "issuer": origin,
            "authorization_endpoint": format!("{origin}/oauth/authorize"),
            "token_endpoint": format!("{origin}/oauth/token"),
            "registration_endpoint": format!("{origin}/oauth/register"),
            "revocation_endpoint": format!("{origin}/oauth/revoke"),
            "response_types_supported": ["code"],
            "grant_types_supported": ["authorization_code", "refresh_token"],
            "code_challenge_methods_supported": ["S256"],
            "token_endpoint_auth_methods_supported": ["none"],
            "scopes_supported": [SCOPE],
        }),
        "public, max-age=300",
    )
}

/// An OAuth error as RFC 6749 writes it, or an ordinary Den problem.
fn oauth_failure(error: OAuthError) -> Response {
    match error {
        OAuthError::Den(e) => e.into_response(),
        OAuthError::Protocol { error, description } => json_reply(
            StatusCode::BAD_REQUEST,
            &json!({ "error": error, "error_description": description }),
            "no-store",
        ),
    }
}

async fn register(
    State(den): State<Arc<Den>>,
    caller: Caller,
    Json(body): Json<Value>,
) -> Response {
    match den.register_client(&caller, &body).await {
        Ok(client) => json_reply(
            StatusCode::CREATED,
            &serde_json::to_value(client).unwrap_or_default(),
            "no-store",
        ),
        Err(e) => oauth_failure(e),
    }
}

type Fields = HashMap<String, String>;

fn fields(form: Result<Form<Fields>, FormRejection>) -> Result<Fields, Error> {
    form.map(|f| f.0)
        .map_err(|_| Error::BadRequest("The form body couldn't be read.".to_owned()))
}

async fn token(
    State(den): State<Arc<Den>>,
    caller: Caller,
    form: Result<Form<Fields>, FormRejection>,
) -> Response {
    let form = match fields(form) {
        Ok(f) => f,
        Err(e) => return e.into_response(),
    };
    let get = |k: &str| form.get(k).map_or("", String::as_str);
    let result = match get("grant_type") {
        "authorization_code" => {
            den.exchange_code(
                &caller,
                get("client_id"),
                get("code"),
                get("redirect_uri"),
                get("code_verifier"),
            )
            .await
        }
        "refresh_token" => {
            den.refresh(&caller, get("client_id"), get("refresh_token"))
                .await
        }
        _ => Err(OAuthError::protocol(
            "unsupported_grant_type",
            "grant_type is authorization_code or refresh_token",
        )),
    };
    match result {
        Ok(tokens) => json_reply(
            StatusCode::OK,
            &serde_json::to_value(tokens).unwrap_or_default(),
            "no-store",
        ),
        Err(e) => oauth_failure(e),
    }
}

async fn revoke(
    State(den): State<Arc<Den>>,
    caller: Caller,
    form: Result<Form<Fields>, FormRejection>,
) -> Response {
    let form = match fields(form) {
        Ok(f) => f,
        Err(e) => return e.into_response(),
    };
    match den
        .revoke(&caller, form.get("token").map_or("", String::as_str))
        .await
    {
        Ok(()) => json_reply(StatusCode::OK, &json!({}), "no-store"),
        Err(e) => e.into_response(),
    }
}

// ---- The sign-in page ----

/// Checks the parameters of an authorization request. The error is shown on a page and nothing is
/// redirected, because the redirect address can't be trusted until it has matched a registration.
async fn check_request(den: &Den, p: &Fields) -> Result<AuthRequest, String> {
    let get = |k: &str| p.get(k).map_or("", String::as_str);
    let client = den
        .client(get("client_id"))
        .await
        .map_err(|_| "Something went wrong on the server.".to_owned())?
        .ok_or("This client isn't registered with the Den.")?;
    let redirect_uri = get("redirect_uri");
    if !client
        .redirect_uris
        .iter()
        .any(|r| crate::redirect::same(r, redirect_uri))
    {
        return Err("The return address isn't one this client registered.".to_owned());
    }
    if get("response_type") != "code" {
        return Err("response_type must be code.".to_owned());
    }
    if get("code_challenge_method") != "S256" {
        return Err("PKCE with code_challenge_method S256 is required.".to_owned());
    }
    let challenge = get("code_challenge");
    if challenge.len() != 43
        || !challenge
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_')
    {
        return Err("code_challenge must be an S256 challenge.".to_owned());
    }
    if p.get("scope")
        .is_some_and(|s| s.split(' ').any(|w| !w.is_empty() && w != SCOPE))
    {
        return Err(format!("The only scope is {}.", SCOPE));
    }
    let origin = &den.config.public.origin;
    if p.get("resource")
        .is_some_and(|r| !r.is_empty() && r != origin && *r != format!("{origin}/mcp"))
    {
        return Err("resource must be this Den's /mcp.".to_owned());
    }
    if get("state").len() > 2000 {
        return Err("state is too long.".to_owned());
    }
    Ok(AuthRequest {
        client,
        redirect_uri: redirect_uri.to_owned(),
        code_challenge: challenge.to_owned(),
        state: get("state").to_owned(),
    })
}

fn escape(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    for c in s.chars() {
        match c {
            '&' => out.push_str("&amp;"),
            '<' => out.push_str("&lt;"),
            '>' => out.push_str("&gt;"),
            '"' => out.push_str("&quot;"),
            '\'' => out.push_str("&#39;"),
            c => out.push(c),
        }
    }
    out
}

const STYLE: &str = "body{font:16px/1.5 system-ui,sans-serif;max-width:34rem;margin:2rem auto;padding:0 1rem;color:#222;background:#fafafa}\
h1{font-size:1.4rem}section{background:#fff;border:1px solid #ddd;border-radius:10px;padding:1rem;margin:1rem 0}\
input{font:inherit;width:100%;box-sizing:border-box;padding:.5rem;margin:.3rem 0 .8rem}button,.btn{font:inherit;padding:.5rem 1rem;cursor:pointer}\
.err{color:#a40000;font-weight:600}code{word-break:break-all;display:block;padding:.6rem;background:#f0f0f0;border-radius:6px}\
@media(prefers-color-scheme:dark){body{background:#181818;color:#eee}section{background:#222;border-color:#444}code{background:#333}.err{color:#ff8a8a}}";

/// Solves the challenge: the page's only script. The worker source rides in an inert script block.
const SCRIPT: &str = r#"(function(){
var form=document.getElementById('new');
if(!form||!window.Worker||!window.crypto||!crypto.subtle){var n=document.getElementById('status');if(n)n.textContent='This page needs a current browser to prove you are a person.';return;}
var status=document.getElementById('status');
form.addEventListener('submit',function(ev){
  if(form.elements.altcha.value){return;}
  ev.preventDefault();
  var button=form.querySelector('button');button.disabled=true;
  status.textContent='Checking that you are a person...';
  fetch('/challenge',{headers:{accept:'application/json'}}).then(function(r){if(!r.ok){throw new Error('challenge');}return r.json();}).then(function(challenge){
    var url=URL.createObjectURL(new Blob([document.getElementById('worker').textContent],{type:'text/javascript'}));
    var worker=new Worker(url);
    worker.onmessage=function(m){
      worker.terminate();URL.revokeObjectURL(url);
      form.elements.altcha.value=btoa(JSON.stringify({challenge:challenge,solution:m.data}));
      form.submit();
    };
    worker.onerror=function(){status.textContent='Could not solve the check. Reload and try again.';button.disabled=false;};
    worker.postMessage(challenge.parameters);
  }).catch(function(){status.textContent='Could not get a check from the Den. Try again.';button.disabled=false;});
});
})();"#;

const WORKER: &str = r#"onmessage=async function(e){
var p=e.data;
function bytes(h){var o=new Uint8Array(h.length/2);for(var i=0;i<o.length;i++){o[i]=parseInt(h.substr(i*2,2),16);}return o;}
var nonce=bytes(p.nonce),salt=bytes(p.salt),hash=p.algorithm.split('/')[1]||'SHA-256';
for(var c=0;;c++){
  var pw=new Uint8Array(nonce.length+4);pw.set(nonce);new DataView(pw.buffer).setUint32(nonce.length,c,false);
  var key=await crypto.subtle.importKey('raw',pw,'PBKDF2',false,['deriveBits']);
  var bits=await crypto.subtle.deriveBits({name:'PBKDF2',hash:hash,salt:salt,iterations:p.cost},key,p.keyLength*8);
  var hex=Array.prototype.map.call(new Uint8Array(bits),function(b){return b.toString(16).padStart(2,'0');}).join('');
  if(hex.indexOf(p.keyPrefix)===0){postMessage({counter:c,derivedKey:hex});return;}
}
};"#;

const COPY_SCRIPT: &str = r#"(function(){var b=document.getElementById('copy');if(!b||!navigator.clipboard){return;}
b.hidden=false;b.addEventListener('click',function(){navigator.clipboard.writeText(document.getElementById('key').textContent).then(function(){b.textContent='Copied';});});})();"#;

fn sha_source(text: &str) -> String {
    format!(
        "'sha256-{}'",
        STANDARD.encode(Sha256::digest(text.as_bytes()))
    )
}

fn hidden(p: &Fields) -> String {
    let mut out = String::new();
    for name in [
        "response_type",
        "client_id",
        "redirect_uri",
        "code_challenge",
        "code_challenge_method",
        "state",
        "scope",
        "resource",
    ] {
        if let Some(v) = p.get(name) {
            out.push_str(&format!(
                "<input type=\"hidden\" name=\"{name}\" value=\"{}\">",
                escape(v)
            ));
        }
    }
    out
}

fn redirect_host(uri: &str) -> String {
    uri.split_once(':')
        .map(|(scheme, rest)| {
            let rest = rest.trim_start_matches('/');
            if matches!(scheme, "http" | "https") {
                rest.split(['/', '?']).next().unwrap_or("").to_owned()
            } else {
                uri.to_owned()
            }
        })
        .unwrap_or_default()
}

/// A finished page with its Content-Security-Policy, which allows only the hashed inline script and style.
fn page(status: StatusCode, body: &str, scripts: &[&str]) -> Response {
    let mut sources: Vec<String> = scripts.iter().map(|s| sha_source(s)).collect();
    sources.insert(0, String::new());
    let csp = format!(
        "default-src 'none'; script-src{}; style-src {}; worker-src blob:; connect-src 'self'; base-uri 'none'; frame-ancestors 'none'",
        if scripts.is_empty() {
            " 'none'".to_owned()
        } else {
            sources.join(" ")
        },
        sha_source(STYLE),
    );
    let mut html = format!(
        "<!doctype html><html lang=\"en\"><head><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">\
         <meta name=\"color-scheme\" content=\"light dark\"><title>Sign in to the Imp Den</title><style>{STYLE}</style></head><body>{body}"
    );
    for s in scripts {
        if *s == WORKER {
            html.push_str(&format!(
                "<script type=\"text/plain\" id=\"worker\">{WORKER}</script>"
            ));
        } else {
            html.push_str(&format!("<script>{s}</script>"));
        }
    }
    html.push_str("</body></html>");
    let mut response = (status, html).into_response();
    let headers = response.headers_mut();
    headers.insert(
        CONTENT_TYPE,
        HeaderValue::from_static("text/html; charset=utf-8"),
    );
    if let Ok(v) = HeaderValue::from_str(&csp) {
        headers.insert(CONTENT_SECURITY_POLICY, v);
    }
    response
}

fn error_page(message: &str) -> Response {
    page(
        StatusCode::BAD_REQUEST,
        &format!(
            "<h1>This sign-in can't continue</h1><p class=\"err\">{}</p><p>Go back to the app that sent you here and try again.</p>",
            escape(message)
        ),
        &[],
    )
}

fn sign_in_page(request: &AuthRequest, p: &Fields, problem: Option<&str>) -> Response {
    let params = hidden(p);
    let message = problem.map_or_else(String::new, |m| {
        format!("<p class=\"err\" role=\"alert\">{}</p>", escape(m))
    });
    let body = format!(
        "<h1>Sign in to the Imp Den</h1>\
         <p><b>{name}</b> asks to share Imp items for you. Afterwards you go back to <b>{host}</b>.</p>{message}\
         <section><h2>New account</h2>\
         <form id=\"new\" method=\"post\" action=\"/oauth/authorize\">{params}\
         <input type=\"hidden\" name=\"mode\" value=\"new\"><input type=\"hidden\" name=\"altcha\" value=\"\">\
         <label for=\"handle\">Pick a handle (3 to 32 letters, digits and hyphens)</label>\
         <input id=\"handle\" name=\"handle\" required minlength=\"3\" maxlength=\"32\" pattern=\"[a-z0-9]([a-z0-9\\-]*[a-z0-9])?\" autocomplete=\"off\" autocapitalize=\"none\" spellcheck=\"false\">\
         <button type=\"submit\">Make my account</button> <span id=\"status\" role=\"status\"></span></form></section>\
         <section><h2>I have an account</h2>\
         <form method=\"post\" action=\"/oauth/authorize\">{params}<input type=\"hidden\" name=\"mode\" value=\"existing\">\
         <label for=\"key\">Account key (starts with dak_)</label>\
         <input id=\"key\" name=\"key\" required type=\"password\" autocomplete=\"off\" spellcheck=\"false\">\
         <button type=\"submit\">Continue</button></form></section>",
        name = escape(&request.client.client_name),
        host = escape(&redirect_host(&request.redirect_uri)),
    );
    page(
        problem.map_or(StatusCode::OK, |_| StatusCode::UNPROCESSABLE_ENTITY),
        &body,
        &[SCRIPT, WORKER],
    )
}

fn key_page(request: &AuthRequest, p: &Fields, handle: &str, key: &str) -> Response {
    let body = format!(
        "<h1>Your account {handle} is ready</h1>\
         <p>This is your account key. It is shown <b>once</b>. Keep it somewhere safe: you need it to connect another app to this account.</p>\
         <code id=\"key\">{key}</code><p><button id=\"copy\" type=\"button\" hidden>Copy the key</button></p>\
         <form method=\"post\" action=\"/oauth/authorize\">{params}<input type=\"hidden\" name=\"mode\" value=\"existing\">\
         <input type=\"hidden\" name=\"key\" value=\"{key}\"><button type=\"submit\">Continue to {name}</button></form>",
        handle = escape(handle),
        key = escape(key),
        params = hidden(p),
        name = escape(&request.client.client_name),
    );
    page(StatusCode::OK, &body, &[COPY_SCRIPT])
}

async fn authorize_page(
    State(den): State<Arc<Den>>,
    axum::extract::Query(p): axum::extract::Query<Fields>,
) -> Response {
    match check_request(&den, &p).await {
        Ok(request) => sign_in_page(&request, &p, None),
        Err(message) => error_page(&message),
    }
}

async fn authorize_post(
    State(den): State<Arc<Den>>,
    caller: Caller,
    form: Result<Form<Fields>, FormRejection>,
) -> Response {
    let p = match fields(form) {
        Ok(p) => p,
        Err(e) => return e.into_response(),
    };
    let request = match check_request(&den, &p).await {
        Ok(r) => r,
        Err(message) => return error_page(&message),
    };
    let get = |k: &str| p.get(k).map_or("", String::as_str);
    let outcome: Result<String, Error> = match get("mode") {
        "new" => match den
            .create_account(&caller, get("handle"), get("altcha"))
            .await
        {
            Ok(created) => {
                return key_page(&request, &p, &created.handle, &created.account_key);
            }
            Err(e) => Err(e),
        },
        "existing" => den.sign_in(&caller, get("key")).await,
        _ => Err(Error::BadRequest(
            "Choose New account or I have an account.".to_owned(),
        )),
    };
    let result = match outcome {
        Ok(handle) => den.issue_code(&request, &handle).await,
        Err(e) => Err(e),
    };
    match result {
        Ok(code) => {
            let sep = if request.redirect_uri.contains('?') {
                '&'
            } else {
                '?'
            };
            let mut target = format!(
                "{}{sep}code={}",
                request.redirect_uri,
                percent_encode(&code)
            );
            if !request.state.is_empty() {
                target.push_str(&format!("&state={}", percent_encode(&request.state)));
            }
            let mut response = StatusCode::SEE_OTHER.into_response();
            if let Ok(v) = HeaderValue::from_str(&target) {
                response.headers_mut().insert(LOCATION, v);
            }
            response
        }
        Err(e) => {
            let (_, title) = e.name();
            let detail = match &e {
                Error::Invalid(v) => v
                    .first()
                    .map_or_else(|| e.detail(), |x| format!("The handle {}.", x.detail)),
                other => other.detail(),
            };
            let mut response = sign_in_page(&request, &p, Some(&format!("{title}: {detail}")));
            *response.status_mut() = e.status();
            if let Error::RateLimited(wait) = &e {
                response
                    .headers_mut()
                    .insert(RETRY_AFTER, HeaderValue::from(wait.as_secs().max(1)));
            }
            response
        }
    }
}
