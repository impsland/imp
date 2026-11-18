//! The Den's wire types and list query.

use super::*;

/// An account just made, with its key. The key is shown once and kept only as a SHA-256.
#[derive(Debug, Serialize)]
pub struct Created {
    pub handle: String,
    pub account_key: String,
    pub created_at: String,
}

#[derive(Debug, Clone, Serialize)]
pub struct ItemSummary {
    #[serde(skip)]
    pub(super) id: i64,
    pub handle: String,
    pub slug: String,
    #[serde(rename = "type")]
    pub kind: String,
    pub name: String,
    pub summary: String,
    pub tags: Vec<String>,
    pub format: i64,
    pub runs_programs: bool,
    pub installs: i64,
    pub revision: i64,
    pub created_at: String,
    pub updated_at: String,
}

#[derive(Debug, Clone, Serialize)]
pub struct Item {
    #[serde(flatten)]
    pub summary: ItemSummary,
    pub about: String,
    pub sha256: String,
    pub size: i64,
    pub document_url: String,
    pub open_url: String,
    pub counts: Counts,
}

#[derive(Debug, Serialize)]
pub struct ItemList {
    pub items: Vec<ItemSummary>,
    pub next_cursor: Option<String>,
}

#[derive(Debug, Serialize)]
pub struct AccountView {
    pub handle: String,
    pub created_at: String,
    pub items: Vec<ItemSummary>,
}

/// What an account may still do.
#[derive(Debug, Serialize)]
pub struct Quota {
    pub items: i64,
    pub items_left: i64,
    pub bytes_left: i64,
    pub new_today_left: i64,
}

/// The signed-in account, as `my_account` shows it.
#[derive(Debug, Serialize)]
pub struct MyAccount {
    pub handle: String,
    pub created_at: String,
    pub items: Vec<ItemSummary>,
    pub quota: Quota,
}

#[derive(Debug, Serialize)]
pub struct Stats {
    pub accounts: i64,
    pub items: i64,
    pub installs: i64,
    pub by_type: ByType,
}

/// Visible items of each type.
#[derive(Debug, Default, Serialize)]
pub struct ByType {
    pub imp: i64,
    pub animation: i64,
    pub trigger: i64,
    pub tool: i64,
    pub kit: i64,
}

/// A document as kept, with the validator clients cache it by.
#[derive(Debug)]
pub struct StoredDocument {
    pub text: String,
    pub etag: String,
}

/// `download_item`: the summary and the document, ready to import.
#[derive(Debug, Serialize)]
pub struct Download {
    pub item: ItemSummary,
    pub document: Value,
}

/// How a publish ended.
#[derive(Debug)]
pub enum Published {
    Created(Item),
    Updated(Item),
    /// The same document again: nothing changed.
    Unchanged(Item),
}

impl Published {
    pub fn item(&self) -> &Item {
        match self {
            Published::Created(i) | Published::Updated(i) | Published::Unchanged(i) => i,
        }
    }
}

#[derive(Debug, Default, Deserialize, JsonSchema)]
pub struct ListQuery {
    /// One of `imp`, `animation`, `trigger`, `tool`, `kit`.
    #[serde(rename = "type")]
    pub kind: Option<String>,
    /// A single tag, for example `fun`.
    pub tag: Option<String>,
    /// The account that shared it, for example `moody-moves-fan`.
    pub handle: Option<String>,
    /// Words to look for in the name, summary, about text and tags. Case-insensitive.
    pub q: Option<String>,
    /// `new` (default), `popular` or `name`.
    pub sort: Option<String>,
    /// How many items, 1 to 50 (default 20).
    pub limit: Option<u32>,
    /// The `next_cursor` of the previous page.
    pub cursor: Option<String>,
}

#[derive(Debug, Deserialize, JsonSchema)]
pub struct PublishItem {
    /// One of `imp`, `animation`, `trigger`, `tool`, `kit`. The document must be what the type says.
    #[serde(rename = "type")]
    pub kind: String,
    /// A name for this item under your handle: lowercase letters, digits and inner dashes, up to 48 characters.
    pub slug: String,
    /// One line of at most 120 characters.
    pub summary: String,
    /// 1 to 5 tags of lowercase letters, digits and dashes, up to 24 characters each.
    pub tags: Vec<String>,
    /// The document: the JSON Imp exports, with `"format": 1` and a `name`.
    pub document: Value,
}

#[derive(Clone, Copy, PartialEq, Eq)]
pub(super) enum Sort {
    New,
    Popular,
    Name,
}
