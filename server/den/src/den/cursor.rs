//! List paging cursors: opaque, bound to a sort order.

use super::*;

/// Where the previous page ended.
#[derive(Debug, PartialEq, Eq)]
pub(super) enum Cursor {
    New { id: i64 },
    Popular { installs: i64, id: i64 },
    Name { name: String, id: i64 },
}

pub(super) fn encode_cursor(sort: Sort, last: &ItemSummary) -> String {
    let plain = match sort {
        Sort::New => format!("n.{}", last.id),
        Sort::Popular => format!("p.{}.{}", last.installs, last.id),
        Sort::Name => format!("a.{}.{}", URL_SAFE_NO_PAD.encode(&last.name), last.id),
    };
    URL_SAFE_NO_PAD.encode(plain)
}

pub(super) fn decode_cursor(cursor: &str, sort: Sort) -> Result<Cursor, Error> {
    let invalid = || bad("`cursor` is not one this server gave out for this sort order.");
    let plain = URL_SAFE_NO_PAD
        .decode(cursor)
        .ok()
        .and_then(|b| String::from_utf8(b).ok())
        .ok_or_else(invalid)?;
    let parts: Vec<&str> = plain.split('.').collect();
    let number = |s: &str| s.parse::<i64>().ok().filter(|n| *n >= 0);
    match (sort, parts.as_slice()) {
        (Sort::New, ["n", id]) => Ok(Cursor::New {
            id: number(id).ok_or_else(invalid)?,
        }),
        (Sort::Popular, ["p", installs, id]) => Ok(Cursor::Popular {
            installs: number(installs).ok_or_else(invalid)?,
            id: number(id).ok_or_else(invalid)?,
        }),
        (Sort::Name, ["a", name, id]) => Ok(Cursor::Name {
            name: URL_SAFE_NO_PAD
                .decode(name)
                .ok()
                .and_then(|b| String::from_utf8(b).ok())
                .ok_or_else(invalid)?,
            id: number(id).ok_or_else(invalid)?,
        }),
        _ => Err(invalid()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn last(name: &str, installs: i64, id: i64) -> ItemSummary {
        ItemSummary {
            id,
            handle: "a-b-c".into(),
            slug: "x".into(),
            kind: "tool".into(),
            name: name.into(),
            summary: "s".into(),
            tags: vec![],
            format: 1,
            runs_programs: false,
            installs,
            revision: 1,
            created_at: String::new(),
            updated_at: String::new(),
        }
    }

    #[test]
    fn cursors_round_trip_per_sort() {
        let item = last("Pip. The/Imp", 7, 42);
        let new = encode_cursor(Sort::New, &item);
        assert_eq!(
            decode_cursor(&new, Sort::New).unwrap(),
            Cursor::New { id: 42 }
        );
        let popular = encode_cursor(Sort::Popular, &item);
        assert_eq!(
            decode_cursor(&popular, Sort::Popular).unwrap(),
            Cursor::Popular {
                installs: 7,
                id: 42
            }
        );
        let name = encode_cursor(Sort::Name, &item);
        assert_eq!(
            decode_cursor(&name, Sort::Name).unwrap(),
            Cursor::Name {
                name: "Pip. The/Imp".into(),
                id: 42
            }
        );
    }

    #[test]
    fn cursors_of_another_sort_or_garbage_are_refused() {
        let new = encode_cursor(Sort::New, &last("n", 0, 42));
        assert!(decode_cursor(&new, Sort::Popular).is_err());
        assert!(decode_cursor(&new, Sort::Name).is_err());
        assert!(decode_cursor("not base64 !!", Sort::New).is_err());
        assert!(decode_cursor(&URL_SAFE_NO_PAD.encode("n.-3"), Sort::New).is_err());
        assert!(decode_cursor(&URL_SAFE_NO_PAD.encode("n.x"), Sort::New).is_err());
        assert!(decode_cursor(&URL_SAFE_NO_PAD.encode("a.!!.3"), Sort::Name).is_err());
    }
}
