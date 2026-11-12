//! List paging cursors: opaque, bound to a sort order.

use super::*;

pub(super) fn encode_cursor(sort: Sort, installs: i64, id: i64) -> String {
    let plain = match sort {
        Sort::New => format!("n.{id}"),
        Sort::Popular => format!("p.{installs}.{id}"),
    };
    URL_SAFE_NO_PAD.encode(plain)
}

/// `(installs, id)` of the last item of the previous page. `installs` is unused when sorting by new.
pub(super) fn decode_cursor(cursor: &str, sort: Sort) -> Result<(i64, i64), Error> {
    let invalid = || bad("`cursor` is not one this server gave out for this sort order.");
    let plain = URL_SAFE_NO_PAD
        .decode(cursor)
        .ok()
        .and_then(|b| String::from_utf8(b).ok())
        .ok_or_else(invalid)?;
    let parts: Vec<&str> = plain.split('.').collect();
    let number = |s: &str| s.parse::<i64>().ok().filter(|n| *n >= 0);
    match (sort, parts.as_slice()) {
        (Sort::New, ["n", id]) => Ok((0, number(id).ok_or_else(invalid)?)),
        (Sort::Popular, ["p", installs, id]) => Ok((
            number(installs).ok_or_else(invalid)?,
            number(id).ok_or_else(invalid)?,
        )),
        _ => Err(invalid()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn cursors_round_trip_per_sort() {
        let new = encode_cursor(Sort::New, 0, 42);
        assert_eq!(decode_cursor(&new, Sort::New).unwrap(), (0, 42));
        let popular = encode_cursor(Sort::Popular, 7, 42);
        assert_eq!(decode_cursor(&popular, Sort::Popular).unwrap(), (7, 42));
    }

    #[test]
    fn cursors_of_another_sort_or_garbage_are_refused() {
        let new = encode_cursor(Sort::New, 0, 42);
        assert!(decode_cursor(&new, Sort::Popular).is_err());
        assert!(decode_cursor("not base64 !!", Sort::New).is_err());
        assert!(decode_cursor(&URL_SAFE_NO_PAD.encode("n.-3"), Sort::New).is_err());
        assert!(decode_cursor(&URL_SAFE_NO_PAD.encode("n.x"), Sort::New).is_err());
    }
}
