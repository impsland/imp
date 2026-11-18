//! The Streamable HTTP transport: every message is a POST of one JSON-RPC message to one address.
//! The server answers with one JSON message or with an event stream that carries the answer. The
//! session id the server gives after `initialize` goes back on every later request, and a DELETE
//! with it ends the session. What the headers and bodies mean is decided in `protocol`.

use super::auth;
use super::client::{McpError, McpSecrets, McpSignIn};
use super::protocol::{self, Incoming};
use futures_util::StreamExt;
use reqwest::header::{CONTENT_TYPE, HeaderMap, HeaderName, HeaderValue};
use serde_json::Value;
use std::rc::Rc;
use std::sync::Mutex;
use std::time::Duration;

pub(super) struct Http {
    client: reqwest::Client,
    url: String,
    /// Valid headers, built once. Their values are marked sensitive so they never show in logs.
    headers: HeaderMap,
    state: Mutex<State>,
    auth: Option<Rc<dyn McpSignIn>>,
}

/// What the server and the client agreed on so far.
#[derive(Default)]
struct State {
    session: Option<String>,
    protocol: Option<String>,
}

impl Http {
    pub(super) fn new(
        url: &str,
        headers: &McpSecrets,
        auth: Option<Rc<dyn McpSignIn>>,
    ) -> Result<Self, McpError> {
        let mut map = HeaderMap::new();
        for (name, value) in &headers.0 {
            let invalid = || McpError::Network(format!("the header {name} is not valid"));
            let mut value = HeaderValue::from_str(value).map_err(|_| invalid())?;
            value.set_sensitive(true);
            map.insert(
                HeaderName::from_bytes(name.as_bytes()).map_err(|_| invalid())?,
                value,
            );
        }
        let client = reqwest::Client::builder()
            .connect_timeout(Duration::from_secs(15))
            .build()
            .map_err(|e| McpError::Network(e.without_url().to_string()))?;
        Ok(Self {
            client,
            url: url.to_string(),
            headers: map,
            state: Mutex::new(State::default()),
            auth,
        })
    }

    pub(super) fn set_protocol(&self, version: &str) {
        if let Ok(mut state) = self.state.lock() {
            state.protocol = Some(version.to_string());
        }
    }

    fn remembered(&self) -> (Option<String>, Option<String>) {
        self.state
            .lock()
            .map(|s| (s.session.clone(), s.protocol.clone()))
            .unwrap_or_default()
    }

    /// Adds the configured headers and the protocol's headers to a request.
    fn with_headers(
        &self,
        request: reqwest::RequestBuilder,
        pairs: &[(String, String)],
    ) -> reqwest::RequestBuilder {
        let mut request = request.headers(self.headers.clone());
        for (name, value) in pairs {
            if let (Ok(name), Ok(value)) = (
                HeaderName::from_bytes(name.as_bytes()),
                HeaderValue::from_str(value),
            ) {
                request = request.header(name, value);
            }
        }
        request
    }

    /// The access token for the next request, from the sign-in the client was given.
    async fn token(&self, force_refresh: bool) -> Result<Option<String>, McpError> {
        match &self.auth {
            Some(auth) => auth.token(&self.url, force_refresh).await,
            None => Ok(None),
        }
    }

    /// Ends the session with a DELETE, as the Streamable HTTP transport says. Without a session
    /// there is nothing to end.
    pub(super) async fn end(&self) -> Result<(), McpError> {
        let (session, version) = self.remembered();
        let Some(pairs) = protocol::end_headers(session.as_deref(), version.as_deref()) else {
            return Ok(());
        };
        self.with_headers(self.client.delete(&self.url), &pairs)
            .send()
            .await
            .map_err(|e| McpError::Network(e.without_url().to_string()))?;
        if let Ok(mut state) = self.state.lock() {
            state.session = None;
        }
        Ok(())
    }

    /// Posts `message`. With `wait_for` set, returns the result of the answer with that id. Without
    /// it (a notification or a reply) the body is not read.
    pub(super) async fn post(
        &self,
        message: &Value,
        wait_for: Option<u64>,
    ) -> Result<Value, McpError> {
        let mut forced = false;
        let response = loop {
            let (session, version) = self.remembered();
            let pairs = protocol::post_headers(session.as_deref(), version.as_deref());
            let mut request = self
                .with_headers(self.client.post(&self.url), &pairs)
                .body(message.to_string());
            if let Some(token) = self.token(forced).await? {
                let mut value = HeaderValue::from_str(&format!("Bearer {token}"))
                    .map_err(|_| McpError::Network("the access token is not valid".into()))?;
                value.set_sensitive(true);
                request = request.header(reqwest::header::AUTHORIZATION, value);
            }
            let response = request
                .send()
                .await
                .map_err(|e| McpError::Network(e.without_url().to_string()))?;
            let status = response.status().as_u16();
            if status == 401 || status == 403 {
                let challenge = response
                    .headers()
                    .get_all(reqwest::header::WWW_AUTHENTICATE)
                    .iter()
                    .filter_map(|v| v.to_str().ok())
                    .find_map(auth::parse_challenge);
                if status == 403 && challenge.as_ref().is_none_or(|c| !c.insufficient_scope) {
                    return Err(McpError::Status(status));
                }
                // One retry with a refreshed token, when there is a sign-in to refresh from.
                if self.auth.is_some() && !forced && status == 401 {
                    forced = true;
                    continue;
                }
                let c = challenge.unwrap_or_default();
                return Err(McpError::Unauthorized {
                    resource_metadata: c.resource_metadata,
                    scope: c.scope,
                    insufficient_scope: c.insufficient_scope,
                });
            }
            break response;
        };
        if let Some(id) = response
            .headers()
            .get(protocol::SESSION_HEADER)
            .and_then(|v| v.to_str().ok())
            && let Ok(mut state) = self.state.lock()
        {
            state.session = Some(id.to_string());
        }
        let status = response.status().as_u16();
        if !protocol::reply_is_accepted(status) {
            return Err(McpError::Status(status));
        }
        let Some(wait_for) = wait_for else {
            return Ok(Value::Null);
        };
        let content_type = response
            .headers()
            .get(CONTENT_TYPE)
            .and_then(|v| v.to_str().ok())
            .unwrap_or_default()
            .to_string();
        if protocol::reply_is_stream(&content_type) {
            self.read_stream(response, wait_for).await
        } else {
            let body = response
                .bytes()
                .await
                .map_err(|e| McpError::Network(e.without_url().to_string()))?;
            let messages =
                protocol::reply_messages(&content_type, &body).map_err(McpError::Server)?;
            self.find_answer(&messages, wait_for)
                .await
                .unwrap_or(Err(McpError::Closed))
        }
    }

    /// Reads events until the answer to `wait_for` arrives.
    async fn read_stream(
        &self,
        response: reqwest::Response,
        wait_for: u64,
    ) -> Result<Value, McpError> {
        let mut bytes = response.bytes_stream();
        let mut events = protocol::EventStream::default();
        while let Some(chunk) = bytes.next().await {
            let chunk = chunk.map_err(|e| McpError::Network(e.without_url().to_string()))?;
            let messages = events.push(&String::from_utf8_lossy(&chunk));
            if let Some(done) = self.find_answer(&messages, wait_for).await {
                return done;
            }
        }
        if let Some(done) = self.find_answer(&events.finish(), wait_for).await {
            return done;
        }
        Err(McpError::Closed)
    }

    /// Looks through messages from the server. Requests from it get a plain refusal, notifications
    /// are skipped, and the answer to `wait_for` ends the search.
    async fn find_answer(
        &self,
        messages: &[Value],
        wait_for: u64,
    ) -> Option<Result<Value, McpError>> {
        for message in messages {
            match protocol::classify(message) {
                Incoming::Request { reply } => {
                    // A failed refusal does not change the answer we wait for.
                    let _ = Box::pin(self.post(&reply, None)).await;
                }
                Incoming::Answer { id, result } if id == wait_for => {
                    return Some(result.map_err(|e| McpError::Server(e.message)));
                }
                Incoming::Answer { .. } | Incoming::Skip => {}
            }
        }
        None
    }
}
