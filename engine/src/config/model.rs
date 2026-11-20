//! `provider/model#variant`: how an agent or `imp.json` names a model.

use std::fmt;

#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
#[error("{0:?} is not a model: write provider/model, with #variant after it if there is one.")]
pub struct ModelRefError(pub String);

/// A model of a provider, with the variant of it to use, if any. The model may hold slashes
/// (`openrouter/openai/gpt-6-luna` is the provider `openrouter` and the model `openai/gpt-6-luna`).
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct ModelRef {
    pub provider: String,
    pub model: String,
    pub variant: Option<String>,
}

impl ModelRef {
    /// Reads `^[^/#]+/[^#]+(#[^#]+)?$`.
    pub fn parse(text: &str) -> Result<Self, ModelRefError> {
        let bad = || ModelRefError(text.to_string());
        let (rest, variant) = match text.split_once('#') {
            Some((rest, variant)) => (rest, Some(variant)),
            None => (text, None),
        };
        if variant.is_some_and(|v| v.is_empty() || v.contains('#')) {
            return Err(bad());
        }
        let (provider, model) = rest.split_once('/').ok_or_else(bad)?;
        if provider.is_empty() || model.is_empty() {
            return Err(bad());
        }
        Ok(Self {
            provider: provider.into(),
            model: model.into(),
            variant: variant.map(str::to_string),
        })
    }

    /// The same model with another variant.
    pub fn with_variant(mut self, variant: Option<String>) -> Self {
        self.variant = variant;
        self
    }
}

impl fmt::Display for ModelRef {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}/{}", self.provider, self.model)?;
        if let Some(variant) = &self.variant {
            write!(f, "#{variant}")?;
        }
        Ok(())
    }
}

impl std::str::FromStr for ModelRef {
    type Err = ModelRefError;
    fn from_str(s: &str) -> Result<Self, Self::Err> {
        Self::parse(s)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_and_formats() {
        for (text, provider, model, variant) in [
            ("ollama/qwen3.8#high", "ollama", "qwen3.8", Some("high")),
            ("ollama/qwen3.8", "ollama", "qwen3.8", None),
            (
                "openrouter/openai/gpt-6-luna",
                "openrouter",
                "openai/gpt-6-luna",
                None,
            ),
            ("a/b/c#v", "a", "b/c", Some("v")),
        ] {
            let r = ModelRef::parse(text).unwrap();
            assert_eq!((r.provider.as_str(), r.model.as_str()), (provider, model));
            assert_eq!(r.variant.as_deref(), variant);
            assert_eq!(r.to_string(), text);
        }
    }

    #[test]
    fn refuses_what_the_pattern_refuses() {
        for text in [
            "", "model", "/m", "p/", "p/m#", "p/m#a#b", "#v", "p#v/m", "p/#v", "/#",
        ] {
            assert!(ModelRef::parse(text).is_err(), "{text:?}");
        }
        assert!(
            ModelRef::parse("x")
                .unwrap_err()
                .to_string()
                .contains("provider/model")
        );
    }

    #[test]
    fn changes_the_variant() {
        let r: ModelRef = "p/m".parse().unwrap();
        assert_eq!(r.with_variant(Some("low".into())).to_string(), "p/m#low");
    }
}
