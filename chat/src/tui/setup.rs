//! The first run in a terminal: the steps that make the first Imp when there is none. Service, address, key,
//! model and name, one screen each, then the same things `imp provider add`, `imp auth set` and `imp agent
//! new` do, so the files are the ones the Mac app reads too. `Wizard` holds the steps and has no input or
//! output, so keys can be tested without a terminal. `run` is the thin part that talks to one.

use super::issue;
use super::start::{Input, Step, footer, next_input, page};
use super::terminal::Restore;
use super::text::{text_width, truncate};
use crate::Result;
use crate::commands::manage::{agent, auth, provider};
use crate::presets::{SERVICES, Service};
use crate::settings::Settings;
use crate::strings::{self, Lang};
use crate::theme::Theme;
use imp_engine::config::{ModelRef, valid_agent_name};
use imp_engine::{OpenAiClient, RetryPolicy};
use ratatui::Frame;
use ratatui::crossterm::event::{KeyCode, KeyModifiers};
use ratatui::layout::{Position, Rect};
use ratatui::text::{Line, Span};
use ratatui::widgets::Paragraph;
use std::time::Duration;

/// The name the field of the Imp's name starts with.
const FIRST_NAME: &str = "Pip";

/// How long to wait for a service to list its models before asking the person to type one.
const MODELS_WAIT: Duration = Duration::from_secs(5);

/// A choice of the first step: a service already in `imp.json`, or one of the presets.
#[derive(Clone)]
pub(super) enum Offer {
    Saved {
        id: String,
        url: String,
        /// The key it has already, from `imp.json` or `auth.json`.
        key: Option<String>,
    },
    Preset(&'static Service),
    /// The build's own service. The key it just handed out is in the steps.
    Issued {
        id: String,
        url: String,
    },
}

impl Offer {
    fn id(&self) -> &str {
        match self {
            Self::Saved { id, .. } => id,
            Self::Preset(service) => service.id,
            Self::Issued { id, .. } => id,
        }
    }

    fn url(&self) -> &str {
        match self {
            Self::Saved { url, .. } => url,
            Self::Preset(service) => service.base_url,
            Self::Issued { url, .. } => url,
        }
    }

    /// Whether the step of the key may be left empty: the service runs here, or is saved as it is.
    fn key_optional(&self) -> bool {
        match self {
            Self::Saved { .. } | Self::Issued { .. } => true,
            Self::Preset(service) => service.local,
        }
    }
}

/// Where the person is in the steps.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) enum Stage {
    Service,
    Address,
    Key,
    Model,
    Name,
}

/// What the steps came to: everything to write.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) struct Made {
    /// The service. It is added to `imp.json` unless `saved` says it was there.
    pub provider: String,
    pub url: String,
    pub saved: bool,
    /// The key to save, if one was typed.
    pub key: Option<String>,
    pub model: String,
    pub name: String,
}

/// The address and key to ask a service for its models with.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) struct Lookup {
    url: String,
    key: Option<String>,
}

pub(super) struct Wizard {
    offers: Vec<Offer>,
    /// The names an Imp cannot have, because an agent has them.
    taken: Vec<String>,
    stage: Stage,
    /// The stages left behind, for Esc.
    before: Vec<Stage>,
    chosen: usize,
    offer: Option<Offer>,
    address: String,
    key: String,
    model: String,
    /// The models of the service. `None` while they are being asked for.
    models: Option<Vec<String>>,
    lookup: Option<Lookup>,
    picked: usize,
    name: String,
    /// What is wrong with the last answer, as a sentence.
    problem: Option<String>,
    lang: Lang,
}

impl Wizard {
    pub(super) fn new(offers: Vec<Offer>, taken: Vec<String>, lang: Lang) -> Self {
        Self {
            offers,
            taken,
            stage: Stage::Service,
            before: Vec::new(),
            chosen: 0,
            offer: None,
            address: String::new(),
            key: String::new(),
            model: String::new(),
            models: None,
            lookup: None,
            picked: 0,
            name: FIRST_NAME.into(),
            problem: None,
            lang,
        }
    }

    /// The steps for the build's own service, whose key is already issued: they start at the model.
    pub(super) fn issued(
        id: String,
        url: String,
        key: String,
        taken: Vec<String>,
        lang: Lang,
    ) -> Self {
        let mut wizard = Self::new(Vec::new(), taken, lang);
        wizard.address = url.clone();
        wizard.key = key.clone();
        wizard.offer = Some(Offer::Issued { id, url });
        wizard.stage = Stage::Model;
        wizard.ask_models();
        wizard
    }

    /// The services to offer: the ones in `imp.json`, then each preset that is not there under its name.
    pub(super) fn offers_of(settings: &Settings) -> Vec<Offer> {
        let loaded = settings.load();
        let mut offers: Vec<Offer> = loaded
            .config
            .providers
            .iter()
            .filter_map(|(id, p)| {
                Some(Offer::Saved {
                    id: id.clone(),
                    url: p.options.base_url.clone().filter(|u| provider::is_url(u))?,
                    key: loaded.auth.key_for(id, Some(p)),
                })
            })
            .collect();
        for service in SERVICES {
            if !offers.iter().any(|o| o.id() == service.id) {
                offers.push(Offer::Preset(service));
            }
        }
        offers
    }

    /// The models to ask for, once, after the key is given.
    pub(super) fn take_lookup(&mut self) -> Option<Lookup> {
        self.lookup.take()
    }

    pub(super) fn set_models(&mut self, models: Vec<String>) {
        self.models = Some(models);
    }

    /// The models that match what is typed in the model field, an exact match first.
    fn matches(&self) -> Vec<&str> {
        let wanted = self.model.trim().to_lowercase();
        let mut found: Vec<&str> = self
            .models
            .iter()
            .flatten()
            .map(String::as_str)
            .filter(|m| m.to_lowercase().contains(&wanted))
            .collect();
        found.sort_by_key(|m| m.to_lowercase() != wanted);
        found
    }

    fn go(&mut self, stage: Stage) {
        self.before.push(self.stage);
        self.stage = stage;
        self.problem = None;
    }

    fn back(&mut self) -> bool {
        match self.before.pop() {
            Some(stage) => {
                self.stage = stage;
                self.problem = None;
                true
            }
            None => false,
        }
    }

    /// The text field of the stage on screen, if it has one.
    fn field(&mut self) -> Option<&mut String> {
        match self.stage {
            Stage::Service => None,
            Stage::Address => Some(&mut self.address),
            Stage::Key => Some(&mut self.key),
            Stage::Model => Some(&mut self.model),
            Stage::Name => Some(&mut self.name),
        }
    }

    pub(super) fn on_input(&mut self, input: Input) -> Step<Made> {
        match input {
            Input::Paste(text) => {
                // A key or a name pasted with its line break is the key or the name.
                let text = text.trim_end_matches(['\n', '\r']);
                if let Some(field) = self.field() {
                    field.push_str(text);
                    self.problem = None;
                }
                self.keep_pick_in_range();
                Step::Stay
            }
            Input::Key(key) => match key.code {
                KeyCode::Char('c' | 'd') if key.modifiers.contains(KeyModifiers::CONTROL) => {
                    Step::Leave
                }
                KeyCode::Esc => {
                    if self.back() {
                        Step::Stay
                    } else {
                        Step::Leave
                    }
                }
                KeyCode::Enter => self.advance(),
                KeyCode::Up => {
                    self.moved(-1);
                    Step::Stay
                }
                KeyCode::Down => {
                    self.moved(1);
                    Step::Stay
                }
                KeyCode::Backspace => {
                    if let Some(field) = self.field() {
                        field.pop();
                    }
                    self.problem = None;
                    self.keep_pick_in_range();
                    Step::Stay
                }
                KeyCode::Char('u') if key.modifiers.contains(KeyModifiers::CONTROL) => {
                    if let Some(field) = self.field() {
                        field.clear();
                    }
                    self.keep_pick_in_range();
                    Step::Stay
                }
                KeyCode::Char(c) if !key.modifiers.contains(KeyModifiers::CONTROL) => {
                    if let Some(field) = self.field() {
                        field.push(c);
                    }
                    self.problem = None;
                    self.keep_pick_in_range();
                    Step::Stay
                }
                _ => Step::Stay,
            },
        }
    }

    /// Up or down in the list of the stage: the services, or the models that match.
    fn moved(&mut self, by: isize) {
        match self.stage {
            Stage::Service => {
                self.chosen = self
                    .chosen
                    .saturating_add_signed(by)
                    .min(self.offers.len().saturating_sub(1));
            }
            Stage::Model => {
                let last = self.matches().len().saturating_sub(1);
                self.picked = self.picked.saturating_add_signed(by).min(last);
            }
            _ => {}
        }
    }

    fn keep_pick_in_range(&mut self) {
        if self.stage == Stage::Model {
            self.picked = 0;
        }
    }

    /// Enter: checks the answer and goes on, or says what is wrong with it.
    fn advance(&mut self) -> Step<Made> {
        match self.stage {
            Stage::Service => {
                let offer = self.offers[self.chosen].clone();
                self.address = offer.url().to_string();
                self.key.clear();
                let next = match &offer {
                    Offer::Saved { key: Some(_), .. } => Stage::Model,
                    Offer::Saved { key: None, .. } => Stage::Key,
                    Offer::Preset(_) | Offer::Issued { .. } => Stage::Address,
                };
                self.offer = Some(offer);
                self.go(next);
                if next == Stage::Model {
                    self.ask_models();
                }
            }
            Stage::Address => {
                self.address = self.address.trim().to_string();
                if provider::is_url(&self.address) {
                    self.go(Stage::Key);
                } else {
                    self.fail("cli.start.setup_error_address");
                }
            }
            Stage::Key => {
                self.key = self.key.trim().to_string();
                if self.key.is_empty() && !self.offer().key_optional() {
                    self.fail("cli.start.setup_error_key");
                } else {
                    self.go(Stage::Model);
                    self.ask_models();
                }
            }
            Stage::Model => {
                let model = self
                    .matches()
                    .get(self.picked)
                    .map_or_else(|| self.model.trim(), |m| m)
                    .to_string();
                if model_problem(&model) {
                    self.fail("cli.start.setup_error_model");
                } else {
                    self.model = model;
                    self.go(Stage::Name);
                }
            }
            Stage::Name => {
                self.name = self.name.trim().to_string();
                match name_problem(&self.name, &self.taken) {
                    Some(Problem::Invalid) => self.fail("cli.start.setup_error_name"),
                    Some(Problem::Taken) => {
                        self.problem = Some(strings::format(
                            self.lang,
                            "cli.start.setup_error_taken",
                            &[("name", &self.name)],
                        ));
                    }
                    None => return Step::Done(self.made()),
                }
            }
        }
        Step::Stay
    }

    fn offer(&self) -> &Offer {
        self.offer.as_ref().expect("a service is chosen first")
    }

    fn fail(&mut self, key: &str) {
        self.problem = Some(strings::text(self.lang, key).to_string());
    }

    /// Asks for the models of the service, with the key it has or the one typed.
    fn ask_models(&mut self) {
        let key = match (self.key.is_empty(), self.offer()) {
            (false, _) => Some(self.key.clone()),
            (true, Offer::Saved { key, .. }) => key.clone(),
            (true, Offer::Preset(_) | Offer::Issued { .. }) => None,
        };
        self.models = None;
        self.model.clear();
        self.picked = 0;
        self.lookup = Some(Lookup {
            url: self.address.clone(),
            key,
        });
    }

    fn made(&self) -> Made {
        let saved = matches!(self.offer(), Offer::Saved { .. });
        Made {
            provider: self.offer().id().to_string(),
            url: self.address.clone(),
            saved,
            key: (!self.key.is_empty()).then(|| self.key.clone()),
            model: self.model.clone(),
            name: self.name.clone(),
        }
    }

    pub(super) fn render(&self, frame: &mut Frame, theme: &Theme) {
        let lang = self.lang;
        let page = page(frame.area());
        let text = |key| strings::text(lang, key);
        let mut lines = vec![
            Line::styled(text("cli.start.setup_title"), theme.strong()),
            Line::raw(""),
        ];
        let question = match self.stage {
            Stage::Service => "cli.start.setup_service",
            Stage::Address => "cli.start.setup_address",
            Stage::Key => "cli.start.setup_key",
            Stage::Model => "cli.start.setup_model",
            Stage::Name => "cli.start.setup_name",
        };
        lines.push(Line::styled(text(question), theme.imp()));
        let mut cursor = None;
        let width = usize::from(page.width);
        match self.stage {
            Stage::Service => {
                for (i, offer) in self.offers.iter().enumerate() {
                    lines.push(self.offer_line(i, offer, theme, width));
                }
            }
            Stage::Address | Stage::Key | Stage::Name => {
                let shown = match self.stage {
                    Stage::Address => self.address.clone(),
                    Stage::Key => "•".repeat(self.key.chars().count()),
                    _ => self.name.clone(),
                };
                cursor = Some(lines.len());
                lines.push(Line::from(vec![
                    Span::styled("› ", theme.imp()),
                    Span::raw(shown),
                ]));
                if let Some(hint) = self.hint() {
                    lines.push(Line::styled(hint, theme.muted()));
                }
            }
            Stage::Model => {
                cursor = Some(lines.len());
                lines.push(Line::from(vec![
                    Span::styled("› ", theme.imp()),
                    Span::raw(self.model.clone()),
                ]));
                match &self.models {
                    None => lines.push(Line::styled(
                        text("cli.start.setup_models_loading"),
                        theme.muted(),
                    )),
                    Some(models) if models.is_empty() => lines.push(Line::styled(
                        text("cli.start.setup_models_none"),
                        theme.muted(),
                    )),
                    Some(_) => self.model_lines(&mut lines, theme, page, width),
                }
            }
        }
        if let Some(problem) = &self.problem {
            lines.push(Line::raw(""));
            lines.push(Line::styled(format!("✕ {problem}"), theme.danger()));
        }
        frame.render_widget(Paragraph::new(lines), page);
        if let Some(row) = cursor {
            let typed = match self.stage {
                Stage::Address => self.address.as_str(),
                Stage::Model => self.model.as_str(),
                Stage::Name => self.name.as_str(),
                _ => "",
            };
            let used = if self.stage == Stage::Key {
                self.key.chars().count()
            } else {
                text_width(typed)
            };
            let x = page.x + 2 + u16::try_from(used).unwrap_or(u16::MAX);
            let y = page.y + u16::try_from(row).unwrap_or(u16::MAX);
            frame.set_cursor_position(Position::new(x.min(page.right().saturating_sub(1)), y));
        }
        let keys = match self.stage {
            Stage::Service => "cli.start.setup_footer_list",
            _ => "cli.start.setup_footer_field",
        };
        footer(frame, page, theme, text(keys));
    }

    /// The line under a field: where to get a key, or that it may stay empty.
    fn hint(&self) -> Option<String> {
        match (self.stage, self.offer.as_ref()?) {
            (Stage::Key, offer) if offer.key_optional() => {
                Some(strings::text(self.lang, "cli.start.setup_key_optional").to_string())
            }
            (Stage::Key, Offer::Preset(service)) => Some(service.link.to_string()),
            _ => None,
        }
    }

    fn offer_line(&self, i: usize, offer: &Offer, theme: &Theme, width: usize) -> Line<'static> {
        let label = match offer {
            Offer::Saved { id, url, .. } | Offer::Issued { id, url, .. } => format!("{id}  {url}"),
            Offer::Preset(service) => strings::text(
                self.lang,
                if service.local {
                    "cli.start.setup_local"
                } else {
                    "cli.start.setup_remote"
                },
            )
            .to_string(),
        };
        let chosen = i == self.chosen;
        Line::from(vec![
            Span::styled(if chosen { "› " } else { "  " }, theme.imp()),
            Span::styled(
                truncate(&label, width.saturating_sub(2)),
                if chosen { theme.strong() } else { theme.text() },
            ),
        ])
    }

    /// The models that match, as many as fit under the field, scrolled to keep the one chosen in view.
    fn model_lines(&self, lines: &mut Vec<Line<'static>>, theme: &Theme, page: Rect, width: usize) {
        let found = self.matches();
        let rows = usize::from(page.height)
            .saturating_sub(lines.len() + 3)
            .max(1);
        let first = (self.picked + 1).saturating_sub(rows);
        for (i, model) in found.iter().enumerate().skip(first).take(rows) {
            let chosen = i == self.picked;
            lines.push(Line::from(vec![
                Span::styled(if chosen { "› " } else { "  " }, theme.imp()),
                Span::styled(
                    truncate(model, width.saturating_sub(2)),
                    if chosen { theme.strong() } else { theme.text() },
                ),
            ]));
        }
    }
}

/// What is wrong with the name of an Imp.
#[derive(Debug, PartialEq, Eq)]
pub(super) enum Problem {
    /// It is not 1 to 32 letters, digits, `-` and `_`.
    Invalid,
    /// An agent has it already (the case does not matter, as for `imp agent new`).
    Taken,
}

pub(super) fn name_problem(name: &str, taken: &[String]) -> Option<Problem> {
    if !valid_agent_name(name) {
        Some(Problem::Invalid)
    } else if taken.iter().any(|t| t.eq_ignore_ascii_case(name)) {
        Some(Problem::Taken)
    } else {
        None
    }
}

/// Whether `model` cannot be the model of an Imp once it has its service in front.
pub(super) fn model_problem(model: &str) -> bool {
    ModelRef::parse(&format!("service/{model}")).is_err()
}

/// Writes what the steps came to, through the commands the same words run.
pub(super) fn write(settings: &Settings, made: &Made) -> Result<()> {
    if !made.saved {
        provider::add(settings, &made.provider, &made.url, None, &[], None)?;
    }
    if let Some(key) = &made.key {
        auth::set(settings, &made.provider, key)?;
    }
    let model = format!("{}/{}", made.provider, made.model);
    agent::new(settings, &made.name, None, Some(model), "primary", None)?;
    Ok(())
}

/// The models a service lists. None when it does not answer in time, or answers with something
/// else: the person types the model then.
async fn fetch_models(lookup: &Lookup) -> Vec<String> {
    let Ok(client) = OpenAiClient::new(&lookup.url, lookup.key.clone(), RetryPolicy::default())
    else {
        return Vec::new();
    };
    match tokio::time::timeout(MODELS_WAIT, client.models()).await {
        Ok(Ok(models)) => models,
        _ => Vec::new(),
    }
}

/// Shows the steps and makes the Imp. The name of it, or `None` when the person left.
pub(super) async fn run(settings: &Settings) -> Result<Option<String>> {
    let loaded = settings.load();
    let taken = loaded.agents.keys().cloned().collect();
    let lang = Lang::detect();
    let mut wizard = match issue::first_key(lang).await {
        Some((id, url, key)) => Wizard::issued(id, url, key, taken, lang),
        None => Wizard::new(Wizard::offers_of(settings), taken, lang),
    };
    let theme = Theme::detect();
    let made = {
        let (_guard, mut terminal) = Restore::start()?;
        loop {
            terminal.draw(|frame| wizard.render(frame, &theme))?;
            if let Some(lookup) = wizard.take_lookup() {
                let models = fetch_models(&lookup).await;
                wizard.set_models(models);
                continue;
            }
            let Some(input) = next_input()? else {
                continue;
            };
            match wizard.on_input(input) {
                Step::Stay => {}
                Step::Done(made) => break made,
                Step::Leave => return Ok(None),
            }
        }
    };
    write(settings, &made)?;
    Ok(Some(made.name))
}

#[cfg(test)]
mod tests {
    use super::*;
    use ratatui::Terminal;
    use ratatui::backend::TestBackend;
    use ratatui::crossterm::event::KeyEvent;

    fn key(code: KeyCode) -> Input {
        Input::Key(KeyEvent::new(code, KeyModifiers::NONE))
    }

    fn typed(wizard: &mut Wizard, text: &str) {
        for c in text.chars() {
            wizard.on_input(key(KeyCode::Char(c)));
        }
    }

    fn wizard() -> Wizard {
        let offers = SERVICES.iter().map(Offer::Preset).collect();
        Wizard::new(offers, vec!["Sage".into()], Lang::En)
    }

    fn screen(wizard: &Wizard, w: u16, h: u16) -> Vec<String> {
        let mut terminal = Terminal::new(TestBackend::new(w, h)).unwrap();
        terminal
            .draw(|f| wizard.render(f, &Theme::new(true, false)))
            .unwrap();
        let buffer = terminal.backend().buffer().clone();
        (0..h)
            .map(|y| {
                (0..w)
                    .map(|x| buffer[(x, y)].symbol().to_string())
                    .collect::<String>()
                    .trim_end()
                    .to_string()
            })
            .collect()
    }

    #[test]
    fn an_issued_service_starts_at_the_models_and_writes_its_key() {
        let mut w = Wizard::issued(
            "api-example-com".into(),
            "https://api.example.com/v1".into(),
            "sk-res-1".into(),
            Vec::new(),
            Lang::En,
        );
        assert_eq!(w.stage, Stage::Model);
        assert_eq!(w.take_lookup().unwrap().key.as_deref(), Some("sk-res-1"));
        w.set_models(vec!["m1".into()]);
        w.on_input(key(KeyCode::Enter));
        let Step::Done(made) = w.on_input(key(KeyCode::Enter)) else {
            panic!("the name step ends the steps");
        };
        assert_eq!(made.provider, "api-example-com");
        assert!(!made.saved);
        assert_eq!(made.key.as_deref(), Some("sk-res-1"));
        assert_eq!(made.model, "m1");
    }

    #[test]
    fn names_follow_the_engine_rule_and_ignore_case_for_taken_ones() {
        let taken = vec!["Sage".to_string()];
        assert_eq!(name_problem("pip_2", &taken), None);
        assert_eq!(name_problem("", &taken), Some(Problem::Invalid));
        assert_eq!(name_problem("a b", &taken), Some(Problem::Invalid));
        assert_eq!(
            name_problem(&"x".repeat(33), &taken),
            Some(Problem::Invalid)
        );
        assert_eq!(name_problem("sage", &taken), Some(Problem::Taken));
    }

    #[test]
    fn a_model_is_anything_a_model_reference_can_hold() {
        assert!(!model_problem("openai/gpt-6-luna"));
        assert!(!model_problem("qwen3:8b"));
        assert!(model_problem(""));
        assert!(!model_problem("gpt#high"));
        assert!(model_problem("gpt#high#low"));
    }

    #[test]
    fn the_remote_steps_ask_for_a_key_and_the_models_with_it() {
        let mut w = wizard();
        assert_eq!(w.stage, Stage::Service);
        w.on_input(key(KeyCode::Enter));
        assert_eq!(w.stage, Stage::Address);
        assert_eq!(w.address, SERVICES[0].base_url);
        w.on_input(key(KeyCode::Enter));
        assert_eq!(w.stage, Stage::Key);
        // A key is needed for a service in the cloud.
        w.on_input(key(KeyCode::Enter));
        assert_eq!(w.stage, Stage::Key);
        assert!(w.problem.as_deref().unwrap().contains("key"));
        typed(&mut w, "sk-123");
        assert_eq!(w.problem, None);
        w.on_input(key(KeyCode::Enter));
        assert_eq!(w.stage, Stage::Model);
        assert_eq!(
            w.take_lookup(),
            Some(Lookup {
                url: SERVICES[0].base_url.into(),
                key: Some("sk-123".into())
            })
        );
        assert_eq!(w.take_lookup(), None);
        w.set_models(vec!["a/one".into(), "b/two".into(), "b/twelve".into()]);
        typed(&mut w, "two");
        assert_eq!(w.matches(), ["b/two"]);
        w.on_input(key(KeyCode::Enter));
        assert_eq!(w.stage, Stage::Name);
        assert_eq!(w.name, "Pip");
        let Step::Done(made) = w.on_input(key(KeyCode::Enter)) else {
            panic!("the name is good");
        };
        assert_eq!(
            made,
            Made {
                provider: "remote".into(),
                url: SERVICES[0].base_url.into(),
                saved: false,
                key: Some("sk-123".into()),
                model: "b/two".into(),
                name: "Pip".into(),
            }
        );
    }

    #[test]
    fn a_local_service_needs_no_key_and_a_model_can_be_typed() {
        let mut w = wizard();
        w.on_input(key(KeyCode::Down));
        w.on_input(key(KeyCode::Enter));
        w.on_input(key(KeyCode::Enter));
        w.on_input(key(KeyCode::Enter));
        assert_eq!(w.stage, Stage::Model);
        w.set_models(Vec::new());
        typed(&mut w, "qwen3:8b");
        w.on_input(key(KeyCode::Enter));
        for _ in 0.."Pip".len() {
            w.on_input(key(KeyCode::Backspace));
        }
        typed(&mut w, "Ann");
        let Step::Done(made) = w.on_input(key(KeyCode::Enter)) else {
            panic!("the name is good");
        };
        assert_eq!(made.provider, "local");
        assert_eq!(made.key, None);
        assert_eq!(made.model, "qwen3:8b");
        assert_eq!(made.name, "Ann");
    }

    #[test]
    fn a_bad_address_or_name_stays_and_says_why() {
        let mut w = wizard();
        w.on_input(key(KeyCode::Enter));
        w.on_input(Input::Key(KeyEvent::new(
            KeyCode::Char('u'),
            KeyModifiers::CONTROL,
        )));
        typed(&mut w, "localhost:1");
        w.on_input(key(KeyCode::Enter));
        assert_eq!(w.stage, Stage::Address);
        assert!(w.problem.as_deref().unwrap().contains("http://"));
        w.name = "sage".into();
        w.stage = Stage::Name;
        w.offer = Some(Offer::Preset(&SERVICES[1]));
        w.on_input(key(KeyCode::Enter));
        assert_eq!(w.stage, Stage::Name);
        assert_eq!(
            w.problem.as_deref(),
            Some("There is already an Imp called sage.")
        );
    }

    #[test]
    fn a_saved_service_with_a_key_goes_straight_to_the_models() {
        let offers = vec![Offer::Saved {
            id: "mine".into(),
            url: "http://x/v1".into(),
            key: Some("k".into()),
        }];
        let mut w = Wizard::new(offers, Vec::new(), Lang::En);
        w.on_input(key(KeyCode::Enter));
        assert_eq!(w.stage, Stage::Model);
        assert_eq!(
            w.take_lookup(),
            Some(Lookup {
                url: "http://x/v1".into(),
                key: Some("k".into())
            })
        );
        // Esc goes back, then leaves.
        assert!(matches!(w.on_input(key(KeyCode::Esc)), Step::Stay));
        assert_eq!(w.stage, Stage::Service);
        assert!(matches!(w.on_input(key(KeyCode::Esc)), Step::Leave));
    }

    #[test]
    fn control_c_leaves_from_any_step() {
        let mut w = wizard();
        w.on_input(key(KeyCode::Enter));
        let ctrl_c = KeyEvent::new(KeyCode::Char('c'), KeyModifiers::CONTROL);
        assert!(matches!(w.on_input(Input::Key(ctrl_c)), Step::Leave));
    }

    #[test]
    fn the_steps_are_drawn_with_their_question_and_hidden_key() {
        let mut w = wizard();
        let rows = screen(&w, 70, 12);
        assert_eq!(rows[1], "  Let's set up your first Imp");
        assert_eq!(rows[3], "  Where does the model run?");
        assert_eq!(rows[4], "  › Remote: an online service, needs a key");
        assert_eq!(rows[5], "    Local: a model server on this computer");
        assert_eq!(rows[10], "  ↑ ↓ choose · Enter next · Esc back");
        w.on_input(key(KeyCode::Enter));
        w.on_input(key(KeyCode::Enter));
        typed(&mut w, "abc");
        let rows = screen(&w, 70, 12);
        assert_eq!(rows[3], "  Your key");
        assert_eq!(rows[4], "  › •••");
        assert_eq!(rows[5], format!("  {}", SERVICES[0].link));
        w.on_input(key(KeyCode::Enter));
        let rows = screen(&w, 70, 12);
        assert_eq!(rows[5], "  Looking for models…");
        w.set_models(vec!["m/one".into(), "m/two".into()]);
        w.on_input(key(KeyCode::Down));
        let rows = screen(&w, 70, 12);
        assert_eq!(rows[3], "  Search or type a model");
        assert_eq!(rows[5], "    m/one");
        assert_eq!(rows[6], "  › m/two");
    }

    #[test]
    fn the_steps_are_written_as_the_commands_would_write_them() {
        let root = std::env::temp_dir().join(format!("imp-setup-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        let (config, home, data) = (root.join("cfg"), root.join("home"), root.join("data"));
        for dir in [&config, &home, &data] {
            std::fs::create_dir_all(dir).unwrap();
        }
        let config_text = config.display().to_string();
        let env = imp_engine::config::Env::new(&[("IMP_CONFIG_HOME", &config_text)], Some(&home));
        let settings = Settings::new(env, root.clone(), Some(data)).unwrap();
        let made = Made {
            provider: "remote".into(),
            url: "https://example.test/v1".into(),
            saved: false,
            key: Some("sk-1".into()),
            model: "b/two".into(),
            name: "Pip".into(),
        };
        write(&settings, &made).unwrap();
        let loaded = settings.load();
        assert_eq!(loaded.imps().count(), 1);
        assert_eq!(
            loaded.imps().next().unwrap().value.model.as_deref(),
            Some("remote/b/two")
        );
        assert_eq!(
            loaded
                .auth
                .key_for("remote", loaded.config.providers.get("remote")),
            Some("sk-1".into())
        );
        let offers = Wizard::offers_of(&settings);
        assert!(matches!(&offers[0], Offer::Saved { id, key: Some(_), .. } if id == "remote"));
        assert_eq!(offers.len(), SERVICES.len());
        let _ = std::fs::remove_dir_all(&root);
    }
}
