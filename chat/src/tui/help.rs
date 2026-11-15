//! The help card: every key, and what is on the screen, in a few plain words.

use super::App;
use super::text::{text_width, wrap};
use crate::strings::{self, Lang};
use ratatui::layout::Rect;
use ratatui::text::{Line, Span};
use ratatui::widgets::{Clear, Paragraph};
use ratatui::{Frame, style::Modifier};

/// One line of the help: what to press (or look at) and what it does.
pub struct Binding {
    pub keys: &'static str,
    /// The keys are a word in the language files, not a key name.
    pub keys_are_words: bool,
    pub text: &'static str,
}

const fn key(keys: &'static str, text: &'static str) -> Binding {
    Binding {
        keys,
        keys_are_words: false,
        text,
    }
}

const fn word(keys: &'static str, text: &'static str) -> Binding {
    Binding {
        keys,
        keys_are_words: true,
        text,
    }
}

/// Groups of bindings, shown with a blank line between them. Every key `App::on_key` and
/// `App::submit` answer to is here, and a test checks that the card shows them all.
pub const GROUPS: &[&[Binding]] = &[
    &[
        key("Enter", "cli.help.send"),
        key("Alt+Enter", "cli.help.newline"),
        key("Shift+Enter", "cli.help.newline"),
        key("Ctrl+J", "cli.help.newline_ctrl"),
        key("Ctrl+U", "cli.help.clear_input"),
        key("Backspace", "cli.help.erase"),
        key("Ctrl+W", "cli.help.erase_word"),
        key("Left Right", "cli.help.move_cursor"),
        key("Alt+← Alt+→", "cli.help.word_move"),
        key("Home End", "cli.help.line_ends"),
        key("Ctrl+P Ctrl+N", "cli.help.recall"),
        key("/", "cli.help.menu"),
        key("Tab Right", "cli.help.complete"),
    ],
    &[
        key("Up Down", "cli.help.scroll_line"),
        key("PgUp PgDn", "cli.help.scroll_page"),
        key("End", "cli.help.scroll_end"),
        word("cli.help.key_wheel", "cli.help.wheel"),
    ],
    &[
        key("Esc", "cli.help.stop_or_quit"),
        key("Ctrl+C", "cli.help.quit"),
        key("Ctrl+D", "cli.help.quit_empty"),
        key("/help", "cli.help.commands"),
        key("/quit", "cli.help.leave"),
        key("/clear", "cli.help.new_chat"),
        key("?", "cli.help.open"),
        key("F1", "cli.help.open_any"),
    ],
    &[
        key("●", "cli.help.imp"),
        key("›", "cli.help.you"),
        key("⏺ ⇢", "cli.help.tool"),
        word("cli.help.key_status", "cli.help.activity"),
    ],
];

impl Binding {
    pub fn label(&self, lang: Lang) -> &'static str {
        if self.keys_are_words {
            strings::text(lang, self.keys)
        } else {
            self.keys
        }
    }
}

/// The lines of the card for an inner width: a title, the groups, and how to close it.
fn lines(app: &App, inner: usize, compact: bool) -> Vec<Line<'static>> {
    let (lang, theme) = (app.lang, &app.theme);
    let all = || GROUPS.iter().flat_map(|g| g.iter());
    let key_width = all().map(|b| text_width(b.label(lang))).max().unwrap_or(0);
    let mut out = vec![Line::styled(
        strings::text(lang, "cli.help.title"),
        theme.text().add_modifier(Modifier::BOLD),
    )];
    for group in GROUPS {
        if !compact {
            out.push(Line::raw(""));
        }
        for b in *group {
            let (label, said) = (b.label(lang), strings::text(lang, b.text));
            if key_width + 2 + text_width(said) <= inner {
                let pad = " ".repeat(key_width - text_width(label) + 2);
                out.push(Line::from(vec![
                    Span::styled(label, theme.text().add_modifier(Modifier::BOLD)),
                    Span::styled(format!("{pad}{said}"), theme.text()),
                ]));
            } else {
                out.push(Line::styled(
                    label,
                    theme.text().add_modifier(Modifier::BOLD),
                ));
                for l in wrap(said, inner.saturating_sub(2)) {
                    out.push(Line::styled(format!("  {l}"), theme.text()));
                }
            }
        }
    }
    out.push(Line::raw(""));
    out.push(Line::styled(
        strings::text(lang, "cli.help.close"),
        theme.muted(),
    ));
    out
}

/// Draws the card in the middle of `area`, as wide as its words and no wider than the screen.
pub fn render(app: &App, frame: &mut Frame, area: Rect) {
    let lang = app.lang;
    let key_width = GROUPS
        .iter()
        .flat_map(|g| g.iter())
        .map(|b| text_width(b.label(lang)))
        .max()
        .unwrap_or(0);
    let widest_text = GROUPS
        .iter()
        .flat_map(|g| g.iter())
        .map(|b| text_width(strings::text(lang, b.text)))
        .chain([strings::text(lang, "cli.help.close")].map(text_width))
        .max()
        .unwrap_or(0);
    let pad = 2;
    let inner = (key_width + 2 + widest_text)
        .min((area.width as usize).saturating_sub(pad * 2))
        .max(1);
    let mut content = lines(app, inner, false);
    if content.len() + 2 > area.height as usize {
        // Without the blank lines between the groups, so every key still shows on a short screen.
        content = lines(app, inner, true);
    }
    let width = (inner + pad * 2).min(area.width as usize) as u16;
    let height = (content.len() + 2).min(area.height as usize) as u16;
    let card = Rect::new(
        area.x + (area.width - width) / 2,
        area.y + (area.height - height) / 2,
        width,
        height,
    );
    frame.render_widget(Clear, card);
    frame.buffer_mut().set_style(card, app.theme.raised());
    let body = Rect::new(
        card.x + pad as u16,
        card.y + 1,
        inner as u16,
        height.saturating_sub(2),
    );
    frame.render_widget(Paragraph::new(content), body.intersection(card));
}
