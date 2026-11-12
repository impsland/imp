//! The Den's wire types and list query.

use super::*;

#[derive(Debug, Serialize)]
pub struct Created {
    pub handle: String,
    pub token: String,
    pub created_at: String,
}

#[derive(Debug, Clone, Serialize)]
pub struct ItemSummary {
    #[serde(skip)]
    pub(super) id: i64,
    pub handle: String,
    pub slug: String,
    pub kind: String,
    pub name: String,
    pub summary: String,
    pub tags: Vec<String>,
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
    pub kit_url: String,
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

#[derive(Debug, Serialize)]
pub struct Stats {
    pub accounts: i64,
    pub items: i64,
    pub installs: i64,
    pub by_kind: ByKind,
}

/// Visible items of each kind.
#[derive(Debug, Default, Serialize)]
pub struct ByKind {
    pub imp: i64,
    pub animation: i64,
    pub trigger: i64,
    pub tool: i64,
    pub kit: i64,
}

/// A kit as kept, with the validators clients cache it by.
#[derive(Debug)]
pub struct KitDoc {
    pub text: String,
    pub etag: String,
}

#[derive(Debug, Default, Deserialize, JsonSchema)]
pub struct ListQuery {
    /// One of `imp`, `animation`, `trigger`, `tool`, `kit`.
    pub kind: Option<String>,
    /// A single tag, for example `fun`.
    pub tag: Option<String>,
    /// Words to look for in the name, summary and about text. Case-insensitive.
    pub q: Option<String>,
    /// `new` (default) or `popular`.
    pub sort: Option<String>,
    /// How many items, 1 to 50 (default 20).
    pub limit: Option<u32>,
    /// The `next_cursor` of the previous page.
    pub cursor: Option<String>,
}

#[derive(Debug, Deserialize, JsonSchema)]
pub struct PutItem {
    /// One line of at most 120 characters.
    pub summary: String,
    /// 1 to 5 tags of lowercase letters, digits and dashes, up to 24 characters each.
    pub tags: Vec<String>,
    /// The kit: the JSON Imp exports, with a `name`.
    pub kit: Value,
}

#[derive(Clone, Copy, PartialEq, Eq)]
pub(super) enum Sort {
    New,
    Popular,
}
