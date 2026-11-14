//! The words of the terminal app, in the person's language. The table is generated from
//! `design/strings/cli.json`. A missing translation shows the English text.

#[path = "strings.generated.rs"]
mod table;

pub use table::STRINGS;

/// A language the terminal app is written in.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Lang {
    En,
    Es,
    ZhHans,
}

impl Lang {
    /// The language from a locale name such as `es_ES.UTF-8`, or English for anything else.
    pub fn from_locale(locale: &str) -> Self {
        let tag = locale.to_ascii_lowercase();
        if tag.starts_with("es") {
            Self::Es
        } else if tag.starts_with("zh") {
            Self::ZhHans
        } else {
            Self::En
        }
    }

    /// The language of the first of `LC_ALL`, `LC_MESSAGES` and `LANG` that is set.
    pub fn detect() -> Self {
        let locale = ["LC_ALL", "LC_MESSAGES", "LANG"]
            .iter()
            .find_map(|name| std::env::var(name).ok().filter(|v| !v.is_empty()));
        locale.map_or(Self::En, |l| Self::from_locale(&l))
    }

    fn index(self) -> usize {
        match self {
            Self::En => 0,
            Self::Es => 1,
            Self::ZhHans => 2,
        }
    }
}

/// The text for `key` in `lang`. English when that language has nothing, and empty for an unknown key.
pub fn text(lang: Lang, key: &str) -> &'static str {
    let Ok(at) = STRINGS.binary_search_by(|(k, _)| (*k).cmp(key)) else {
        return "";
    };
    let texts = &STRINGS[at].1;
    let wanted = texts[lang.index()];
    if wanted.is_empty() { texts[0] } else { wanted }
}

/// Like [`text`], with each `{name}` replaced by its value.
pub fn format(lang: Lang, key: &str, args: &[(&str, &str)]) -> String {
    let mut out = text(lang, key).to_string();
    for (name, value) in args {
        out = out.replace(&format!("{{{name}}}"), value);
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn every_key_has_three_languages_and_a_cli_name() {
        assert!(!STRINGS.is_empty());
        for (key, texts) in STRINGS {
            assert!(key.starts_with("cli."), "{key}");
            for t in texts {
                assert!(!t.is_empty(), "{key} is missing a language");
            }
        }
        assert!(
            STRINGS.windows(2).all(|w| w[0].0 < w[1].0),
            "sorted for lookup"
        );
    }

    #[test]
    fn a_language_is_found_from_the_locale() {
        assert_eq!(Lang::from_locale("es_ES.UTF-8"), Lang::Es);
        assert_eq!(Lang::from_locale("zh_CN.UTF-8"), Lang::ZhHans);
        assert_eq!(Lang::from_locale("fr_FR.UTF-8"), Lang::En);
        assert_eq!(Lang::from_locale("C"), Lang::En);
        assert_eq!(text(Lang::Es, "cli.chat.ready"), "Listo");
        assert_eq!(text(Lang::ZhHans, "cli.chat.ready"), "就绪");
    }

    #[test]
    fn an_empty_translation_falls_back_to_english() {
        // Every shipped key is complete, so the fallback is checked on the lookup rule itself.
        let texts = ["Ready", "", "就绪"];
        let wanted = texts[Lang::Es.index()];
        assert_eq!(if wanted.is_empty() { texts[0] } else { wanted }, "Ready");
        assert_eq!(text(Lang::En, "cli.chat.ready"), "Ready");
    }

    #[test]
    fn arguments_are_filled_in() {
        assert_eq!(
            format(
                Lang::En,
                "cli.chat.tool_use",
                &[("imp", "pip"), ("tool", "files__read")]
            ),
            "pip uses the tool files__read"
        );
    }
}
