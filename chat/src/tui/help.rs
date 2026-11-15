//! The help card: every key, and what is on the screen, in a few plain words. On a short screen it
//! drops its blank lines, then takes two columns if the screen is wide, and else scrolls.

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
        key("Up Down", "cli.help.up_down"),
        key("Ctrl+P Ctrl+N", "cli.help.recall"),
        key("/", "cli.help.menu"),
        key("@", "cli.help.files"),
        key("Tab Right", "cli.help.complete"),
    ],
    &[
        key("Shift+↑ Shift+↓", "cli.help.scroll_line"),
        key("PgUp PgDn", "cli.help.scroll_page"),
        key("End", "cli.help.scroll_end"),
        word("cli.help.key_wheel", "cli.help.wheel"),
        word("cli.help.key_drag", "cli.help.select"),
        word("cli.help.key_double_click", "cli.help.select_word"),
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

/// The widest key label.
fn key_width(lang: Lang) -> usize {
    GROUPS
        .iter()
        .flat_map(|g| g.iter())
        .map(|b| text_width(b.label(lang)))
        .max()
        .unwrap_or(0)
}

/// The lines of some groups for an inner width, with a blank line before each group unless `compact`.
fn group_lines(
    app: &App,
    groups: &[&[Binding]],
    inner: usize,
    compact: bool,
) -> Vec<Line<'static>> {
    let (lang, theme) = (app.lang, &app.theme);
    let key_width = key_width(lang);
    let mut out = Vec::new();
    for group in groups {
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
    out
}

/// The title, `body`, and how to close the card.
fn framed(app: &App, body: Vec<Line<'static>>) -> Vec<Line<'static>> {
    let mut out = vec![Line::styled(
        strings::text(app.lang, "cli.help.title"),
        app.theme.text().add_modifier(Modifier::BOLD),
    )];
    out.extend(body);
    out.push(Line::raw(""));
    out.push(Line::styled(
        strings::text(app.lang, "cli.help.close"),
        app.theme.muted(),
    ));
    out
}

/// The groups in two columns of `column` width each, `gap` apart, split where the columns are most even.
fn two_columns(app: &App, column: usize, gap: usize) -> Vec<Line<'static>> {
    let split = (1..GROUPS.len())
        .min_by_key(|k| {
            let left = group_lines(app, &GROUPS[..*k], column, true).len();
            let right = group_lines(app, &GROUPS[*k..], column, true).len();
            left.max(right)
        })
        .unwrap_or(1);
    let left = group_lines(app, &GROUPS[..split], column, true);
    let right = group_lines(app, &GROUPS[split..], column, true);
    let mut out = vec![Line::raw("")];
    for i in 0..left.len().max(right.len()) {
        let mut spans: Vec<Span<'static>> = Vec::new();
        let mut used = 0;
        if let Some(l) = left.get(i) {
            used = l.width();
            spans.extend(l.spans.iter().cloned());
        }
        if let Some(r) = right.get(i) {
            spans.push(Span::raw(" ".repeat(column.saturating_sub(used) + gap)));
            spans.extend(r.spans.iter().cloned());
        }
        out.push(Line::from(spans));
    }
    out
}

/// Draws the card in the middle of `area`, as wide as its words and no wider than the screen.
pub fn render(app: &App, frame: &mut Frame, area: Rect) {
    let lang = app.lang;
    let key_width = key_width(lang);
    let widest_text = GROUPS
        .iter()
        .flat_map(|g| g.iter())
        .map(|b| text_width(strings::text(lang, b.text)))
        .chain([strings::text(lang, "cli.help.close")].map(text_width))
        .max()
        .unwrap_or(0);
    let pad = 2;
    let gap = 3;
    let screen_width = area.width as usize;
    let room = (area.height as usize).saturating_sub(2);
    let natural = key_width + 2 + widest_text;
    let mut inner = natural.min(screen_width.saturating_sub(pad * 2)).max(1);
    let mut content = framed(app, group_lines(app, GROUPS, inner, false));
    if content.len() > room {
        // Without the blank lines between the groups, so every key still shows on a short screen.
        content = framed(app, group_lines(app, GROUPS, inner, true));
    }
    if content.len() > room {
        // Side by side, when the screen is wide enough for the words to wrap only a little.
        let column = (natural.min(screen_width.saturating_sub(pad * 2 + gap) / 2)).max(1);
        if column >= key_width + 24 {
            let two = framed(app, two_columns(app, column, gap));
            if two.len() <= room || two.len() < content.len() {
                content = two;
                inner = column * 2 + gap;
            }
        }
    }
    // Still too tall: it scrolls, and its last line says how.
    let scrolls = content.len() > room && room >= 3;
    if scrolls {
        let visible = room - 1;
        let most = content.len() - visible;
        let from = app.help_scroll.get().min(most);
        app.help_scroll.set(from);
        let mut shown: Vec<Line<'static>> = content.drain(from..from + visible).collect();
        let up = if from > 0 { "↑ " } else { "  " };
        let down = if from < most { "↓ " } else { "  " };
        shown.push(Line::styled(
            format!("{up}{down}{}", strings::text(lang, "cli.chat.help_scroll")),
            app.theme.muted(),
        ));
        content = shown;
    }
    let width = (inner + pad * 2).min(screen_width) as u16;
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
        (inner as u16).min(width.saturating_sub(pad as u16)),
        height.saturating_sub(2),
    );
    frame.render_widget(Paragraph::new(content), body.intersection(card));
}
