//! The animation catalog: every animation in `spec/animations/catalog.json`, offered by the Den
//! as one shared item each under the reserved account `imp`. The apps bundle only the entries
//! marked `bundled`. The Den carries the whole list, so "Get more from the Den" finds the rest.

use serde_json::{Value, json};
use sqlx::{Row, SqlitePool};

use crate::crypto::sha256_hex;
use crate::kit;

/// The reserved handle the catalog is published under (nobody can register it).
pub const HANDLE: &str = "imp";

/// The catalog as the repository keeps it (the apps read the same file).
const CATALOG: &str = include_str!("../../../spec/animations/catalog.json");

/// One catalog animation as a Den item.
struct Entry {
    slug: String,
    summary: String,
    kit: Value,
}

/// `lookAround` becomes `look-around`, the form a slug takes.
fn slug_of(id: &str) -> String {
    let mut out = String::new();
    for c in id.chars() {
        if c.is_ascii_uppercase() {
            out.push('-');
        }
        out.push(c.to_ascii_lowercase());
    }
    out
}

fn entries() -> Result<Vec<Entry>, String> {
    let catalog: Value = serde_json::from_str(CATALOG).map_err(|e| e.to_string())?;
    let list = catalog["animations"]
        .as_array()
        .ok_or("the catalog has no animations")?;
    let mut out = Vec::new();
    for animation in list {
        let id = animation["id"].as_str().ok_or("an animation has no id")?;
        let name = animation["name"].as_str().unwrap_or(id);
        let about = animation["about"].as_str().unwrap_or_default();
        // What the kit holds: the animation as kits write it (no catalog-only keys). A bundled
        // one installs as a new version of the built-in animation it is.
        let mut shared = animation.clone();
        if let Some(object) = shared.as_object_mut() {
            object.remove("id");
            object.remove("bundled");
            if animation["bundled"].as_bool() == Some(true) {
                object.insert("replaces".to_owned(), json!(id));
            }
        }
        out.push(Entry {
            slug: slug_of(id),
            summary: about.chars().take(120).collect(),
            kit: json!({ "name": name, "about": about, "animations": [shared] }),
        });
    }
    Ok(out)
}

/// Writes the catalog into the database: the reserved account, and one item per animation.
/// Safe to run on every start: an item whose kit is unchanged is left alone (its install count,
/// its hidden flag), a changed one gets a new revision, one that is gone from the file stays.
/// Returns how many items were added or changed.
pub async fn seed(pool: &SqlitePool) -> Result<usize, String> {
    let entries = entries()?;
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |d| i64::try_from(d.as_secs()).unwrap_or(0));
    let mut tx = pool
        .begin_with("BEGIN IMMEDIATE")
        .await
        .map_err(|e| e.to_string())?;
    // Nobody holds the token of this account: its hash is of bytes nobody keeps.
    sqlx::query(
        "INSERT OR IGNORE INTO accounts (handle, token_hash, created_at) VALUES (?1, ?2, ?3)",
    )
    .bind(HANDLE)
    .bind(sha256_hex(&rand::random::<[u8; 32]>()))
    .bind(now)
    .execute(&mut *tx)
    .await
    .map_err(|e| e.to_string())?;
    let mut changed = 0;
    for entry in entries {
        let checked = kit::check(entry.kit).map_err(|v| {
            let found: Vec<String> = v
                .into_iter()
                .map(|x| format!("{} {}", x.pointer, x.detail))
                .collect();
            format!("{}: {}", entry.slug, found.join("; "))
        })?;
        let tags = serde_json::to_string(&["animation"]).map_err(|e| e.to_string())?;
        let counts = serde_json::to_string(&checked.counts).map_err(|e| e.to_string())?;
        let size = i64::try_from(checked.text.len()).unwrap_or(i64::MAX);
        let existing = sqlx::query("SELECT id, sha256 FROM items WHERE handle = ?1 AND slug = ?2")
            .bind(HANDLE)
            .bind(&entry.slug)
            .fetch_optional(&mut *tx)
            .await
            .map_err(|e| e.to_string())?;
        match existing {
            Some(row) => {
                let same = row
                    .try_get::<String, _>("sha256")
                    .is_ok_and(|s| s == checked.sha256);
                if same {
                    continue;
                }
                let id: i64 = row.try_get("id").map_err(|e| e.to_string())?;
                sqlx::query(
                    "UPDATE items SET kind = ?1, name = ?2, about = ?3, summary = ?4, tags = ?5, kit = ?6, counts = ?7, \
                     sha256 = ?8, size = ?9, revision = revision + 1, runs_programs = 0, updated_at = ?10 WHERE id = ?11",
                )
                .bind(checked.kind.as_str())
                .bind(&checked.name)
                .bind(&checked.about)
                .bind(&entry.summary)
                .bind(&tags)
                .bind(&checked.text)
                .bind(&counts)
                .bind(&checked.sha256)
                .bind(size)
                .bind(now)
                .bind(id)
                .execute(&mut *tx)
                .await
                .map_err(|e| e.to_string())?;
            }
            None => {
                sqlx::query(
                    "INSERT INTO items (handle, slug, kind, name, about, summary, tags, kit, counts, sha256, size, revision, \
                     runs_programs, created_at, updated_at) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, 1, 0, ?12, ?12)",
                )
                .bind(HANDLE)
                .bind(&entry.slug)
                .bind(checked.kind.as_str())
                .bind(&checked.name)
                .bind(&checked.about)
                .bind(&entry.summary)
                .bind(&tags)
                .bind(&checked.text)
                .bind(&counts)
                .bind(&checked.sha256)
                .bind(size)
                .bind(now)
                .execute(&mut *tx)
                .await
                .map_err(|e| e.to_string())?;
            }
        }
        changed += 1;
    }
    tx.commit().await.map_err(|e| e.to_string())?;
    Ok(changed)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn catalog() -> Value {
        serde_json::from_str(CATALOG).unwrap()
    }

    #[test]
    fn slugs() {
        assert_eq!(slug_of("jump"), "jump");
        assert_eq!(slug_of("lookAround"), "look-around");
        assert_eq!(slug_of("areYouSure"), "are-you-sure");
    }

    #[test]
    fn every_entry_is_a_valid_item() {
        let all = entries().unwrap();
        assert_eq!(all.len(), catalog()["animations"].as_array().unwrap().len());
        let mut slugs = std::collections::HashSet::new();
        for e in &all {
            assert!(crate::meta::slug_problem(&e.slug).is_none(), "{}", e.slug);
            assert!(slugs.insert(e.slug.clone()), "{} twice", e.slug);
            assert!(!e.summary.is_empty() && !e.summary.contains('\n'));
            assert!(kit::check(e.kit.clone()).is_ok(), "{}", e.slug);
        }
    }

    #[test]
    fn exactly_five_are_bundled() {
        let bundled = catalog()["animations"]
            .as_array()
            .unwrap()
            .iter()
            .filter(|a| a["bundled"] == json!(true))
            .count();
        assert_eq!(bundled, 5);
    }

    #[tokio::test]
    async fn seeding_adds_everything_once() {
        let path = std::env::temp_dir().join(format!(
            "den-catalog-{}.sqlite",
            hex::encode(rand::random::<[u8; 8]>())
        ));
        let name = path.to_string_lossy().into_owned();
        let pool = crate::db::open(&name).await.unwrap();
        let total = entries().unwrap().len();

        assert_eq!(seed(&pool).await.unwrap(), total);
        assert_eq!(
            seed(&pool).await.unwrap(),
            0,
            "the second start changes nothing"
        );
        let count: i64 = sqlx::query_scalar(
            "SELECT COUNT(*) FROM items WHERE handle = ?1 AND kind = 'animation'",
        )
        .bind(HANDLE)
        .fetch_one(&pool)
        .await
        .unwrap();
        assert_eq!(usize::try_from(count).unwrap(), total);

        // A changed kit is updated in place. Installs and the hidden flag stay.
        sqlx::query(
            "UPDATE items SET sha256 = 'old', installs = 7, hidden = 1 WHERE slug = 'jump'",
        )
        .execute(&pool)
        .await
        .unwrap();
        assert_eq!(seed(&pool).await.unwrap(), 1);
        let row = sqlx::query("SELECT revision, installs, hidden FROM items WHERE slug = 'jump'")
            .fetch_one(&pool)
            .await
            .unwrap();
        assert_eq!(row.get::<i64, _>("revision"), 2);
        assert_eq!(row.get::<i64, _>("installs"), 7);
        assert_eq!(row.get::<i64, _>("hidden"), 1);
        for suffix in ["", "-wal", "-shm"] {
            let mut p = path.clone().into_os_string();
            p.push(suffix);
            let _ = std::fs::remove_file(p);
        }
    }
}
