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

/// The schema of a type argument: one of the item types. The Den checks the value itself, so a wrong
/// one answers with a problem document that names the field.
fn kind_schema(_: &mut schemars::SchemaGenerator) -> schemars::Schema {
    let kinds: Vec<&str> = Kind::ALL.iter().map(|k| k.as_str()).collect();
    schemars::json_schema!({ "type": "string", "enum": kinds })
}

fn sort_schema(_: &mut schemars::SchemaGenerator) -> schemars::Schema {
    schemars::json_schema!({ "type": "string", "enum": ["new", "popular", "name"] })
}

fn limit_schema(_: &mut schemars::SchemaGenerator) -> schemars::Schema {
    schemars::json_schema!({ "type": "integer", "minimum": 1, "maximum": 50 })
}

fn document_schema(_: &mut schemars::SchemaGenerator) -> schemars::Schema {
    schemars::json_schema!({ "type": "object" })
}

#[derive(Debug, Default, Deserialize, JsonSchema)]
pub struct ListQuery {
    /// Only items of this type.
    #[serde(rename = "type", default, skip_serializing_if = "Option::is_none")]
    #[schemars(schema_with = "kind_schema")]
    pub kind: Option<String>,
    /// A single tag, for example `fun`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    #[schemars(schema_with = "tag_schema")]
    pub tag: Option<String>,
    /// The account that shared it, for example `moody-moves-fan`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    #[schemars(schema_with = "handle_schema")]
    pub handle: Option<String>,
    /// Words to look for, at most 100 characters. Every word must appear in the name, summary, about
    /// text or tags. Case-insensitive.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    #[schemars(schema_with = "q_schema")]
    pub q: Option<String>,
    /// The order: newest first (default), most installed first, or by name.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    #[schemars(schema_with = "sort_schema")]
    pub sort: Option<String>,
    /// How many items, 1 to 50 (default 20).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    #[schemars(schema_with = "limit_schema")]
    pub limit: Option<u32>,
    /// The `next_cursor` of the previous page, with the same filters and sort.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    #[schemars(schema_with = "text_schema")]
    pub cursor: Option<String>,
}

fn text_schema(_: &mut schemars::SchemaGenerator) -> schemars::Schema {
    schemars::json_schema!({ "type": "string" })
}

fn q_schema(_: &mut schemars::SchemaGenerator) -> schemars::Schema {
    schemars::json_schema!({ "type": "string", "maxLength": 100 })
}

fn tag_schema(_: &mut schemars::SchemaGenerator) -> schemars::Schema {
    schemars::json_schema!({ "type": "string", "pattern": "^[a-z0-9-]{1,24}$" })
}

fn handle_schema(_: &mut schemars::SchemaGenerator) -> schemars::Schema {
    schemars::json_schema!({ "type": "string", "pattern": "^[a-z0-9]+(-[a-z0-9]+)*$", "minLength": 3, "maxLength": 32 })
}

#[derive(Debug, Deserialize, JsonSchema)]
pub struct PublishItem {
    /// What the document is. It must hold what the type says (see document_format).
    #[serde(rename = "type")]
    #[schemars(schema_with = "kind_schema")]
    pub kind: String,
    /// The item's name under your handle: lowercase letters, digits and inner dashes. Publishing to a
    /// slug you already have updates that item.
    #[schemars(length(min = 1, max = 48), pattern(r"^[a-z0-9]+(-[a-z0-9]+)*$"))]
    pub slug: String,
    /// One line that says what the item is.
    #[schemars(length(min = 1, max = 120))]
    pub summary: String,
    /// 1 to 5 different tags.
    #[schemars(length(min = 1, max = 5), inner(pattern(r"^[a-z0-9-]{1,24}$")))]
    pub tags: Vec<String>,
    /// The item as a JSON object with `"format": 1` and a `name`: what Imp's imp_export_kit gives, or
    /// one written by the rules document_format returns.
    #[schemars(schema_with = "document_schema")]
    pub document: Value,
}

#[derive(Debug, Default, Deserialize, JsonSchema)]
pub struct FormatQuery {
    /// Only the rules and the example for this type. Leave it out for every type.
    #[serde(rename = "type", default, skip_serializing_if = "Option::is_none")]
    #[schemars(schema_with = "kind_schema")]
    pub kind: Option<String>,
}

#[derive(Clone, Copy, PartialEq, Eq)]
pub(super) enum Sort {
    New,
    Popular,
    Name,
}
