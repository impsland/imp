use super::help::GROUPS;
use super::text::wrap;
use super::*;
use crate::strings::Lang;
use crate::theme::Theme;
use imp_core::{RetryNotice, StreamEvent, ToolCall};
use ratatui::Terminal;
use ratatui::backend::TestBackend;
use ratatui::crossterm::event::{
    KeyCode, KeyEvent, KeyEventKind, KeyModifiers, MouseEvent, MouseEventKind,
};
use std::time::Duration;

fn key(code: KeyCode) -> KeyEvent {
    KeyEvent::new(code, KeyModifiers::NONE)
}

fn with(code: KeyCode, m: KeyModifiers) -> KeyEvent {
    KeyEvent::new(code, m)
}

fn type_text(app: &mut App, text: &str) {
    for c in text.chars() {
        app.on_key(key(KeyCode::Char(c)));
    }
}

fn screen(app: &App, w: u16, h: u16) -> Vec<String> {
    let mut terminal = Terminal::new(TestBackend::new(w, h)).unwrap();
    terminal.draw(|f| app.render(f)).unwrap();
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

fn answer(app: &mut App, text: &str) {
    for e in [
        AgentEvent::StepStart,
        AgentEvent::Stream(StreamEvent::Text(text.into())),
        AgentEvent::StepEnd,
    ] {
        app.on_agent(&e);
    }
    app.on_done(Ok(()));
}

#[test]
fn wrapping_keeps_breaks_and_splits_long_words() {
    assert_eq!(wrap("one two three", 7), ["one two", "three"]);
    assert_eq!(wrap("a\n\nb", 10), ["a", "", "b"]);
    assert_eq!(wrap("abcdefgh", 3), ["abc", "def", "gh"]);
    assert_eq!(wrap("", 5), [""]);
    assert_eq!(wrap("x", 0), ["x"]);
    assert_eq!(wrap("日本語日本語", 6), ["日本語", "日本語"]);
}

#[test]
fn the_visible_window() {
    assert_eq!(visible_start(3, 10, 0), (0, 0));
    assert_eq!(visible_start(30, 10, 0), (20, 20));
    assert_eq!(visible_start(30, 10, 5), (15, 20));
    assert_eq!(visible_start(30, 10, 99), (0, 20));
}

#[test]
fn typing_editing_and_sending() {
    let mut app = App::new("pip", "m", "sys");
    type_text(&mut app, "helo");
    app.on_key(key(KeyCode::Backspace));
    type_text(&mut app, "lo");
    assert_eq!(app.input(), "hello");
    assert_eq!(
        app.on_key(key(KeyCode::Enter)),
        Action::Send("hello".into())
    );
    assert_eq!(app.input(), "");
    assert!(app.is_waiting());
    assert_eq!(app.chat.messages().len(), 1);
    // Nothing is sent while the answer is on its way.
    type_text(&mut app, "more");
    assert_eq!(app.on_key(key(KeyCode::Enter)), Action::None);
    assert_eq!(app.input(), "more");
    answer(&mut app, "Hi");
    assert!(!app.is_waiting());
    assert_eq!(app.on_key(key(KeyCode::Enter)), Action::Send("more".into()));
}

#[test]
fn empty_input_sends_nothing_and_newlines_are_kept() {
    let mut app = App::new("pip", "m", "sys");
    assert_eq!(app.on_key(key(KeyCode::Enter)), Action::None);
    type_text(&mut app, "a");
    app.on_key(with(KeyCode::Enter, KeyModifiers::ALT));
    type_text(&mut app, "b");
    app.on_key(with(KeyCode::Enter, KeyModifiers::SHIFT));
    app.on_key(with(KeyCode::Char('j'), KeyModifiers::CONTROL));
    type_text(&mut app, "c");
    assert_eq!(app.input(), "a\nb\n\nc");
    app.on_paste("x\r\ny");
    assert_eq!(app.input(), "a\nb\n\ncx\ny");
    app.on_key(with(KeyCode::Char('u'), KeyModifiers::CONTROL));
    assert_eq!(app.input(), "");
}

#[test]
fn leaving_and_commands() {
    let mut app = App::new("pip", "m", "sys");
    assert_eq!(app.on_key(key(KeyCode::Esc)), Action::Quit);
    assert_eq!(
        app.on_key(with(KeyCode::Char('c'), KeyModifiers::CONTROL)),
        Action::Quit
    );
    assert_eq!(
        app.on_key(with(KeyCode::Char('d'), KeyModifiers::CONTROL)),
        Action::Quit
    );
    type_text(&mut app, "/quit");
    assert_eq!(app.on_key(key(KeyCode::Enter)), Action::Quit);
    let mut app = App::new("pip", "m", "sys");
    type_text(&mut app, "hi");
    app.on_key(key(KeyCode::Enter));
    answer(&mut app, "yo");
    type_text(&mut app, "/clear");
    assert_eq!(app.on_key(key(KeyCode::Enter)), Action::None);
    assert!(app.chat.messages().is_empty());
    let mut released = key(KeyCode::Esc);
    released.kind = KeyEventKind::Release;
    assert_eq!(app.on_key(released), Action::None);
}

#[test]
fn scrolling_stays_inside_the_transcript() {
    let mut app = App::new("pip", "m", "sys");
    for i in 0..12 {
        type_text(&mut app, &format!("question {i}"));
        app.on_key(key(KeyCode::Enter));
        answer(&mut app, &format!("answer {i}"));
    }
    let before = screen(&app, 40, 12);
    assert!(before.iter().any(|l| l.contains("answer 11")));
    assert!(!before.iter().any(|l| l.contains("question 0")));
    app.on_key(key(KeyCode::PageUp));
    assert!(app.scroll() > 0);
    let after = screen(&app, 40, 12);
    assert!(!after.iter().any(|l| l.contains("answer 11")));
    for _ in 0..20 {
        app.on_key(key(KeyCode::PageUp));
    }
    let top = screen(&app, 40, 12);
    assert!(top.iter().any(|l| l.contains("question 0")));
    let max = app.scroll();
    app.on_key(key(KeyCode::PageUp));
    assert_eq!(app.scroll(), max);
    app.on_key(key(KeyCode::End));
    assert_eq!(app.scroll(), 0);
    app.on_mouse(MouseEvent {
        kind: MouseEventKind::ScrollUp,
        column: 0,
        row: 0,
        modifiers: KeyModifiers::NONE,
    });
    assert_eq!(app.scroll(), WHEEL_LINES);
    app.on_key(key(KeyCode::PageDown));
    assert_eq!(app.scroll(), 0);
}

#[test]
fn the_screen_shows_transcript_input_and_status() {
    let mut app = chatty();
    type_text(&mut app, "draft");
    let rows = screen(&app, 24, 12);
    let text = rows.join("\n");
    assert!(rows[0].starts_with("› Hello there,"), "{text}");
    assert!(text.contains("● Well hi, this"), "{text}");
    assert!(text.contains('▌'));
    assert!(rows[9].contains("› draft"), "{text}");
    assert!(rows[11].starts_with("● pip · gpt-5"), "{text}");
    assert!(rows[11].contains("Answering"), "{text}");
}

#[test]
fn status_shows_retries_and_tools() {
    let mut app = App::new("pip", "m", "sys");
    assert_eq!(app.activity(), "Ready");
    type_text(&mut app, "go");
    app.on_key(key(KeyCode::Enter));
    assert_eq!(app.activity(), "Thinking");
    app.on_agent(&AgentEvent::StepStart);
    app.on_agent(&AgentEvent::Retry(RetryNotice {
        attempt: 2,
        of: 3,
        delay: Duration::ZERO,
    }));
    assert_eq!(app.activity(), "Retrying 2 of 3");
    assert!(screen(&app, 60, 8)[7].contains("Retrying 2 of 3"));
    app.on_agent(&AgentEvent::Stream(StreamEvent::ToolCallDelta {
        index: 0,
        id: Some("c".into()),
        name: Some("files__read".into()),
        arguments: "{}".into(),
    }));
    app.on_agent(&AgentEvent::StepEnd);
    app.on_agent(&AgentEvent::ToolStart(ToolCall {
        id: "c".into(),
        name: "files__read".into(),
        arguments: "{}".into(),
    }));
    assert_eq!(app.activity(), "Using the tool files__read");
    app.on_agent(&AgentEvent::ToolResult {
        call_id: "c".into(),
        name: "files__read".into(),
        content: "contents\nsecond line".into(),
    });
    let text = screen(&app, 60, 10).join("\n");
    assert!(text.contains("pip uses the tool files__read"), "{text}");
    assert!(text.contains("result: contents"), "{text}");
    assert!(!text.contains("second line"));
}

#[test]
fn a_failed_answer_keeps_what_arrived_and_shows_the_problem() {
    let mut app = App::new("pip", "m", "sys");
    type_text(&mut app, "go");
    app.on_key(key(KeyCode::Enter));
    app.on_agent(&AgentEvent::StepStart);
    app.on_agent(&AgentEvent::Stream(StreamEvent::Text("Half".into())));
    app.on_done(Err("the service answered 500: oops".into()));
    assert!(!app.chat.is_streaming());
    assert_eq!(app.chat.messages().last().unwrap().content, "Half");
    let text = screen(&app, 50, 10).join("\n");
    assert!(
        text.contains("Something went wrong: the service answered 500"),
        "{text}"
    );
    assert_eq!(app.activity(), "Ready");
}

#[test]
fn a_tiny_terminal_does_not_panic() {
    let mut app = App::new("pip", "m", "sys");
    type_text(
        &mut app,
        "hello\nthere\nfriend\nof\nmine\nand\nmore\nlines\nhere",
    );
    for (w, h) in [(1, 1), (3, 4), (10, 3), (80, 2)] {
        let _ = screen(&app, w, h);
    }
}

fn app(imp: &str, model: &str) -> App {
    App::new(imp, model, "sys").styled(Lang::En, Theme::new(false, false))
}

/// A chat in the middle of an answer, with a long Imp reply.
fn chatty() -> App {
    let mut app = app("pip", "gpt-5");
    type_text(&mut app, "Hello there, little friend");
    app.on_key(key(KeyCode::Enter));
    app.on_agent(&AgentEvent::StepStart);
    app.on_agent(&AgentEvent::Stream(StreamEvent::Text(
        "Well hi, this answer wraps around".into(),
    )));
    app
}

const BOXES: &str = "─│┌┐└┘├┤┬┴┼═║╔╗╚╝╠╣╦╩╬━┃┏┓┗┛";

/// Every main screen: waiting for words, mid-answer with a draft, a problem, and the help card.
fn main_screens() -> Vec<(&'static str, App)> {
    let mut empty = app("pip", "gpt-5");
    let mut failed = chatty();
    failed.on_done(Err("the service answered 500: oops".into()));
    let mut helped = chatty();
    helped.on_key(key(KeyCode::F(1)));
    let mut tooled = chatty();
    tooled.on_agent(&AgentEvent::StepEnd);
    tooled.on_agent(&AgentEvent::ToolStart(ToolCall {
        id: "c".into(),
        name: "files__read".into(),
        arguments: "{}".into(),
    }));
    empty.on_key(key(KeyCode::Char('?')));
    vec![
        ("help on empty", empty),
        ("answering", chatty()),
        ("problem", failed),
        ("help", helped),
        ("tool", tooled),
    ]
}

#[test]
fn screens_have_no_borders_no_separator_lines_and_fit_the_width() {
    for (name, app) in main_screens() {
        for width in [80u16, 40, 36] {
            for row in screen(&app, width, 30) {
                let shown = row.chars().count();
                assert!(
                    text_cols(&row) <= width as usize,
                    "{name} at {width}: {row:?}"
                );
                assert!(
                    !row.chars().any(|c| BOXES.contains(c)),
                    "{name} at {width}: {row:?}"
                );
                let rule = shown > 2
                    && row
                        .chars()
                        .all(|c| matches!(c, '-' | '_' | '=' | '.' | '·' | ' '));
                assert!(
                    !rule || row.trim().is_empty(),
                    "{name} at {width}: separator {row:?}"
                );
            }
        }
    }
}

fn text_cols(s: &str) -> usize {
    super::text::text_width(s)
}

#[test]
fn the_help_card_lists_every_key_and_is_not_full_width() {
    let mut app = chatty();
    app.on_key(key(KeyCode::F(1)));
    assert!(app.is_help_open());
    let rows = screen(&app, 80, 30);
    let text = rows.join("\n");
    for group in GROUPS {
        for b in *group {
            assert!(
                text.contains(b.label(Lang::En)),
                "missing {}\n{text}",
                b.keys
            );
            assert!(
                text.contains(crate::strings::text(Lang::En, b.text)),
                "missing {}\n{text}",
                b.text
            );
        }
    }
    let widest = rows.iter().map(|r| text_cols(r)).max().unwrap_or(0);
    let card = rows
        .iter()
        .filter(|r| r.contains("Enter"))
        .map(|r| text_cols(r))
        .max()
        .unwrap_or(0);
    assert!(card < 80 && widest <= 80, "{text}");
    let narrow = screen(&app, 36, 40).join("\n");
    for group in GROUPS {
        for b in *group {
            assert!(
                narrow.contains(b.label(Lang::En)),
                "missing {} at 36\n{narrow}",
                b.keys
            );
        }
    }
}

#[test]
fn every_key_the_chat_answers_is_in_the_help() {
    let listed: Vec<&str> = GROUPS
        .iter()
        .flat_map(|g| g.iter())
        .map(|b| b.keys)
        .collect();
    for needed in [
        "Enter",
        "Alt+Enter",
        "Shift+Enter",
        "Ctrl+J",
        "Ctrl+U",
        "Backspace",
        "Up Down",
        "PgUp PgDn",
        "End",
        "Esc",
        "Ctrl+C",
        "Ctrl+D",
        "/quit",
        "/clear",
        "?",
        "F1",
    ] {
        assert!(listed.contains(&needed), "{needed} is not in the help");
    }
}

#[test]
fn the_help_opens_with_a_question_mark_only_when_nothing_is_written() {
    let mut app = app("pip", "m");
    app.on_key(key(KeyCode::Char('?')));
    assert!(app.is_help_open());
    assert_eq!(
        app.on_key(key(KeyCode::Esc)),
        Action::None,
        "a key closes the card first"
    );
    assert!(!app.is_help_open());
    type_text(&mut app, "why?");
    assert_eq!(app.input(), "why?");
    assert!(!app.is_help_open());
    app.on_key(key(KeyCode::F(1)));
    assert!(app.is_help_open());
}

#[test]
fn the_terminals_own_background_is_the_surface() {
    let app = chatty();
    let mut terminal = Terminal::new(TestBackend::new(60, 12)).unwrap();
    terminal.draw(|f| app.render(f)).unwrap();
    let buffer = terminal.backend().buffer().clone();
    // Only the message field has a fill. The transcript and the status line keep the default background.
    for x in 0..60 {
        assert_eq!(buffer[(x, 0)].bg, ratatui::style::Color::Reset);
        assert_eq!(buffer[(x, 11)].bg, ratatui::style::Color::Reset);
    }
    assert_ne!(buffer[(5, 9)].bg, ratatui::style::Color::Reset);
    let plain = App::new("pip", "m", "s").styled(Lang::En, Theme::new(true, false));
    let mut terminal = Terminal::new(TestBackend::new(60, 12)).unwrap();
    terminal.draw(|f| plain.render(f)).unwrap();
    assert!(
        terminal
            .backend()
            .buffer()
            .content()
            .iter()
            .all(|c| c.fg == ratatui::style::Color::Reset && c.bg == ratatui::style::Color::Reset)
    );
}

#[test]
fn the_words_follow_the_language() {
    let app = App::new("pip", "m", "s").styled(Lang::Es, Theme::new(true, false));
    assert_eq!(app.activity(), "Listo");
    assert!(
        screen(&app, 60, 6)
            .join("\n")
            .contains("Escribe un mensaje")
    );
}

/// Prints the main screen at 60 columns when run with `--nocapture`.
#[test]
fn the_main_screen_at_sixty_columns() {
    let mut app = app("pip", "gpt-5");
    type_text(&mut app, "What can you do?");
    app.on_key(key(KeyCode::Enter));
    answer(&mut app, "I can chat, remember things and use tools.");
    type_text(&mut app, "Show me");
    let rows = screen(&app, 60, 10);
    println!("{}", rows.join("\n"));
    assert!(rows[0].starts_with("› What can you do?"));
}
