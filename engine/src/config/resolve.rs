//! Which service, model and request settings an agent talks with: its `model` (else the default one in
//! `imp.json`), that provider's address, key and headers, the variant's body fields and the agent's own
//! `request`. A pure function over the loaded values, so every app resolves the same way.

use crate::config::{Agent, Auth, ImpConfig, ModelRef, Provider};
use serde_json::{Map, Value, json};
use std::collections::BTreeMap;

/// The variants that work without the provider defining them: they send `reasoning_effort`.
pub const EFFORTS: [&str; 3] = ["low", "medium", "high"];

/// Where a provider's key comes from.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum KeySource {
    /// `options.apiKey` in `imp.json` (usually `{env:NAME}` or `{file:path}`).
    Settings,
    /// Saved in `auth.json`.
    Saved,
}

/// Everything a request to the model needs, apart from the messages.
#[derive(Clone, PartialEq)]
pub struct Resolved {
    pub provider: String,
    pub model: String,
    pub variant: Option<String>,
    pub base_url: String,
    pub api_key: Option<String>,
    pub key_source: Option<KeySource>,
    /// The provider's headers, then the agent's.
    pub headers: BTreeMap<String, String>,
    /// Added to the request body: the variant's object, then the agent's `request.body`.
    pub body: Map<String, Value>,
}

impl std::fmt::Debug for Resolved {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Resolved")
            .field("provider", &self.provider)
            .field("model", &self.model)
            .field("variant", &self.variant)
            .field("base_url", &self.base_url)
            .field("api_key", &self.api_key.as_ref().map(|_| "<hidden>"))
            .finish_non_exhaustive()
    }
}

impl Resolved {
    /// `provider/model#variant` as written in a file.
    pub fn reference(&self) -> String {
        ModelRef {
            provider: self.provider.clone(),
            model: self.model.clone(),
            variant: self.variant.clone(),
        }
        .to_string()
    }
}

/// The object a variant adds to the body: the provider model's own, else `reasoning_effort` for
/// `low`, `medium` and `high`.
pub fn variant_body(
    provider: &Provider,
    model: &str,
    variant: &str,
) -> Result<Map<String, Value>, String> {
    if let Some(Value::Object(map)) = provider
        .models
        .get(model)
        .and_then(|m| m.variants.get(variant))
    {
        return Ok(map.clone());
    }
    if EFFORTS.contains(&variant) {
        return Ok(json!({ "reasoning_effort": variant })
            .as_object()
            .cloned()
            .unwrap_or_default());
    }
    Err(format!(
        "{model} has no variant {variant}. low, medium and high always work; others are defined under providers.<id>.models.{model}.variants in imp.json."
    ))
}

/// Resolves the model of `agent`, or `over` instead of its own. `Err` is a plain sentence.
pub fn resolve(
    config: &ImpConfig,
    auth: &Auth,
    agent: &Agent,
    over: Option<&ModelRef>,
) -> Result<Resolved, String> {
    let model = match over {
        Some(m) => m.clone(),
        None => agent
            .model_ref(config.model.as_deref())
            .map_err(|e| e.to_string())?
            .ok_or_else(|| {
                format!(
                    "{} has no model. Choose one with `imp model provider/model --agent {}`.",
                    agent.name, agent.name
                )
            })?,
    };
    let provider = config.providers.get(&model.provider).ok_or_else(|| {
        format!(
            "There is no provider {}. Add it with `imp provider add {} --url URL`.",
            model.provider, model.provider
        )
    })?;
    let base_url = provider
        .options
        .base_url
        .clone()
        .filter(|u| !u.trim().is_empty())
        .ok_or_else(|| {
            format!(
                "The provider {} has no address (options.baseURL).",
                model.provider
            )
        })?;
    let (api_key, key_source) = match provider.options.api_key.clone().filter(|k| !k.is_empty()) {
        Some(key) => (Some(key), Some(KeySource::Settings)),
        None => match auth.key_for(&model.provider, Some(provider)) {
            Some(key) => (Some(key), Some(KeySource::Saved)),
            None => (None, None),
        },
    };
    let mut body = match &model.variant {
        Some(v) => variant_body(provider, &model.model, v)?,
        None => Map::new(),
    };
    let mut headers = provider.options.headers.clone();
    if let Some(request) = &agent.request {
        headers.extend(request.headers.clone());
        body.extend(request.body.clone());
    }
    Ok(Resolved {
        provider: model.provider,
        model: model.model,
        variant: model.variant,
        base_url,
        api_key,
        key_source,
        headers,
        body,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::config::{ModelDef, ProviderAuth, ProviderOptions};

    fn config() -> ImpConfig {
        let mut c = ImpConfig {
            model: Some("ollama/qwen3#high".into()),
            ..ImpConfig::default()
        };
        let mut p = Provider {
            options: ProviderOptions {
                base_url: Some("http://h/v1".into()),
                ..ProviderOptions::default()
            },
            ..Provider::default()
        };
        p.options.headers.insert("X-A".into(), "provider".into());
        p.models.insert(
            "qwen3".into(),
            ModelDef {
                variants: [("deep".to_string(), json!({"think": true}))].into(),
                ..ModelDef::default()
            },
        );
        c.providers.insert("ollama".into(), p);
        c
    }

    fn agent(model: Option<&str>) -> Agent {
        Agent::parse(
            "pip",
            &format!(
                "---\n{}---\nhi",
                model.map(|m| format!("model: {m}\n")).unwrap_or_default()
            ),
        )
        .unwrap()
    }

    #[test]
    fn the_default_model_and_an_effort_variant() {
        let r = resolve(&config(), &Auth::default(), &agent(None), None).unwrap();
        assert_eq!((r.provider.as_str(), r.model.as_str()), ("ollama", "qwen3"));
        assert_eq!(r.body["reasoning_effort"], "high");
        assert_eq!(r.reference(), "ollama/qwen3#high");
        assert_eq!(r.api_key, None);
    }

    #[test]
    fn a_provider_variant_and_the_agents_request_win_in_that_order() {
        let mut a = agent(Some("ollama/qwen3#deep"));
        a.request = Some(crate::config::AgentRequest {
            headers: [("X-A".to_string(), "agent".to_string())].into(),
            body: [("think".to_string(), json!(false))].into(),
        });
        let r = resolve(&config(), &Auth::default(), &a, None).unwrap();
        assert_eq!(r.body["think"], json!(false));
        assert_eq!(r.headers["X-A"], "agent");
        assert!(
            resolve(
                &config(),
                &Auth::default(),
                &agent(Some("ollama/qwen3#nope")),
                None
            )
            .is_err()
        );
    }

    #[test]
    fn the_key_is_the_settings_one_else_the_saved_one() {
        let mut auth = Auth::default();
        auth.providers.insert(
            "ollama".into(),
            ProviderAuth {
                key: "saved".into(),
            },
        );
        let r = resolve(&config(), &auth, &agent(None), None).unwrap();
        assert_eq!(
            (r.api_key.as_deref(), r.key_source),
            (Some("saved"), Some(KeySource::Saved))
        );
        let mut c = config();
        c.providers.get_mut("ollama").unwrap().options.api_key = Some("from-settings".into());
        let r = resolve(&c, &auth, &agent(None), None).unwrap();
        assert_eq!(
            (r.api_key.as_deref(), r.key_source),
            (Some("from-settings"), Some(KeySource::Settings))
        );
        assert!(!format!("{r:?}").contains("from-settings"));
    }

    #[test]
    fn mistakes_are_sentences() {
        let e = resolve(&ImpConfig::default(), &Auth::default(), &agent(None), None).unwrap_err();
        assert!(e.contains("has no model"), "{e}");
        let e = resolve(
            &ImpConfig::default(),
            &Auth::default(),
            &agent(Some("x/y")),
            None,
        )
        .unwrap_err();
        assert!(e.contains("no provider x"), "{e}");
    }
}
