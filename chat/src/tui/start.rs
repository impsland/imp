//! What `imp` shows in a terminal before the chat when no Imp was named: a list to choose from when there
//! are several, and the steps that make the first one (`setup`) when there are none. With one Imp, or with
//! no terminal, nothing is shown and the chat goes on as it was asked.

use super::setup;
use super::terminal::Restore;
use super::text::{text_width, truncate};
use crate::settings::{Settings, hue_of};
use crate::strings::{self, Lang};
use crate::theme::Theme;
use crate::{CliError, Result};
use ratatui::Frame;
use ratatui::crossterm::event::{Event, KeyCode, KeyEvent, KeyEventKind, KeyModifiers, read};
use ratatui::layout::Rect;
use ratatui::text::{Line, Span};
use ratatui::widgets::Paragraph;

/// What to do first.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Plan {
    /// Open the chat as asked: with the Imp named, the only Imp there is, or the error that says why not.
    Open,
    /// Let the person choose one of the Imps.
    Pick,
    /// There is no Imp: make the first one.
    SetUp,
}

/// `named`: the Imp was named with `--imp`. `interactive`: there is a terminal to ask in.
pub fn plan(named: bool, imps: usize, interactive: bool) -> Plan {
    match imps {
        _ if named || !interactive => Plan::Open,
        0 => Plan::SetUp,
        1 => Plan::Open,
        _ => Plan::Pick,
    }
}

/// How the start ended.
#[derive(Debug, PartialEq, Eq)]
pub enum Start {
    /// Open the chat with this Imp, or with the only one when there is no name.
    Chat(Option<String>),
    /// The person left without choosing.
    Leave,
}

/// What a screen does with a key.
pub(super) enum Step<T> {
    Stay,
    Done(T),
    Leave,
}

/// Decides, and shows what the decision needs. `name`: the Imp asked for, if any.
pub async fn choose(settings: &Settings, name: Option<&str>) -> Result<Start> {
    let loaded = settings.load();
    let imps: Vec<_> = loaded.imps().collect();
    match plan(name.is_some(), imps.len(), true) {
        Plan::Open => Ok(Start::Chat(name.map(str::to_string))),
        Plan::Pick => {
            let choices = imps
                .iter()
                .map(|a| Choice {
                    name: a.value.name.clone(),
                    model: a
                        .value
                        .model
                        .clone()
                        .or_else(|| loaded.config.model.clone())
                        .unwrap_or_else(|| "-".into()),
                    about: a.value.description.clone().unwrap_or_default(),
                    hue: hue_of(&a.value),
                })
                .collect();
            pick(choices)
        }
        Plan::SetUp => match setup::run(settings).await? {
            Some(made) => Ok(Start::Chat(Some(made))),
            None => Ok(Start::Leave),
        },
    }
}

/// One Imp in the list.
#[derive(Debug, Clone)]
pub(super) struct Choice {
    name: String,
    model: String,
    about: String,
    hue: f64,
}

/// The list of Imps.
pub(super) struct Picker {
    choices: Vec<Choice>,
    selected: usize,
}

impl Picker {
    pub(super) fn new(choices: Vec<Choice>) -> Self {
        Self {
            choices,
            selected: 0,
        }
    }

    pub(super) fn on_key(&mut self, key: KeyEvent) -> Step<String> {
        let last = self.choices.len().saturating_sub(1);
        match key.code {
            KeyCode::Up => self.selected = self.selected.saturating_sub(1),
            KeyCode::Down => self.selected = (self.selected + 1).min(last),
            KeyCode::Home => self.selected = 0,
            KeyCode::End => self.selected = last,
            KeyCode::Enter => return Step::Done(self.choices[self.selected].name.clone()),
            _ if leaves(key) => return Step::Leave,
            _ => {}
        }
        Step::Stay
    }

    pub(super) fn render(&self, frame: &mut Frame, theme: &Theme, lang: Lang) {
        let page = page(frame.area());
        let rows = usize::from(page.height.saturating_sub(4)).max(1);
        // Scrolls just enough to keep the selected Imp on screen.
        let first = (self.selected + 1).saturating_sub(rows);
        let name_width = self
            .choices
            .iter()
            .map(|c| text_width(&c.name))
            .max()
            .unwrap_or(0)
            .min(24);
        let model_width = self
            .choices
            .iter()
            .map(|c| text_width(&c.model))
            .max()
            .unwrap_or(0)
            .min(32);
        let mut lines = vec![
            Line::styled(strings::text(lang, "cli.start.pick_title"), theme.strong()),
            Line::raw(""),
        ];
        for (i, choice) in self.choices.iter().enumerate().skip(first).take(rows) {
            let chosen = i == self.selected;
            let name = pad(&truncate(&choice.name, name_width), name_width);
            let model = pad(&truncate(&choice.model, model_width), model_width);
            let used = 4 + name_width + 2 + model_width + 2;
            let about = truncate(&choice.about, usize::from(page.width).saturating_sub(used));
            lines.push(Line::from(vec![
                Span::styled(if chosen { "› " } else { "  " }, theme.text()),
                Span::styled("●", theme.hue(choice.hue)),
                Span::raw(" "),
                Span::styled(name, if chosen { theme.strong() } else { theme.text() }),
                Span::styled(format!("  {model}  {about}"), theme.muted()),
            ]));
        }
        frame.render_widget(Paragraph::new(lines), page);
        footer(
            frame,
            page,
            theme,
            strings::text(lang, "cli.start.pick_footer"),
        );
    }
}

/// Shows the list until an Imp is chosen or the person leaves.
fn pick(choices: Vec<Choice>) -> Result<Start> {
    let mut picker = Picker::new(choices);
    let (theme, lang) = (Theme::detect(), Lang::detect());
    let (_guard, mut terminal) = Restore::start()?;
    loop {
        terminal.draw(|frame| picker.render(frame, &theme, lang))?;
        if let Some(key) = next_key()? {
            match picker.on_key(key) {
                Step::Stay => {}
                Step::Done(name) => return Ok(Start::Chat(Some(name))),
                Step::Leave => return Ok(Start::Leave),
            }
        }
    }
}

/// The next key press, or `None` for anything else that happens (a resize still redraws).
pub(super) fn next_key() -> Result<Option<KeyEvent>> {
    match read().map_err(|e| CliError(e.to_string()))? {
        Event::Key(key) if key.kind != KeyEventKind::Release => Ok(Some(key)),
        _ => Ok(None),
    }
}

/// The next key press or paste, or `None` for anything else that happens.
pub(super) fn next_input() -> Result<Option<Input>> {
    match read().map_err(|e| CliError(e.to_string()))? {
        Event::Key(key) if key.kind != KeyEventKind::Release => Ok(Some(Input::Key(key))),
        Event::Paste(text) => Ok(Some(Input::Paste(text))),
        _ => Ok(None),
    }
}

/// What the person did at a step with a field.
pub(super) enum Input {
    Key(KeyEvent),
    Paste(String),
}

/// Esc, Ctrl-C and Ctrl-D leave.
pub(super) fn leaves(key: KeyEvent) -> bool {
    key.code == KeyCode::Esc
        || (key.modifiers.contains(KeyModifiers::CONTROL)
            && matches!(key.code, KeyCode::Char('c' | 'd')))
}

/// Where the text goes: a margin round the screen, and a line length that reads well.
pub(super) fn page(area: Rect) -> Rect {
    let width = area.width.saturating_sub(4).min(80);
    Rect::new(
        area.x + 2.min(area.width),
        area.y + 1.min(area.height),
        width,
        area.height.saturating_sub(2),
    )
}

/// The last line of the page: what the keys do.
pub(super) fn footer(frame: &mut Frame, page: Rect, theme: &Theme, text: &str) {
    if page.height == 0 {
        return;
    }
    let row = Rect::new(page.x, page.y + page.height - 1, page.width, 1);
    frame.render_widget(Paragraph::new(Line::styled(text, theme.muted())), row);
}

/// `text` with spaces after it up to `width` columns.
pub(super) fn pad(text: &str, width: usize) -> String {
    let fill = width.saturating_sub(text_width(text));
    format!("{text}{}", " ".repeat(fill))
}

#[cfg(test)]
mod tests {
    use super::*;
    use ratatui::Terminal;
    use ratatui::backend::TestBackend;

    fn key(code: KeyCode) -> KeyEvent {
        KeyEvent::new(code, KeyModifiers::NONE)
    }

    fn choices() -> Vec<Choice> {
        [
            ("pip", "remote/gpt", "Keeps answers short"),
            ("sage", "local/qwen", ""),
            ("zoë", "remote/x", "Reads a lot"),
        ]
        .into_iter()
        .map(|(name, model, about)| Choice {
            name: name.into(),
            model: model.into(),
            about: about.into(),
            hue: 0.3,
        })
        .collect()
    }

    fn screen(picker: &Picker, w: u16, h: u16) -> Vec<String> {
        let mut terminal = Terminal::new(TestBackend::new(w, h)).unwrap();
        terminal
            .draw(|f| picker.render(f, &Theme::new(true, false), Lang::En))
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
    fn nothing_is_asked_when_there_is_no_terminal_or_a_name() {
        for imps in [0, 1, 5] {
            assert_eq!(plan(false, imps, false), Plan::Open, "{imps} Imps");
            assert_eq!(plan(true, imps, true), Plan::Open, "{imps} Imps");
        }
    }

    #[test]
    fn a_terminal_without_a_name_picks_or_sets_up() {
        assert_eq!(plan(false, 0, true), Plan::SetUp);
        assert_eq!(plan(false, 1, true), Plan::Open);
        assert_eq!(plan(false, 2, true), Plan::Pick);
    }

    #[test]
    fn arrows_move_and_enter_chooses() {
        let mut picker = Picker::new(choices());
        picker.on_key(key(KeyCode::Up));
        assert_eq!(picker.selected, 0);
        picker.on_key(key(KeyCode::Down));
        picker.on_key(key(KeyCode::Down));
        picker.on_key(key(KeyCode::Down));
        assert_eq!(picker.selected, 2);
        picker.on_key(key(KeyCode::Home));
        picker.on_key(key(KeyCode::Down));
        assert!(matches!(
            picker.on_key(key(KeyCode::Enter)),
            Step::Done(name) if name == "sage"
        ));
    }

    #[test]
    fn escape_and_control_c_leave() {
        let mut picker = Picker::new(choices());
        assert!(matches!(picker.on_key(key(KeyCode::Esc)), Step::Leave));
        let ctrl_c = KeyEvent::new(KeyCode::Char('c'), KeyModifiers::CONTROL);
        assert!(matches!(picker.on_key(ctrl_c), Step::Leave));
        assert!(matches!(picker.on_key(key(KeyCode::Char('c'))), Step::Stay));
    }

    #[test]
    fn the_list_shows_name_model_and_description_on_one_line() {
        let mut picker = Picker::new(choices());
        let rows = screen(&picker, 50, 10);
        assert_eq!(rows[1], "  Who do you want to talk to?");
        assert_eq!(rows[3], "  › ● pip   remote/gpt  Keeps answers short");
        assert_eq!(rows[4], "    ● sage  local/qwen");
        assert_eq!(rows[5], "    ● zoë   remote/x    Reads a lot");
        assert_eq!(rows[8], "  ↑ ↓ choose · Enter open · Esc quit");
        picker.on_key(key(KeyCode::Down));
        assert!(screen(&picker, 50, 10)[4].starts_with("  › ● sage"));
    }

    #[test]
    fn a_long_list_scrolls_to_keep_the_choice_in_view() {
        let many = (0..20)
            .map(|i| Choice {
                name: format!("imp{i:02}"),
                model: "m/x".into(),
                about: String::new(),
                hue: 0.1,
            })
            .collect();
        let mut picker = Picker::new(many);
        picker.on_key(key(KeyCode::End));
        let rows = screen(&picker, 40, 8);
        assert!(rows.iter().any(|r| r.contains("› ● imp19")), "{rows:?}");
        assert!(!rows.iter().any(|r| r.contains("imp00")));
    }
}
