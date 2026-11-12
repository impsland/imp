//! Which files a phone may fetch from the Mac: a reply on the phone shows a picture or plays a voice that
//! lives on the Mac (`![](voice.mp3)`, a path in the Imp's folder), and the phone asks for it by the
//! reference as written. The Mac only sends what one of that Imp's replies actually mentions. This is the
//! pure half, finding the references in the text. The adapter resolves a reference against the file
//! system and checks it is inside the Imp's folder.

use std::ops::Range;

/// The references the replies make, as written: Markdown link and image destinations (`](...)`, with an
/// optional `<...>` and title) and `src=` / `href=` attributes. Plain prose that mentions a path is not a
/// reference.
pub fn references(texts: &[&str]) -> Vec<String> {
    texts
        .iter()
        .flat_map(|text| {
            reference_ranges(text)
                .into_iter()
                .map(|r| text[r].to_string())
        })
        .collect()
}

/// Where each reference sits in `text` (byte offsets), in the order `references` lists them.
pub fn reference_ranges(text: &str) -> Vec<Range<usize>> {
    let mut found = Vec::new();
    let mut pos = 0;
    while let Some(open) = text[pos..].find("](") {
        let start = pos + open + 2;
        let mut depth = 1i32;
        let mut escaped = false;
        let mut end = None;
        for (i, ch) in text[start..].char_indices() {
            if escaped {
                escaped = false;
                continue;
            }
            match ch {
                '\\' => escaped = true,
                '(' => depth += 1,
                ')' => {
                    depth -= 1;
                    if depth == 0 {
                        end = Some(start + i);
                        break;
                    }
                }
                '\n' => break,
                _ => {}
            }
        }
        let Some(end) = end else {
            pos = start;
            continue;
        };
        if let Some(range) = destination(text, start..end) {
            found.push(range);
        }
        pos = end;
    }
    for key in ["src=", "href="] {
        let mut tail = 0;
        while let Some(at) = text[tail..].find(key) {
            tail += at + key.len();
            let Some(quote) = text[tail..]
                .chars()
                .next()
                .filter(|c| *c == '"' || *c == '\'')
            else {
                continue;
            };
            let body = tail + 1;
            let Some(close) = text[body..].find(quote) else {
                break;
            };
            found.push(body..body + close);
            tail = body + close;
        }
    }
    found
}

/// The destination of a Markdown link: without `<...>` or a trailing `"title"`.
fn destination(text: &str, raw: Range<usize>) -> Option<Range<usize>> {
    let slice = &text[raw.clone()];
    let first = slice.find(|c: char| !c.is_whitespace())?;
    let start = raw.start + first;
    let rest = &text[start..raw.end];
    let range = if rest.starts_with('<') && rest.contains('>') {
        let close = start + rest.find('>')?;
        start + 1..close
    } else if let Some(space) = rest.find([' ', '\t']) {
        start..start + space
    } else {
        let last = rest.trim_end().len();
        start..start + last
    };
    (!range.is_empty()).then_some(range)
}

/// Whether a reference points at the web (the phone loads it directly).
pub fn is_web(reference: &str) -> bool {
    let Some((scheme, _)) = reference.split_once(':') else {
        return false;
    };
    !scheme.is_empty()
        && scheme
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || matches!(c, '+' | '-' | '.'))
        && matches!(scheme.to_ascii_lowercase().as_str(), "http" | "https")
}

#[cfg(test)]
mod tests {
    use super::*;

    fn refs(text: &str) -> Vec<String> {
        references(&[text])
    }

    #[test]
    fn markdown_links_and_images_make_references() {
        assert_eq!(
            refs("Look ![a](pics/a.png) and [b](b.mp3 \"title\")."),
            vec!["pics/a.png", "b.mp3"]
        );
        assert_eq!(refs("[x](<my file.png>)"), vec!["my file.png"]);
        assert_eq!(refs("[x](  spaced.png  )"), vec!["spaced.png"]);
        assert_eq!(refs("[x](a_(1).png)"), vec!["a_(1).png"]);
        assert_eq!(refs("[x](a\\)b.png)"), vec!["a\\)b.png"]);
    }

    #[test]
    fn prose_and_broken_links_are_not_references() {
        assert!(refs("see /etc/passwd or ~/secret.txt").is_empty());
        assert!(refs("[x](unclosed.png").is_empty());
        assert!(refs("[x](line\nbreak.png)").is_empty());
        assert!(refs("[x]()").is_empty());
        assert!(refs("[x](   )").is_empty());
    }

    #[test]
    fn attributes_count_when_quoted() {
        assert_eq!(
            refs(r#"<img src="a.png"> <a href='b.html'>"#),
            vec!["a.png", "b.html"]
        );
        assert!(refs("src=a.png").is_empty());
        assert!(refs(r#"src="never closed"#).is_empty());
    }

    #[test]
    fn ranges_point_into_the_text_even_with_wide_characters() {
        let text = "caf\u{e9} ![](\u{e9}t\u{e9}.png)";
        let ranges = reference_ranges(text);
        assert_eq!(&text[ranges[0].clone()], "\u{e9}t\u{e9}.png");
    }

    #[test]
    fn web_references_are_left_to_the_phone() {
        assert!(is_web("https://example.com/a.png"));
        assert!(is_web("HTTP://example.com"));
        assert!(!is_web("file:///tmp/a.png"));
        assert!(!is_web("a.png"));
        assert!(!is_web("/tmp/a:b.png"));
    }
}
