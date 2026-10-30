//! `den admin`: the operator's commands, acting directly on the database. There is no HTTP admin
//! surface. A running Den shows changes once its 30-second caches turn over.

use std::process::ExitCode;

use sqlx::{Row, SqlitePool};

const USAGE: &str = "usage: den admin reported | hide <handle>/<slug> | unhide <handle>/<slug> | remove <handle>/<slug> | remove-account <handle> | backup <file>";

pub async fn run(path: &str, args: &[String]) -> ExitCode {
    match execute(path, args).await {
        Ok(message) => {
            println!("{message}");
            ExitCode::SUCCESS
        }
        Err(message) => {
            eprintln!("{message}");
            ExitCode::FAILURE
        }
    }
}

fn item_ref(arg: Option<&String>) -> Result<(&str, &str), String> {
    arg.and_then(|a| a.split_once('/'))
        .filter(|(h, s)| !h.is_empty() && !s.is_empty())
        .ok_or_else(|| USAGE.to_owned())
}

async fn execute(path: &str, args: &[String]) -> Result<String, String> {
    let command = args
        .first()
        .map(String::as_str)
        .ok_or_else(|| USAGE.to_owned())?;
    let pool = crate::db::open(path)
        .await
        .map_err(|e| format!("cannot open the database {path}: {e}"))?;
    let failed = |e: sqlx::Error| format!("database error: {e}");
    match command {
        "reported" => reported(&pool).await.map_err(failed),
        "hide" | "unhide" => {
            let (handle, slug) = item_ref(args.get(1))?;
            let hide = command == "hide";
            let mut tx = pool.begin().await.map_err(failed)?;
            let changed =
                sqlx::query("UPDATE items SET hidden = ?3 WHERE handle = ?1 AND slug = ?2")
                    .bind(handle)
                    .bind(slug)
                    .bind(hide)
                    .execute(&mut *tx)
                    .await
                    .map_err(failed)?;
            if !hide {
                sqlx::query("DELETE FROM reports WHERE item = (SELECT id FROM items WHERE handle = ?1 AND slug = ?2)")
                    .bind(handle)
                    .bind(slug)
                    .execute(&mut *tx)
                    .await
                    .map_err(failed)?;
            }
            tx.commit().await.map_err(failed)?;
            found(
                changed.rows_affected(),
                &format!("{command} {handle}/{slug}"),
            )
        }
        "remove" => {
            let (handle, slug) = item_ref(args.get(1))?;
            let gone = sqlx::query("DELETE FROM items WHERE handle = ?1 AND slug = ?2")
                .bind(handle)
                .bind(slug)
                .execute(&pool)
                .await
                .map_err(failed)?;
            found(gone.rows_affected(), &format!("removed {handle}/{slug}"))
        }
        "remove-account" => {
            let handle = args
                .get(1)
                .filter(|h| !h.is_empty())
                .ok_or_else(|| USAGE.to_owned())?;
            let gone = sqlx::query("DELETE FROM accounts WHERE handle = ?1")
                .bind(handle)
                .execute(&pool)
                .await
                .map_err(failed)?;
            found(
                gone.rows_affected(),
                &format!("removed account {handle} and everything it shared"),
            )
        }
        "backup" => {
            let to = args
                .get(1)
                .filter(|f| !f.is_empty())
                .ok_or_else(|| USAGE.to_owned())?;
            if std::path::Path::new(to).exists() {
                return Err(format!("{to} already exists"));
            }
            sqlx::query("VACUUM INTO ?1")
                .bind(to)
                .execute(&pool)
                .await
                .map_err(failed)?;
            Ok(format!("backed up to {to}"))
        }
        _ => Err(USAGE.to_owned()),
    }
}

fn found(rows: u64, done: &str) -> Result<String, String> {
    if rows == 0 {
        Err("nothing matches".to_owned())
    } else {
        Ok(format!("done: {done}"))
    }
}

async fn reported(pool: &SqlitePool) -> Result<String, sqlx::Error> {
    let rows = sqlx::query(
        "SELECT i.handle, i.slug, i.hidden, COUNT(r.id) AS reports, \
         (SELECT reason FROM reports WHERE item = i.id ORDER BY id DESC LIMIT 1) AS last_reason \
         FROM items i JOIN reports r ON r.item = i.id GROUP BY i.id ORDER BY reports DESC, i.id DESC",
    )
    .fetch_all(pool)
    .await?;
    if rows.is_empty() {
        return Ok("no reported items".to_owned());
    }
    let mut lines = Vec::new();
    for row in &rows {
        let hidden: bool = row.try_get("hidden")?;
        lines.push(format!(
            "{}/{}\t{} reports\t{}\t{}",
            row.try_get::<String, _>("handle")?,
            row.try_get::<String, _>("slug")?,
            row.try_get::<i64, _>("reports")?,
            if hidden { "hidden" } else { "visible" },
            row.try_get::<String, _>("last_reason")?
                .replace(['\n', '\r', '\t'], " "),
        ));
    }
    Ok(lines.join("\n"))
}
