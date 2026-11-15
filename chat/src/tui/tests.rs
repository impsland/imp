use super::help::GROUPS;
use super::text::wrap;
use super::*;
use crate::strings::Lang;
use crate::theme::Theme;
use imp_engine::{RetryNotice, StreamEvent, ToolCall};
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
    // At 24 columns a long model is cut short, so the activity still shows.
    assert!(rows[11].starts_with("● pip · open"), "{text}");
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
    assert_eq!(app.activity(), "Using the tool read");
    let text = screen(&app, 60, 10).join("\n");
    assert!(text.contains("⏺ read()"), "{text}");
    assert!(text.contains("⎿ running…"), "{text}");
    app.on_agent(&AgentEvent::ToolResult {
        call_id: "c".into(),
        name: "files__read".into(),
        content: "contents\nsecond line".into(),
    });
    let text = screen(&app, 60, 10).join("\n");
    assert!(text.contains("⏺ read()"), "{text}");
    assert!(text.contains("⎿ contents (+1 lines)"), "{text}");
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
    let mut app = app("pip", "openai/gpt-6-luna");
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
    let mut empty = app("pip", "openai/gpt-6-luna");
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
    // The card has grown with the editing keys, so it needs a few more rows to show all of them.
    let rows = screen(&app, 80, 36);
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
    let narrow = screen(&app, 36, 56).join("\n");
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
        "Ctrl+W",
        "Left Right",
        "Alt+← Alt+→",
        "Home End",
        "Tab Right",
        "/",
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
    let mut app = app("pip", "openai/gpt-6-luna");
    type_text(&mut app, "What can you do?");
    app.on_key(key(KeyCode::Enter));
    answer(&mut app, "I can chat, remember things and use tools.");
    type_text(&mut app, "Show me");
    let rows = screen(&app, 60, 10);
    println!("{}", rows.join("\n"));
    assert!(rows[0].starts_with("› What can you do?"));
}

#[test]
fn a_slash_command_runs_and_shows_without_joining_the_conversation() {
    let mut app = app("pip", "m");
    type_text(&mut app, "/model gpt-x");
    assert_eq!(
        app.on_key(key(KeyCode::Enter)),
        Action::Command("/model gpt-x".into())
    );
    assert!(app.chat.messages().is_empty(), "commands are not messages");
    app.notes_from(vec![crate::slash::Note::info(
        "Saved. pip's model is gpt-x now.",
    )]);
    let text = screen(&app, 60, 10).join("\n");
    assert!(text.contains("› /model gpt-x"), "{text}");
    assert!(text.contains("Saved. pip's model is gpt-x now."), "{text}");
    // A key typed to /api_key never shows.
    type_text(&mut app, "/api_key sk-very-secret");
    assert!(matches!(
        app.on_key(key(KeyCode::Enter)),
        Action::Command(_)
    ));
    let text = screen(&app, 60, 12).join("\n");
    assert!(!text.contains("sk-very-secret"), "{text}");
    // `//` sends a message that starts with a slash.
    type_text(&mut app, "//etc/hosts is a file");
    assert_eq!(
        app.on_key(key(KeyCode::Enter)),
        Action::Send("/etc/hosts is a file".into())
    );
}

#[test]
fn commands_are_suggested_and_tab_completes_them() {
    let mut app = app("pip", "m");
    type_text(&mut app, "/mc");
    assert_eq!(app.suggestions()[0].name, "/mcp");
    let text = screen(&app, 80, 12).join("\n");
    assert!(text.contains("List, add or remove MCP servers"), "{text}");
    app.on_key(key(KeyCode::Tab));
    assert_eq!(app.input(), "/mcp ");
    assert!(
        app.suggestions().is_empty(),
        "no command names to suggest once arguments start"
    );
    app.on_key(with(KeyCode::Char('u'), KeyModifiers::CONTROL));
    type_text(&mut app, "/");
    assert!(app.suggestions().len() > 3);
}

fn names(app: &App) -> Vec<&'static str> {
    app.menu()
        .entries
        .iter()
        .filter_map(|e| e.command.map(|c| c.name))
        .collect()
}

fn highlighted(app: &App) -> String {
    let menu = app.menu();
    menu.entries[app.pick_in(menu.entries.len())].insert.clone()
}

#[test]
fn matches_are_ranked_prefix_first_then_contained_then_in_order() {
    let mut app = app("pip", "m");
    type_text(&mut app, "/api");
    assert_eq!(names(&app), ["/api_key", "/api_key_env"]);
    app.on_key(with(KeyCode::Char('u'), KeyModifiers::CONTROL));
    type_text(&mut app, "/key");
    // The alias of /api_key first, then names that contain it.
    assert_eq!(names(&app), ["/api_key", "/api_key_env"]);
    app.on_key(with(KeyCode::Char('u'), KeyModifiers::CONTROL));
    type_text(&mut app, "/pe");
    assert_eq!(names(&app)[0], "/personality");
    assert!(
        names(&app).contains(&"/api_key"),
        "letters in order: {:?}",
        names(&app)
    );
    app.on_key(with(KeyCode::Char('u'), KeyModifiers::CONTROL));
    type_text(&mut app, "/sd");
    assert_eq!(names(&app), ["/send"], "letters in order");
    assert_eq!(slash::suggest("/zzz"), Vec::<&slash::Command>::new());
}

#[test]
fn up_and_down_choose_in_the_list_and_wrap_around() {
    let mut app = app("pip", "m");
    type_text(&mut app, "/");
    let all = names(&app);
    assert!(all.len() > MOST_SUGGESTIONS);
    assert!(highlighted(&app).starts_with(all[0]));
    app.on_key(key(KeyCode::Up));
    assert!(
        highlighted(&app).starts_with(all[all.len() - 1]),
        "Up from the first wraps to the last"
    );
    app.on_key(key(KeyCode::Down));
    assert!(
        highlighted(&app).starts_with(all[0]),
        "Down from the last wraps to the first"
    );
    app.on_key(key(KeyCode::Down));
    assert!(highlighted(&app).starts_with(all[1]));
    assert_eq!(app.scroll(), 0, "the arrows did not scroll the chat");
    // Typing starts the choice over.
    type_text(&mut app, "m");
    assert!(highlighted(&app).starts_with(names(&app)[0]));
}

#[test]
fn the_list_scrolls_and_says_where_the_highlight_is() {
    let mut app = app("pip", "m");
    type_text(&mut app, "/");
    let total = names(&app).len();
    // The status line has arrows of its own, so only the line with the position is looked at.
    let footer = |rows: Vec<String>, at: String| {
        rows.into_iter()
            .find(|r| r.contains(&at))
            .unwrap_or_default()
    };
    let rows = screen(&app, 80, 24);
    let line = footer(rows.clone(), format!("1/{total}"));
    assert!(line.contains('↓') && !line.contains('↑'), "{rows:?}");
    app.on_key(key(KeyCode::Up));
    let rows = screen(&app, 80, 24);
    let line = footer(rows.clone(), format!("{total}/{total}"));
    assert!(line.contains('↑') && !line.contains('↓'), "{rows:?}");
    let last = format!(" › {}", slash::COMMANDS[total - 1].usage);
    assert!(rows.iter().any(|r| r.starts_with(&last)), "{rows:?}");
    let tiny = screen(&app, 40, 7).join("\n");
    assert!(tiny.contains(&format!("{total}/{total}")), "{tiny}");
}

#[test]
fn tab_and_right_accept_the_highlighted_command() {
    let mut app = app("pip", "m");
    type_text(&mut app, "/sen");
    assert_eq!(names(&app)[0], "/send");
    app.on_key(key(KeyCode::Tab));
    assert_eq!(
        app.input(),
        "/send ",
        "a command with arguments gets a space"
    );
    app.on_key(with(KeyCode::Char('u'), KeyModifiers::CONTROL));
    type_text(&mut app, "/pa");
    app.on_key(key(KeyCode::Right));
    assert_eq!(
        app.input(),
        "/pair",
        "a command without arguments gets none"
    );
    assert_eq!(app.cursor(), 5);
    app.on_key(with(KeyCode::Char('u'), KeyModifiers::CONTROL));
    type_text(&mut app, "/m");
    app.on_key(key(KeyCode::Down));
    let want = app.menu().entries[1].insert.clone();
    app.on_key(key(KeyCode::Tab));
    assert_eq!(app.input(), want);
}

#[test]
fn enter_runs_a_command_without_arguments_and_completes_one_that_needs_them() {
    let mut app = app("pip", "m");
    type_text(&mut app, "/pa");
    assert_eq!(
        app.on_key(key(KeyCode::Enter)),
        Action::Command("/pair".into())
    );
    assert_eq!(app.input(), "");
    type_text(&mut app, "/sen");
    assert_eq!(
        app.on_key(key(KeyCode::Enter)),
        Action::None,
        "half a command is not sent"
    );
    assert_eq!(app.input(), "/send ");
    // Optional arguments: it runs as it is.
    app.on_key(with(KeyCode::Char('u'), KeyModifiers::CONTROL));
    type_text(&mut app, "/mod");
    assert_eq!(
        app.on_key(key(KeyCode::Enter)),
        Action::Command("/model".into())
    );
    // With arguments typed, Enter sends what is there.
    type_text(&mut app, "/model gpt-6");
    assert_eq!(
        app.on_key(key(KeyCode::Enter)),
        Action::Command("/model gpt-6".into())
    );
    // Not a command: nothing is highlighted, so a message goes as before.
    type_text(&mut app, "/zzz");
    assert!(app.menu().entries.is_empty());
}

#[test]
fn esc_closes_the_list_first_and_leaves_the_second_time() {
    let mut app = app("pip", "m");
    type_text(&mut app, "/mc");
    assert!(!app.menu().entries.is_empty());
    assert_eq!(app.on_key(key(KeyCode::Esc)), Action::None);
    assert_eq!(app.input(), "/mc", "the text stays");
    assert!(app.menu().entries.is_empty());
    let text = screen(&app, 80, 12).join("\n");
    assert!(!text.contains("List, add or remove MCP servers"), "{text}");
    // Up and Down scroll the chat again while the list is closed.
    app.on_key(key(KeyCode::Up));
    assert_eq!(app.input(), "/mc");
    // Typing opens it again.
    type_text(&mut app, "p");
    assert!(!app.menu().entries.is_empty());
    app.on_key(key(KeyCode::Esc));
    assert_eq!(app.on_key(key(KeyCode::Esc)), Action::Quit);
    // Tab brings a closed list back.
    let mut app = self::app("pip", "m");
    type_text(&mut app, "/mc");
    app.on_key(key(KeyCode::Esc));
    app.on_key(key(KeyCode::Tab));
    assert!(!app.menu().entries.is_empty());
}

#[test]
fn the_list_is_not_there_while_waiting_or_on_several_lines() {
    let mut app = chatty();
    type_text(&mut app, "/mc");
    assert!(app.menu().entries.is_empty() && app.menu().hint.is_none());
    let mut app = self::app("pip", "m");
    type_text(&mut app, "/mc");
    app.on_key(with(KeyCode::Char('j'), KeyModifiers::CONTROL));
    assert!(app.menu().entries.is_empty());
}

#[test]
fn a_command_and_a_space_show_how_to_use_it() {
    let mut app = app("pip", "m");
    type_text(&mut app, "/send ");
    let hint = app.menu().hint.unwrap_or_default();
    assert_eq!(
        hint,
        "/send DEVICE [IMP] — Send this Imp (or another) to a linked device"
    );
    assert!(
        app.menu().entries.is_empty(),
        "no fixed choices for a device"
    );
    let text = screen(&app, 80, 12).join("\n");
    assert!(text.contains(&hint), "{text}");
    // An alias finds its command too.
    app.on_key(with(KeyCode::Char('u'), KeyModifiers::CONTROL));
    type_text(&mut app, "/key ");
    assert!(app.menu().hint.unwrap_or_default().starts_with("/api_key"));
    // An unknown command has no hint.
    app.on_key(with(KeyCode::Char('u'), KeyModifiers::CONTROL));
    type_text(&mut app, "/nope ");
    assert!(app.menu().hint.is_none());
}

#[test]
fn fixed_choices_after_a_command_are_listed_and_accepted() {
    let mut app = app("pip", "m");
    type_text(&mut app, "/api_key ");
    let labels: Vec<String> = app.menu().entries.iter().map(|e| e.label.clone()).collect();
    assert_eq!(labels, ["save", "forget"]);
    type_text(&mut app, "f");
    assert_eq!(app.menu().entries.len(), 1);
    app.on_key(key(KeyCode::Tab));
    assert_eq!(app.input(), "/api_key forget");
    // Enter with a choice open sends what is typed, so `/api_key` alone shows where the key is from.
    let mut app = self::app("pip", "m");
    type_text(&mut app, "/api_key ");
    assert_eq!(
        app.on_key(key(KeyCode::Enter)),
        Action::Command("/api_key".into())
    );
    let mut app = self::app("pip", "m");
    type_text(&mut app, "/mcp re");
    app.on_key(key(KeyCode::Tab));
    assert_eq!(app.input(), "/mcp remove ");
    type_text(&mut app, "x");
    assert!(
        app.menu().entries.is_empty(),
        "only the first word has choices"
    );
}

#[test]
fn the_cursor_moves_and_edits_in_place() {
    let mut app = app("pip", "m");
    type_text(&mut app, "helo wrld");
    for _ in 0..3 {
        app.on_key(key(KeyCode::Left));
    }
    type_text(&mut app, "o");
    assert_eq!(app.input(), "helo world");
    app.on_key(key(KeyCode::Home));
    assert_eq!(app.cursor(), 0);
    app.on_key(key(KeyCode::Delete));
    assert_eq!(app.input(), "elo world");
    app.on_key(key(KeyCode::Backspace));
    assert_eq!(app.input(), "elo world", "nothing before the start");
    app.on_key(key(KeyCode::Right));
    app.on_key(key(KeyCode::Right));
    type_text(&mut app, "l");
    assert_eq!(app.input(), "ello world");
    app.on_key(key(KeyCode::End));
    assert_eq!(app.cursor(), app.input().len());
    app.on_key(key(KeyCode::Right));
    app.on_key(key(KeyCode::Delete));
    assert_eq!(app.input(), "ello world");
    let ctrl = |c| with(KeyCode::Char(c), KeyModifiers::CONTROL);
    app.on_key(ctrl('a'));
    assert_eq!(app.cursor(), 0);
    app.on_key(ctrl('e'));
    assert_eq!(app.cursor(), 10);
    app.on_key(key(KeyCode::Backspace));
    assert_eq!(app.input(), "ello worl");
}

#[test]
fn words_move_and_are_erased_with_ctrl_and_alt() {
    let mut app = app("pip", "m");
    type_text(&mut app, "one two  three");
    app.on_key(with(KeyCode::Left, KeyModifiers::ALT));
    assert_eq!(app.cursor(), 9);
    app.on_key(with(KeyCode::Left, KeyModifiers::CONTROL));
    assert_eq!(app.cursor(), 4);
    app.on_key(with(KeyCode::Right, KeyModifiers::CONTROL));
    assert_eq!(app.cursor(), 7);
    app.on_key(with(KeyCode::Right, KeyModifiers::ALT));
    assert_eq!(app.cursor(), 14);
    app.on_key(with(KeyCode::Char('w'), KeyModifiers::CONTROL));
    assert_eq!(app.input(), "one two  ");
    app.on_key(with(KeyCode::Char('w'), KeyModifiers::CONTROL));
    assert_eq!(app.input(), "one ");
    app.on_key(with(KeyCode::Left, KeyModifiers::ALT));
    app.on_key(with(KeyCode::Char('w'), KeyModifiers::CONTROL));
    assert_eq!(app.input(), "one ", "nothing before the first word");
    app.on_key(with(KeyCode::Backspace, KeyModifiers::ALT));
    assert_eq!(app.cursor(), 0);
}

#[test]
fn editing_works_on_wide_letters_lines_and_pastes() {
    let mut app = app("pip", "m");
    type_text(&mut app, "é你好");
    app.on_key(key(KeyCode::Left));
    assert_eq!(app.cursor(), "é你".len());
    app.on_key(key(KeyCode::Backspace));
    assert_eq!(app.input(), "é好");
    app.on_paste("a\r\nb");
    assert_eq!(app.input(), "éa\nb好");
    app.on_key(with(KeyCode::Char('a'), KeyModifiers::CONTROL));
    assert_eq!(app.cursor(), "éa\n".len(), "the start of the second line");
    app.on_key(key(KeyCode::End));
    assert_eq!(app.cursor(), app.input().len());
}

#[test]
fn the_terminal_cursor_follows_the_text_cursor() {
    let at = |app: &App, w: u16, h: u16| {
        let mut terminal = Terminal::new(TestBackend::new(w, h)).unwrap();
        terminal.draw(|f| app.render(f)).unwrap();
        terminal.get_cursor_position().unwrap()
    };
    let mut app = app("pip", "m");
    let start = at(&app, 40, 10);
    type_text(&mut app, "ab你");
    let end = at(&app, 40, 10);
    assert_eq!(
        (end.x - start.x, end.y),
        (4, start.y),
        "a wide letter takes two columns"
    );
    app.on_key(key(KeyCode::Left));
    assert_eq!(at(&app, 40, 10).x - start.x, 2);
    app.on_key(key(KeyCode::Home));
    assert_eq!(at(&app, 40, 10).x, start.x);
    // On the second line. The field grows upwards, so the cursor row stays where it was.
    app.on_key(key(KeyCode::End));
    app.on_key(with(KeyCode::Char('j'), KeyModifiers::CONTROL));
    type_text(&mut app, "c");
    let second = at(&app, 40, 10);
    assert_eq!((second.x - start.x, second.y), (1, start.y));
    // A long line wraps, and the cursor goes with the text.
    let mut long = self::app("pip", "m");
    type_text(&mut long, &"word ".repeat(12));
    let wrapped = at(&long, 20, 12);
    assert!(
        wrapped.y > start.y.min(wrapped.y) && wrapped.x < 20,
        "{wrapped:?}"
    );
    long.on_key(with(KeyCode::Char('a'), KeyModifiers::CONTROL));
    assert_eq!(at(&long, 20, 12).x, 3);
}
#[test]
fn what_was_sent_comes_back_with_ctrl_p() {
    let mut app = app("pip", "m");
    type_text(&mut app, "first");
    app.on_key(key(KeyCode::Enter));
    answer(&mut app, "ok");
    type_text(&mut app, "second");
    app.on_key(key(KeyCode::Enter));
    answer(&mut app, "ok");
    let ctrl = |c| with(KeyCode::Char(c), KeyModifiers::CONTROL);
    app.on_key(ctrl('p'));
    assert_eq!(app.input(), "second");
    app.on_key(ctrl('p'));
    assert_eq!(app.input(), "first");
    app.on_key(ctrl('n'));
    assert_eq!(app.input(), "second");
    app.on_key(ctrl('n'));
    assert_eq!(app.input(), "");
}

#[test]
fn esc_stops_an_answer_and_leaves_otherwise() {
    let mut app = chatty();
    assert_eq!(app.on_key(key(KeyCode::Esc)), Action::Stop);
    app.on_done(Ok(()));
    assert_eq!(app.on_key(key(KeyCode::Esc)), Action::Quit);
}

#[test]
fn a_message_to_another_imp_reads_as_one() {
    let mut app = app("pip", "m");
    type_text(&mut app, "ask zed");
    app.on_key(key(KeyCode::Enter));
    let call = ToolCall {
        id: "t".into(),
        name: "imp_message".into(),
        arguments: r#"{"to":"zed","text":"How is the weather?"}"#.into(),
    };
    app.on_agent(&AgentEvent::StepStart);
    app.on_agent(&AgentEvent::Stream(StreamEvent::ToolCallDelta {
        index: 0,
        id: Some(call.id.clone()),
        name: Some(call.name.clone()),
        arguments: call.arguments.clone(),
    }));
    app.on_agent(&AgentEvent::StepEnd);
    app.on_agent(&AgentEvent::ToolStart(call));
    let text = screen(&app, 60, 12).join("\n");
    assert!(text.contains("⇢ zed: How is the weather?"), "{text}");
    assert!(text.contains("⇠ waiting for zed…"), "{text}");
    app.on_agent(&AgentEvent::ToolResult {
        call_id: "t".into(),
        name: "imp_message".into(),
        content: "Sunny all day.".into(),
    });
    let text = screen(&app, 60, 12).join("\n");
    assert!(text.contains("⇠ Sunny all day."), "{text}");
}

#[test]
fn an_imp_that_is_away_answers_there_and_the_empty_chat_says_where_it_works() {
    let mut app = app("pip", "m").in_folder("/home/me/project");
    let text = screen(&app, 60, 12).join("\n");
    assert!(text.contains("/home/me/project"), "{text}");
    assert!(text.contains("/model"), "{text}");
    app.set_away(Some("iPhone".into()));
    assert_eq!(app.activity(), "On iPhone");
    type_text(&mut app, "hello?");
    assert_eq!(app.on_key(key(KeyCode::Enter)), Action::None);
    assert!(app.notes().any(|n| n.text.contains("/call")));
    assert!(app.chat.messages().is_empty());
}

#[test]
fn a_visitor_shows_its_homes_chat_and_what_it_is_writing() {
    use crate::link::device::Visitor;
    use imp_engine::link::{LinkImp, LinkTraits, LinkTurn, LinkWork};
    let mut visitor = Visitor {
        look: LinkImp {
            id: uuid::Uuid::from_u128(3),
            name: "Pebble".into(),
            hue: 0.3,
            scale: 1.0,
            traits: LinkTraits::default(),
        },
        home: uuid::Uuid::from_u128(4),
        home_name: "iPhone".into(),
        from: uuid::Uuid::from_u128(4),
        awake: true,
        turns: vec![LinkTurn {
            id: uuid::Uuid::from_u128(5),
            date: 0.0,
            request: "Hi".into(),
            from: None,
            reply: "Hello from the pocket".into(),
            failed: false,
            steps: vec![],
        }],
        work: None,
    };
    let mut app = app("pip", "m");
    app.show_visitor(&visitor);
    let text = screen(&app, 60, 12).join("\n");
    assert!(text.contains("Hello from the pocket"), "{text}");
    assert!(text.contains("Pebble · visiting from iPhone"), "{text}");
    type_text(&mut app, "More?");
    assert_eq!(
        app.on_key(key(KeyCode::Enter)),
        Action::Send("More?".into())
    );
    visitor.work = Some(LinkWork {
        request: "More?".into(),
        status: None,
        partial: "Sure, here".into(),
        from: None,
    });
    app.show_visitor(&visitor);
    assert!(app.is_waiting());
    let text = screen(&app, 60, 12).join("\n");
    assert!(text.contains("Sure, here▌"), "{text}");
    visitor.awake = false;
    visitor.work = None;
    app.show_visitor(&visitor);
    assert_eq!(app.activity(), "Asleep");
}
