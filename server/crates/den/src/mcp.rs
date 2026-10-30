//! The MCP server at `/v1/mcp`: the same operations as the REST API, as tools.

use std::borrow::Cow;
use std::sync::Arc;

use axum::http::request::Parts;
use rmcp::handler::server::tool::Extension;
use rmcp::handler::server::wrapper::Parameters;
use rmcp::model::{CallToolResult, ProtocolVersion, ServerCapabilities, ServerConfig};
use rmcp::transport::streamable_http_server::session::never::NeverSessionManager;
use rmcp::transport::streamable_http_server::{StreamableHttpServerConfig, StreamableHttpService};
use rmcp::{ServerHandler, tool, tool_handler, tool_router};
use schemars::JsonSchema;
use serde::{Deserialize, Serialize};

use crate::den::{Den, ListQuery, PutItem};
use crate::error::Error;
use crate::extract::caller_of;

const INSTRUCTIONS: &str = "The Imp Den shares kits for Imp, the desktop pet: whole Imps, animations, triggers and tools. \
Search with search_items, read with get_item and get_kit. To publish you need an account: call get_challenge, solve it, \
call create_account, then pass the returned token to your MCP client as `Authorization: Bearer <token>` and call publish_item.";

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
struct NewAccount {
    /// 3 to 32 characters: lowercase letters, digits and inner dashes.
    handle: String,
    /// The solved challenge as base64 of the JSON `{"challenge": <the challenge>, "solution": {"counter": n, "derivedKey": "<hex>"}}`.
    altcha: String,
}

#[derive(Deserialize, JsonSchema)]
struct Publish {
    /// Your account handle.
    handle: String,
    /// A name for this item under your handle: lowercase letters, digits and inner dashes, up to 48 characters.
    slug: String,
    #[serde(flatten)]
    item: PutItem,
}

#[derive(Serialize)]
struct Solving<'a> {
    challenge: &'a altcha::Challenge,
    how_to_solve: &'static str,
}

const HOW_TO_SOLVE: &str = "For counter = 0, 1, 2, ... compute key = PBKDF2-HMAC-SHA256(password = hex-decoded nonce followed by \
the counter as 4 bytes big-endian, salt = hex-decoded salt, iterations = cost, output length = keyLength bytes) until the \
lowercase hex of key starts with keyPrefix. Then give create_account the base64 of the JSON \
{\"challenge\": <this challenge object>, \"solution\": {\"counter\": <counter>, \"derivedKey\": \"<hex of key>\"}}. \
A challenge works once and expires at expiresAt.";

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
        description = "Search the Imp Den for shared kits (Imps, animations, triggers, tools). All filters are optional. \
                       Returns a page of item summaries and a next_cursor to pass back for the next page.",
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
        description = "Get one item's details: name, about text, summary, tags, kind, whether it runs programs, installs, \
                       revision and what it contains. Use get_kit for the kit itself.",
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
        description = "Get the kit JSON of an item, exactly what Imp downloads and imports. Items with runs_programs set \
                       start programs on the user's Mac when added, so tell the user before installing one.",
        annotations(read_only_hint = true)
    )]
    async fn get_kit(
        &self,
        Extension(parts): Extension<Parts>,
        Parameters(item): Parameters<ItemRef>,
    ) -> Result<CallToolResult, CallToolResult> {
        let doc = self
            .den
            .kit(&caller_of(&parts), &item.handle, &item.slug)
            .await
            .map_err(|e| self.failed(&e))?;
        let kit = serde_json::from_str::<serde_json::Value>(&doc.text)
            .map_err(|_| self.failed(&Error::Internal))?;
        self.done(&kit)
    }

    #[tool(
        description = "Get a proof-of-work challenge, the first step to creating an account without sign-up. It works once and \
                       expires in 10 minutes. The result says how to solve it.",
        annotations(read_only_hint = true)
    )]
    async fn get_challenge(
        &self,
        Extension(parts): Extension<Parts>,
    ) -> Result<CallToolResult, CallToolResult> {
        let challenge = self
            .den
            .challenge(&caller_of(&parts))
            .map_err(|e| self.failed(&e))?;
        self.done(&Solving {
            challenge: &challenge,
            how_to_solve: HOW_TO_SOLVE,
        })
    }

    #[tool(
        description = "Create an account from a solved challenge. Returns the account token, shown only once. Give it to \
                       your MCP client as `Authorization: Bearer <token>` to publish and delete."
    )]
    async fn create_account(
        &self,
        Extension(parts): Extension<Parts>,
        Parameters(account): Parameters<NewAccount>,
    ) -> Result<CallToolResult, CallToolResult> {
        self.outcome(
            self.den
                .create_account(&caller_of(&parts), &account.handle, &account.altcha)
                .await,
        )
    }

    #[tool(
        description = "Publish a kit, or update it (the revision goes up by one). Needs the account token in the \
                       Authorization header. The kit is checked with Imp's own limits and must hold no secrets: \
                       environment and header values of tools must be empty.",
        annotations(destructive_hint = false, idempotent_hint = true)
    )]
    async fn publish_item(
        &self,
        Extension(parts): Extension<Parts>,
        Parameters(publish): Parameters<Publish>,
    ) -> Result<CallToolResult, CallToolResult> {
        let result = self
            .den
            .put_item(
                &caller_of(&parts),
                &publish.handle,
                &publish.slug,
                publish.item,
            )
            .await;
        self.outcome(result.map(|(_, item)| item))
    }

    #[tool(
        description = "Delete one of your items. Needs the account token in the Authorization header.",
        annotations(destructive_hint = true, idempotent_hint = true)
    )]
    async fn delete_item(
        &self,
        Extension(parts): Extension<Parts>,
        Parameters(item): Parameters<ItemRef>,
    ) -> Result<CallToolResult, CallToolResult> {
        let result = self
            .den
            .delete_item(&caller_of(&parts), &item.handle, &item.slug)
            .await;
        self.outcome(result.map(|()| serde_json::json!({ "deleted": true })))
    }
}

#[tool_handler]
impl ServerHandler for ImpMcp {
    fn get_info(&self) -> ServerConfig {
        ServerConfig::new(ServerCapabilities::builder().enable_tools().build())
            .with_instructions(INSTRUCTIONS)
    }

    fn supported_protocol_versions(&self) -> Cow<'static, [ProtocolVersion]> {
        Cow::Borrowed(&[ProtocolVersion::V_2026_07_28])
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
        .with_max_request_body_bytes(600 * 1024);
    StreamableHttpService::new(
        move || Ok(ImpMcp::new(Arc::clone(&den))),
        Arc::new(NeverSessionManager::default()),
        config,
    )
}
