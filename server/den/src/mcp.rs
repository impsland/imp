//! The MCP server at `/mcp`: search, read and download for anyone, publish and delete with an account.
//! Stateless Streamable HTTP. A write without a valid access token gets an HTTP 401 that starts the
//! MCP host's sign-in (see `guard`).

use std::borrow::Cow;
use std::sync::Arc;

use axum::body::Body;
use axum::extract::{Request, State};
use axum::http::Method;
use axum::http::request::Parts;
use axum::middleware::Next;
use axum::response::{IntoResponse, Response};
use rmcp::handler::server::tool::Extension;
use rmcp::handler::server::wrapper::Parameters;
use rmcp::model::{
    CallToolResult, Implementation, ProtocolVersion, ServerCapabilities, ServerConfig,
};
use rmcp::transport::streamable_http_server::session::never::NeverSessionManager;
use rmcp::transport::streamable_http_server::{StreamableHttpServerConfig, StreamableHttpService};
use rmcp::{ServerHandler, tool, tool_handler, tool_router};
use schemars::JsonSchema;
use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::den::{Den, ListQuery, PublishItem};
use crate::error::Error;
use crate::extract::caller_of;

/// The MCP revisions the Den speaks, newest first.
pub const PROTOCOL_VERSIONS: [&str; 3] = ["2026-07-28", "2025-11-25", "2025-06-18"];

static SUPPORTED: [ProtocolVersion; 3] = [
    ProtocolVersion::V_2026_07_28,
    ProtocolVersion::V_2025_11_25,
    ProtocolVersion::V_2025_06_18,
];

/// The tools that need an account.
const WRITE_TOOLS: [&str; 4] = [
    "publish_item",
    "delete_item",
    "my_account",
    "delete_account",
];

const INSTRUCTIONS: &str = "The Imp Den shares items for Imp, the desktop pet: whole Imps (imp), animations, triggers, tools and \
bundles of them (kit). Every item is a small JSON document with `\"format\": 1`. Search with search_items, read with get_item, \
and fetch the document with download_item, then give it to Imp's imp_add_kit (nothing is added until the person confirms). \
Items with runs_programs set start programs or ask for skills to be installed, so tell the person first. To publish you need \
an account; the first call of publish_item makes your MCP client open a sign-in page for the person. Export with \
imp_export_kit, then call publish_item with a type, a slug, a one-line summary, 1 to 5 tags and the document.";

#[derive(Clone)]
pub struct ImpMcp {
    den: Arc<Den>,
}

#[derive(Deserialize, JsonSchema)]
struct ItemRef {
    /// The account handle, such as `moody-moves-fan`.
    handle: String,
    /// The item's slug under that handle.
    slug: String,
}

#[derive(Deserialize, JsonSchema)]
struct DeleteArgs {
    /// The slug of one of your items.
    slug: String,
    /// Your own handle. Optional. Naming another account's handle is refused.
    handle: Option<String>,
}

#[derive(Deserialize, JsonSchema)]
struct Confirm {
    /// Your handle, to confirm that the account and everything it shared should go.
    confirm: String,
}

impl ImpMcp {
    fn new(den: Arc<Den>) -> Self {
        Self { den }
    }

    fn done<T: Serialize>(&self, value: &T) -> Result<CallToolResult, CallToolResult> {
        match serde_json::to_value(value) {
            Ok(v) if v.is_object() => Ok(CallToolResult::structured(v)),
            Ok(_) | Err(_) => Err(self.failed(&Error::Internal)),
        }
    }

    fn failed(&self, error: &Error) -> CallToolResult {
        CallToolResult::structured_error(error.problem(&self.den.config.public.origin))
    }

    fn outcome<T: Serialize>(
        &self,
        result: Result<T, Error>,
    ) -> Result<CallToolResult, CallToolResult> {
        match result {
            Ok(value) => self.done(&value),
            Err(error) => Err(self.failed(&error)),
        }
    }
}

#[tool_router]
impl ImpMcp {
    #[tool(
        description = "Search the Imp Den for shared items: Imps, animations, triggers, tools and kits. All filters are \
                       optional. Returns a page of item summaries and a next_cursor to pass back for the next page.",
        annotations(read_only_hint = true)
    )]
    async fn search_items(
        &self,
        Extension(parts): Extension<Parts>,
        Parameters(query): Parameters<ListQuery>,
    ) -> Result<CallToolResult, CallToolResult> {
        let list = self
            .den
            .list(&caller_of(&parts), query)
            .await
            .map_err(|e| self.failed(&e))?;
        self.done(&*list)
    }

    #[tool(
        description = "Get one item's details: name, about text, summary, tags, type, format, whether it runs programs, \
                       installs, revision, what it contains and its address. Use download_item for the document itself.",
        annotations(read_only_hint = true)
    )]
    async fn get_item(
        &self,
        Extension(parts): Extension<Parts>,
        Parameters(item): Parameters<ItemRef>,
    ) -> Result<CallToolResult, CallToolResult> {
        self.outcome(
            self.den
                .item(&caller_of(&parts), &item.handle, &item.slug)
                .await,
        )
    }

    #[tool(
        description = "Download an item: its summary and its document, ready to give to Imp's imp_add_kit. Counts one \
                       install. Items with runs_programs set start programs or install skills, so tell the person first.",
        annotations(
            read_only_hint = false,
            destructive_hint = false,
            idempotent_hint = false
        )
    )]
    async fn download_item(
        &self,
        Extension(parts): Extension<Parts>,
        Parameters(item): Parameters<ItemRef>,
    ) -> Result<CallToolResult, CallToolResult> {
        self.outcome(
            self.den
                .download(&caller_of(&parts), &item.handle, &item.slug)
                .await,
        )
    }

    #[tool(
        description = "Publish an item under your handle, or update it (the revision goes up by one). Needs an account: \
                       the person signs in when asked. The type (imp, animation, trigger, tool or kit) must match the \
                       document, which has `format: 1` and a name, and holds no secrets (env and header values stay \
                       empty). The Den refuses a document it already has.",
        annotations(destructive_hint = false, idempotent_hint = true)
    )]
    async fn publish_item(
        &self,
        Extension(parts): Extension<Parts>,
        Parameters(publish): Parameters<PublishItem>,
    ) -> Result<CallToolResult, CallToolResult> {
        let result = self.den.publish(&caller_of(&parts), publish).await;
        self.outcome(result.map(|published| published.item().clone()))
    }

    #[tool(
        description = "Delete one of your items by its slug. Needs an account.",
        annotations(destructive_hint = true, idempotent_hint = true)
    )]
    async fn delete_item(
        &self,
        Extension(parts): Extension<Parts>,
        Parameters(item): Parameters<DeleteArgs>,
    ) -> Result<CallToolResult, CallToolResult> {
        let result = self
            .den
            .delete_item(&caller_of(&parts), item.handle.as_deref(), &item.slug)
            .await;
        self.outcome(result.map(|()| serde_json::json!({ "deleted": true })))
    }

    #[tool(
        description = "Show your account: handle, when it was made, everything you shared, and what is left of your quota. \
                       Needs an account.",
        annotations(read_only_hint = true)
    )]
    async fn my_account(
        &self,
        Extension(parts): Extension<Parts>,
    ) -> Result<CallToolResult, CallToolResult> {
        self.outcome(self.den.my_account(&caller_of(&parts)).await)
    }

    #[tool(
        description = "Delete your account, everything it shared and every sign-in. Needs an account. `confirm` must be your handle.",
        annotations(destructive_hint = true, idempotent_hint = true)
    )]
    async fn delete_account(
        &self,
        Extension(parts): Extension<Parts>,
        Parameters(confirm): Parameters<Confirm>,
    ) -> Result<CallToolResult, CallToolResult> {
        let result = self
            .den
            .delete_account(&caller_of(&parts), &confirm.confirm)
            .await;
        self.outcome(result.map(|()| serde_json::json!({ "deleted": true })))
    }
}

#[tool_handler]
impl ServerHandler for ImpMcp {
    fn get_info(&self) -> ServerConfig {
        ServerConfig::new(ServerCapabilities::builder().enable_tools().build())
            .with_server_info(Implementation::new("imp-den", env!("CARGO_PKG_VERSION")))
            .with_instructions(INSTRUCTIONS)
    }

    fn supported_protocol_versions(&self) -> Cow<'static, [ProtocolVersion]> {
        Cow::Borrowed(&SUPPORTED)
    }
}

/// The MCP endpoint: stateless, JSON answers, Host and Origin held to the Den's public address.
pub fn service(den: Arc<Den>) -> StreamableHttpService<ImpMcp, NeverSessionManager> {
    let public = &den.config.public;
    let mut hosts = vec![public.authority.clone()];
    if public.host != public.authority {
        hosts.push(public.host.clone());
    }
    let config = StreamableHttpServerConfig::default()
        .with_legacy_session_mode(false)
        .with_json_response(true)
        .with_sse_keep_alive(None)
        .with_allowed_hosts(hosts)
        .with_allowed_origins([public.origin.clone()])
        .enforce_origin_validation()
        .with_max_request_body_bytes(crate::app::MAX_BODY);
    StreamableHttpService::new(
        move || Ok(ImpMcp::new(Arc::clone(&den))),
        Arc::new(NeverSessionManager::default()),
        config,
    )
}

/// Whether a JSON-RPC body (one message or a batch) calls a tool that needs an account.
fn calls_a_write_tool(body: &[u8]) -> bool {
    let Ok(value) = serde_json::from_slice::<Value>(body) else {
        return false;
    };
    let one = |message: &Value| {
        message.get("method").and_then(Value::as_str) == Some("tools/call")
            && message
                .pointer("/params/name")
                .and_then(Value::as_str)
                .is_some_and(|name| WRITE_TOOLS.contains(&name))
    };
    match &value {
        Value::Array(batch) => batch.iter().any(one),
        other => one(other),
    }
}

/// Runs before the MCP service. A call of a tool that needs an account, without a valid access token,
/// is answered with HTTP 401 here, so that the MCP host starts its OAuth sign-in. The WWW-Authenticate
/// header comes from the outer layer, which knows the public address. Reads pass untouched.
pub async fn guard(State(den): State<Arc<Den>>, req: Request, next: Next) -> Response {
    if req.method() != Method::POST {
        return next.run(req).await;
    }
    let (parts, body) = req.into_parts();
    let Ok(bytes) = axum::body::to_bytes(body, crate::app::MAX_BODY).await else {
        return Error::TooLarge.into_response();
    };
    if calls_a_write_tool(&bytes)
        && let Err(error) = den.authenticate(&caller_of(&parts)).await
    {
        return error.into_response();
    }
    next.run(Request::from_parts(parts, Body::from(bytes)))
        .await
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_calls_of_account_tools_are_writes() {
        let call = |name: &str| {
            serde_json::json!({ "jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": { "name": name } })
                .to_string()
        };
        assert!(calls_a_write_tool(call("publish_item").as_bytes()));
        assert!(calls_a_write_tool(call("my_account").as_bytes()));
        assert!(!calls_a_write_tool(call("search_items").as_bytes()));
        assert!(!calls_a_write_tool(call("download_item").as_bytes()));
        let batch = format!("[{}, {}]", call("search_items"), call("delete_item"));
        assert!(calls_a_write_tool(batch.as_bytes()));
        assert!(!calls_a_write_tool(br#"{"method":"tools/list"}"#));
        assert!(!calls_a_write_tool(b"not json"));
    }
}
