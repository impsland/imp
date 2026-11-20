use super::help::GROUPS;
use super::text::wrap;
use super::*;
use crate::strings::Lang;
use crate::theme::Theme;
use imp_engine::{RetryNotice, StreamEvent, ToolCall};
use ratatui::Terminal;
use ratatui::backend::TestBackend;
use ratatui::crossterm::event::{
    KeyCode, KeyEvent, KeyEventKind, KeyModifiers, MouseButton, MouseEvent, MouseEventKind,
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
    // Esc never leaves the chat, so a stray press does nothing.
    assert_eq!(app.on_key(key(KeyCode::Esc)), Action::None);
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
    assert!(text.contains("⎿ ⠋ running…"), "{text}");
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
    // The card has grown with the editing, file and mouse keys, so it needs a few more rows to show
    // all of them at once. A shorter screen scrolls it (see the test after this one).
    let rows = screen(&app, 80, 42);
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
    let narrow = screen(&app, 36, 72).join("\n");
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
        "Shift+↑ Shift+↓",
        "PgUp PgDn",
        "End",
        "Esc",
        "Ctrl+C",
        "Ctrl+D",
        "/quit",
        "/clear",
        "Ctrl+O",
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
    // A key typed for `/auth set` never shows, and goes to the command alone.
    type_text(&mut app, "/auth set openai");
    assert!(matches!(
        app.on_key(key(KeyCode::Enter)),
        Action::Command(_)
    ));
    app.ask_secret("Key for openai".into(), "/auth set openai".into());
    type_text(&mut app, "sk-very-secret");
    let text = screen(&app, 60, 12).join("\n");
    assert!(!text.contains("sk-very-secret"), "{text}");
    assert_eq!(
        app.on_key(key(KeyCode::Enter)),
        Action::Secret {
            line: "/auth set openai".into(),
            key: "sk-very-secret".into()
        }
    );
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
    assert!(
        text.contains("MCP servers: tools from programs and services"),
        "{text}"
    );
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
        .filter_map(|e| e.command.map(|c| c.name.as_str()))
        .collect()
}

fn highlighted(app: &App) -> String {
    let menu = app.menu();
    menu.entries[app.pick_in(menu.entries.len())].insert.clone()
}

#[test]
fn matches_are_ranked_prefix_first_then_contained_then_in_order() {
    let mut app = app("pip", "m");
    type_text(&mut app, "/pr");
    // Names that start with it first, then the ones with its letters in order.
    assert_eq!(
        names(&app),
        ["/provider", "/project", "/permission", "/pair"]
    );
    app.on_key(with(KeyCode::Char('u'), KeyModifiers::CONTROL));
    type_text(&mut app, "/ommand");
    // Names that contain it come after the ones that start with it.
    assert_eq!(names(&app), ["/command"]);
    app.on_key(with(KeyCode::Char('u'), KeyModifiers::CONTROL));
    type_text(&mut app, "/rules");
    // The alias of /permission finds it.
    assert_eq!(names(&app), ["/permission"]);
    app.on_key(with(KeyCode::Char('u'), KeyModifiers::CONTROL));
    type_text(&mut app, "/pm");
    assert!(
        names(&app).contains(&"/permission"),
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
fn the_list_is_above_the_field_and_commands_with_forms_show_them_under_the_name() {
    let mut app = app("pip", "m");
    type_text(&mut app, "/mc");
    let rows = screen(&app, 120, 24);
    let field = rows
        .iter()
        .position(|r| r == " › /mc")
        .unwrap_or_else(|| panic!("{rows:#?}"));
    let name = rows.iter().position(|r| r.starts_with(" › /mcp")).unwrap();
    assert!(rows[name].contains("MCP servers: tools from programs and services"));
    let forms = [
        "list [--agent NAME]",
        "add NAME [--command PROGRAM ARGS] [--url URL] [--env NAME=VALUE] [--header NAME=VALUE]",
        "set NAME KEY VALUE",
        "remove NAME",
        "enable NAME [--agent NAME]",
        "disable NAME [--agent NAME]",
    ];
    for (i, form) in forms.iter().enumerate() {
        assert_eq!(rows[name + 1 + i].trim(), *form, "{rows:#?}");
        assert!(rows[name + 1 + i].starts_with("    "), "indented");
    }
    assert!(field > name + forms.len(), "{rows:#?}");
}

#[test]
fn the_hint_of_a_command_is_above_the_field_too() {
    let mut app = app("pip", "m");
    type_text(&mut app, "/model ");
    let rows = screen(&app, 80, 24);
    let hint = row_of(&rows, "/model [MODEL] [--agent NAME]: ");
    let field = row_of(&rows, "› /model");
    assert!(hint < field, "{rows:#?}");
}

#[test]
fn a_short_terminal_shortens_the_list_with_forms_without_overlap() {
    let mut app = app("pip", "m");
    type_text(&mut app, "/mc");
    for (w, h) in [(80, 5), (80, 7), (40, 9), (20, 4), (10, 2), (1, 1)] {
        assert_eq!(screen(&app, w, h).len(), h as usize);
    }
    let rows = screen(&app, 80, 9);
    assert!(rows.iter().any(|r| r.starts_with(" › /mcp")), "{rows:#?}");
    assert!(rows.iter().any(|r| r == " › /mc"), "{rows:#?}");
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
    assert!(
        !text.contains("MCP servers: tools from programs and services"),
        "{text}"
    );
    // Up and Down scroll the chat again while the list is closed.
    app.on_key(key(KeyCode::Up));
    assert_eq!(app.input(), "/mc");
    // Typing opens it again.
    type_text(&mut app, "p");
    assert!(!app.menu().entries.is_empty());
    app.on_key(key(KeyCode::Esc));
    assert_eq!(app.on_key(key(KeyCode::Esc)), Action::None);
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
        "/send DEVICE [IMP]: Send this Imp (or another) to a linked device"
    );
    assert!(
        app.menu().entries.is_empty(),
        "no fixed choices for a device"
    );
    let text = screen(&app, 80, 12).join("\n");
    assert!(text.contains(&hint), "{text}");
    // An alias finds its command too.
    app.on_key(with(KeyCode::Char('u'), KeyModifiers::CONTROL));
    type_text(&mut app, "/rules ");
    assert!(
        app.menu()
            .hint
            .unwrap_or_default()
            .starts_with("/permission")
    );
    // An unknown command has no hint.
    app.on_key(with(KeyCode::Char('u'), KeyModifiers::CONTROL));
    type_text(&mut app, "/nope ");
    assert!(app.menu().hint.is_none());
}

#[test]
fn fixed_choices_after_a_command_are_listed_and_accepted() {
    let mut app = app("pip", "m");
    type_text(&mut app, "/auth ");
    let labels: Vec<String> = app.menu().entries.iter().map(|e| e.label.clone()).collect();
    assert_eq!(labels, ["set", "clear", "list"]);
    type_text(&mut app, "c");
    assert_eq!(app.menu().entries.len(), 1);
    app.on_key(key(KeyCode::Tab));
    assert_eq!(app.input(), "/auth clear ");
    // Enter with a choice open sends what is typed, so `/auth` alone lists where the keys are from.
    let mut app = self::app("pip", "m");
    type_text(&mut app, "/auth ");
    assert_eq!(
        app.on_key(key(KeyCode::Enter)),
        Action::Command("/auth".into())
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
fn esc_stops_an_answer_and_does_nothing_otherwise() {
    let mut app = chatty();
    assert_eq!(app.on_key(key(KeyCode::Esc)), Action::Stop);
    app.on_done(Ok(()));
    assert_eq!(
        app.on_key(key(KeyCode::Esc)),
        Action::None,
        "Esc never leaves the chat"
    );
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
    // A spinner turns before it while zed thinks.
    assert!(text.contains("⇠ ⠋ waiting for zed…"), "{text}");
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
            about: None,
            abilities: Vec::new(),
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

fn mouse(app: &mut App, kind: MouseEventKind, column: u16, row: u16) -> Action {
    app.on_mouse(MouseEvent {
        kind,
        column,
        row,
        modifiers: KeyModifiers::NONE,
    })
}

/// The row of the screen whose text contains `needle`.
fn row_of(rows: &[String], needle: &str) -> u16 {
    rows.iter()
        .position(|r| r.contains(needle))
        .unwrap_or_else(|| panic!("{needle} is not on screen:\n{}", rows.join("\n"))) as u16
}

#[test]
fn the_empty_chat_shows_the_imp_once_and_the_folder_under_the_field() {
    let app = app("pip", "openai/gpt-6-luna").in_folder("~/Developer/imp");
    let rows = screen(&app, 80, 30);
    let text = rows.join("\n");
    // Who it is and where it works are said once, in the status line.
    assert_eq!(text.matches("openai/gpt-6-luna").count(), 1, "{text}");
    assert!(
        rows[29].starts_with("● pip · openai/gpt-6-luna · ~/Developer/imp"),
        "{text}"
    );
    // The Imp is in the middle of the transcript, left and right.
    let art = row_of(&rows, "WWWWWWWWW.  wWWWW");
    let line = &rows[art as usize];
    let left = line.len() - line.trim_start().len();
    let width = line.trim().chars().count();
    assert!(left.abs_diff(80 - left - width) <= 6, "{text}");
    assert!(art > 2, "there is room above it\n{text}");
    assert!(text.contains("/model"), "{text}");
    // Without room for it, only the words show.
    let short = screen(&app, 80, 12).join("\n");
    assert!(!short.contains("WWWWWWWWW.  wWWWW"), "{short}");
    assert!(short.contains("/model"), "{short}");
    // A narrow status line keeps the end of the folder, then lets it go.
    let narrow = screen(&app, 56, 30);
    assert!(narrow[29].contains("…/imp"), "{}", narrow[29]);
    let tiny = screen(&app, 30, 30);
    assert!(
        !tiny[29].contains("imp ·") && tiny[29].contains("Ready"),
        "{}",
        tiny[29]
    );
}

#[test]
fn a_short_screen_keeps_the_field_and_status_and_the_help_scrolls() {
    let mut app = chatty();
    type_text(&mut app, "draft");
    // Below ten rows the field has no blank rows around it.
    let rows = screen(&app, 60, 6);
    let text = rows.join("\n");
    assert!(rows[4].contains("› draft"), "{text}");
    assert!(rows[5].contains("pip"), "{text}");
    let _ = screen(&app, 60, 2);
    // A help card that does not fit scrolls, and says so. The arrows scroll it and keep it open.
    let mut helped = chatty();
    helped.on_key(key(KeyCode::F(1)));
    let top = screen(&helped, 60, 16).join("\n");
    assert!(top.contains("scroll"), "{top}");
    assert!(top.contains("Send the message"), "{top}");
    assert!(!top.contains("Open this help from anywhere"), "{top}");
    helped.on_key(key(KeyCode::End));
    assert!(helped.is_help_open());
    let bottom = screen(&helped, 60, 16).join("\n");
    assert!(bottom.contains("F1"), "{bottom}");
    helped.on_key(key(KeyCode::Down));
    mouse(&mut helped, MouseEventKind::ScrollUp, 1, 1);
    assert!(helped.is_help_open());
    helped.on_key(key(KeyCode::Char('x')));
    assert!(!helped.is_help_open());
    assert_eq!(
        helped.input(),
        "",
        "the key that closes the card is not typed"
    );
    // On a wide, short screen the card takes two columns and every key shows.
    let mut wide = chatty();
    wide.on_key(key(KeyCode::F(1)));
    let text = screen(&wide, 200, 30).join("\n");
    assert!(!text.contains("scroll,"), "{text}");
    for group in GROUPS {
        for b in *group {
            assert!(
                text.contains(b.label(Lang::En)),
                "missing {}\n{text}",
                b.keys
            );
        }
    }
}

/// A finished chat with a long answer, drawn once so the mouse knows where things are.
fn answered(width: u16, height: u16) -> App {
    let mut app = app("pip", "m");
    type_text(&mut app, "Tell me");
    app.on_key(key(KeyCode::Enter));
    answer(
        &mut app,
        "The quick brown fox jumps over the lazy dog and keeps running far away\nNew line here",
    );
    let _ = screen(&app, width, height);
    app
}

#[test]
fn dragging_over_text_copies_it_without_marks_and_joins_wrapped_lines() {
    let mut app = answered(30, 16);
    let rows = screen(&app, 30, 16);
    let first = row_of(&rows, "● The quick");
    let last = row_of(&rows, "New line here");
    assert_eq!(
        mouse(&mut app, MouseEventKind::Down(MouseButton::Left), 0, first),
        Action::None
    );
    mouse(&mut app, MouseEventKind::Drag(MouseButton::Left), 10, last);
    let copied = mouse(&mut app, MouseEventKind::Up(MouseButton::Left), 10, last);
    assert_eq!(
        copied,
        Action::Copy(
            "The quick brown fox jumps over the lazy dog and keeps running far away\nNew line"
                .into()
        )
    );
    // The chosen text shows reversed.
    let mut terminal = Terminal::new(TestBackend::new(30, 16)).unwrap();
    terminal.draw(|f| app.render(f)).unwrap();
    let cell = &terminal.backend().buffer()[(4, first)];
    assert!(cell.modifier.contains(ratatui::style::Modifier::REVERSED));
    // Esc lets go of it before it would leave the chat.
    assert_eq!(app.on_key(key(KeyCode::Esc)), Action::None);
    assert!(app.selected_text().is_empty());
    // A click without a drag copies nothing.
    mouse(&mut app, MouseEventKind::Down(MouseButton::Left), 5, first);
    assert_eq!(
        mouse(&mut app, MouseEventKind::Up(MouseButton::Left), 5, first),
        Action::None
    );
}

#[test]
fn two_clicks_copy_a_word_three_a_paragraph_and_ctrl_c_copies_again() {
    let mut app = answered(30, 16);
    let rows = screen(&app, 30, 16);
    let first = row_of(&rows, "● The quick");
    let click = |app: &mut App| {
        let down = mouse(app, MouseEventKind::Down(MouseButton::Left), 7, first);
        mouse(app, MouseEventKind::Up(MouseButton::Left), 7, first);
        down
    };
    assert_eq!(click(&mut app), Action::None);
    assert_eq!(click(&mut app), Action::Copy("quick".into()));
    assert_eq!(
        click(&mut app),
        Action::Copy(
            "The quick brown fox jumps over the lazy dog and keeps running far away".into()
        )
    );
    assert_eq!(
        app.on_key(with(KeyCode::Char('c'), KeyModifiers::CONTROL)),
        Action::Copy(
            "The quick brown fox jumps over the lazy dog and keeps running far away".into()
        ),
        "with text chosen, Ctrl+C copies instead of leaving"
    );
    assert_eq!(
        app.on_key(with(KeyCode::Char('c'), KeyModifiers::CONTROL)),
        Action::Quit
    );
}

#[test]
fn dragging_past_the_top_scrolls_and_keeps_choosing() {
    let mut app = app("pip", "m");
    for i in 0..10 {
        type_text(&mut app, &format!("question {i}"));
        app.on_key(key(KeyCode::Enter));
        answer(&mut app, &format!("answer {i}"));
    }
    let rows = screen(&app, 40, 12);
    let bottom = row_of(&rows, "answer 9");
    // From the end of the last answer, upwards.
    mouse(
        &mut app,
        MouseEventKind::Down(MouseButton::Left),
        39,
        bottom,
    );
    mouse(&mut app, MouseEventKind::Drag(MouseButton::Left), 2, 3);
    assert!(!app.edge_scrolling());
    // The terminal's top row is the transcript's, so holding the mouse on it scrolls.
    mouse(&mut app, MouseEventKind::Drag(MouseButton::Left), 2, 0);
    let _ = screen(&app, 40, 12);
    assert!(app.edge_scrolling());
    for _ in 0..10 {
        app.on_edge_tick();
        let _ = screen(&app, 40, 12);
    }
    assert!(app.scroll() >= 3, "{}", app.scroll());
    let Action::Copy(text) = mouse(&mut app, MouseEventKind::Up(MouseButton::Left), 2, 0) else {
        panic!("nothing copied");
    };
    assert!(text.ends_with("answer 9"), "{text}");
    assert!(text.lines().count() > 5, "{text}");
    assert!(!app.edge_scrolling());
}

#[test]
fn edge_scrolling_is_slow_and_grows_only_a_little_with_the_distance() {
    let mut app = app("pip", "m");
    for i in 0..10 {
        type_text(&mut app, &format!("question {i}"));
        app.on_key(key(KeyCode::Enter));
        answer(&mut app, &format!("answer {i}"));
    }
    let rows = screen(&app, 40, 12);
    let bottom = row_of(&rows, "answer 9");
    mouse(
        &mut app,
        MouseEventKind::Down(MouseButton::Left),
        39,
        bottom,
    );
    // Just past the top edge: one line at once, then about two lines a second (ten ticks of 100 ms).
    mouse(&mut app, MouseEventKind::Drag(MouseButton::Left), 2, 0);
    let _ = screen(&app, 40, 12);
    assert_eq!(app.scroll(), 1);
    for _ in 0..10 {
        app.on_edge_tick();
        let _ = screen(&app, 40, 12);
    }
    let near = app.scroll() - 1;
    assert!((1..=3).contains(&near), "{near}");
    // Moving the mouse along the edge does not scroll by itself.
    let held = app.scroll();
    mouse(&mut app, MouseEventKind::Drag(MouseButton::Left), 5, 0);
    assert_eq!(app.scroll(), held);
    // Far below the transcript it is faster, but never more than the fastest rate in a second.
    let before = app.scroll();
    mouse(&mut app, MouseEventKind::Drag(MouseButton::Left), 5, 11);
    let _ = screen(&app, 40, 12);
    let at_once = before.saturating_sub(app.scroll());
    assert!(at_once <= 1, "{at_once}");
    for _ in 0..10 {
        app.on_edge_tick();
        let _ = screen(&app, 40, 12);
    }
    let far = before.saturating_sub(app.scroll());
    assert!((1..=9).contains(&far), "{far}");
}

#[test]
fn while_scrolled_up_new_lines_do_not_move_the_view() {
    let mut app = app("pip", "m");
    for i in 0..8 {
        type_text(&mut app, &format!("question {i}"));
        app.on_key(key(KeyCode::Enter));
        answer(&mut app, &format!("answer {i}"));
    }
    type_text(&mut app, "more");
    app.on_key(key(KeyCode::Enter));
    app.on_agent(&AgentEvent::StepStart);
    let _ = screen(&app, 40, 12);
    app.on_key(key(KeyCode::PageUp));
    let before = screen(&app, 40, 12);
    assert!(before[11].contains("End ↓ latest"), "{}", before[11]);
    app.on_agent(&AgentEvent::Stream(StreamEvent::Text(
        "one\ntwo\nthree\nfour".into(),
    )));
    let after = screen(&app, 40, 12);
    assert_eq!(before[..6], after[..6], "the view moved");
    app.on_key(key(KeyCode::End));
    assert!(screen(&app, 40, 12).join("\n").contains("four"));
}

#[test]
fn at_lists_the_folders_files_and_enter_puts_one_in_the_message() {
    let mut app = app("pip", "m");
    app.set_files(vec![
        "README.md".into(),
        "src/".into(),
        "src/main.rs".into(),
        "src/menu.rs".into(),
    ]);
    type_text(&mut app, "look at @ma");
    let menu = app.menu();
    assert!(menu.files);
    assert_eq!(menu.entries[0].label, "src/main.rs");
    let text = screen(&app, 60, 14).join("\n");
    assert!(text.contains("src/main.rs"), "{text}");
    assert_eq!(
        app.on_key(key(KeyCode::Enter)),
        Action::None,
        "Enter picks, it does not send"
    );
    assert_eq!(app.input(), "look at @src/main.rs ");
    assert!(app.menu().entries.is_empty());
    // A folder opens to what is in it. The cursor stays after it.
    type_text(&mut app, "and @sr");
    app.on_key(key(KeyCode::Tab));
    assert_eq!(app.input(), "look at @src/main.rs and @src/");
    let names: Vec<String> = app.menu().entries.iter().map(|e| e.label.clone()).collect();
    assert_eq!(names, ["src/main.rs", "src/menu.rs"]);
    // Esc closes the list, and Enter then sends.
    app.on_key(key(KeyCode::Esc));
    assert!(matches!(app.on_key(key(KeyCode::Enter)), Action::Send(_)));
    // In the middle of the text, the rest is kept.
    let mut mid = self::app("pip", "m");
    mid.set_files(vec!["notes.txt".into()]);
    type_text(&mut mid, "read  please");
    for _ in 0.."  please".len() - 1 {
        mid.on_key(key(KeyCode::Left));
    }
    type_text(&mut mid, "@no");
    mid.on_key(key(KeyCode::Tab));
    assert_eq!(mid.input(), "read @notes.txt please");
    assert_eq!(mid.cursor(), "read @notes.txt".len());
}

#[test]
fn a_message_with_files_shows_what_was_written_and_their_names() {
    let mut app = app("pip", "m");
    type_text(&mut app, "read @a.txt");
    app.on_key(key(KeyCode::Enter));
    app.chat.amend_last_user(format!(
        "read @a.txt{}\n<file path=\"a.txt\">\nsecret contents\n</file>\n</attached_files>",
        crate::mentions::ATTACHED
    ));
    let text = screen(&app, 60, 12).join("\n");
    assert!(text.contains("› read @a.txt"), "{text}");
    assert!(text.contains("⎿ with a.txt"), "{text}");
    assert!(!text.contains("secret contents"), "{text}");
    assert!(
        app.chat.request_messages()[1]
            .content
            .contains("secret contents")
    );
}

fn cursor_at(app: &App, w: u16, h: u16) -> ratatui::layout::Position {
    let mut terminal = Terminal::new(TestBackend::new(w, h)).unwrap();
    terminal.draw(|f| app.render(f)).unwrap();
    terminal.get_cursor_position().unwrap()
}

#[test]
fn a_typed_space_shows_and_moves_the_cursor() {
    let mut app = app("pip", "m");
    type_text(&mut app, "a");
    let after_a = cursor_at(&app, 40, 12).x;
    type_text(&mut app, " ");
    assert_eq!(
        cursor_at(&app, 40, 12).x,
        after_a + 1,
        "the space moved the cursor"
    );
    type_text(&mut app, " b");
    let rows = screen(&app, 40, 12);
    assert!(rows.iter().any(|r| r.contains("› a  b")), "{rows:?}");
    // A space at the end of a full row is kept, and the next word starts the next row.
    let mut long = self::app("pip", "m");
    type_text(&mut long, "hello world again");
    let rows = screen(&long, 16, 12);
    assert!(rows.iter().any(|r| r.ends_with("world")), "{rows:?}");
}

#[test]
fn up_and_down_move_between_lines_then_through_what_was_sent() {
    let mut app = app("pip", "m");
    for said in ["first", "second"] {
        type_text(&mut app, said);
        app.on_key(key(KeyCode::Enter));
        answer(&mut app, "ok");
    }
    let _ = screen(&app, 40, 16);
    // A draft of two lines: Up goes to its first line before it brings back anything.
    type_text(&mut app, "draft one");
    app.on_key(with(KeyCode::Char('j'), KeyModifiers::CONTROL));
    type_text(&mut app, "two");
    app.on_key(key(KeyCode::Up));
    assert_eq!(app.input(), "draft one\ntwo");
    assert_eq!(app.cursor(), 3, "the same column, one line up");
    app.on_key(key(KeyCode::Up));
    assert_eq!(app.input(), "second");
    app.on_key(key(KeyCode::Up));
    assert_eq!(app.input(), "first");
    app.on_key(key(KeyCode::Up));
    assert_eq!(app.input(), "first", "the oldest stays");
    app.on_key(key(KeyCode::Down));
    assert_eq!(app.input(), "second");
    app.on_key(key(KeyCode::Down));
    assert_eq!(app.input(), "draft one\ntwo", "the draft comes back");
    app.on_key(key(KeyCode::Down));
    assert_eq!(app.input(), "draft one\ntwo");
    // Shift with the arrows scrolls the chat instead.
    let mut long = self::app("pip", "m");
    for i in 0..12 {
        type_text(&mut long, &format!("q{i}"));
        long.on_key(key(KeyCode::Enter));
        answer(&mut long, "a");
    }
    let _ = screen(&long, 40, 10);
    long.on_key(with(KeyCode::Up, KeyModifiers::SHIFT));
    assert_eq!(long.scroll(), 1);
    assert_eq!(long.input(), "");
    long.on_key(with(KeyCode::Down, KeyModifiers::SHIFT));
    assert_eq!(long.scroll(), 0);
}

#[test]
fn answers_show_their_markdown_as_styles() {
    let mut app = chatty();
    app.on_agent(&AgentEvent::StepEnd);
    app.on_done(Ok(()));
    type_text(&mut app, "more");
    app.on_key(key(KeyCode::Enter));
    answer(
        &mut app,
        "## Steps\n\n- **Open** the `config.toml`\n- Save\n\n```\nlet x = 1;\n```",
    );
    let mut terminal = Terminal::new(TestBackend::new(60, 30)).unwrap();
    terminal.draw(|f| app.render(f)).unwrap();
    let buffer = terminal.backend().buffer().clone();
    let rows: Vec<String> = (0..30)
        .map(|y| (0..60).map(|x| buffer[(x, y)].symbol()).collect::<String>())
        .collect();
    let text = rows.join("\n");
    assert!(text.contains("● Steps"), "{text}");
    assert!(text.contains("• Open the config.toml"), "{text}");
    assert!(text.contains("let x = 1;"), "{text}");
    assert!(
        !text.contains("**") && !text.contains("```") && !text.contains("## "),
        "{text}"
    );
    let y = rows.iter().position(|r| r.contains("• Open")).unwrap() as u16;
    let x = rows[y as usize].find("Open").unwrap() as u16;
    let x = rows[y as usize][..x as usize].chars().count() as u16;
    assert!(
        buffer[(x, y)]
            .modifier
            .contains(ratatui::style::Modifier::BOLD)
    );
}

#[test]
fn what_a_command_says_is_set_apart_and_lines_up() {
    let mut app = app("pip", "m");
    type_text(&mut app, "hello");
    app.on_key(key(KeyCode::Enter));
    answer(&mut app, "hi");
    type_text(&mut app, "/settings");
    assert!(matches!(
        app.on_key(key(KeyCode::Enter)),
        Action::Command(_)
    ));
    app.notes_from(vec![
        Note::heading("pip"),
        Note::field("model", "m"),
        Note::field("personality", "Kind."),
        Note::check(true, "own.personality.imp_message"),
        Note::check(false, "mcp.files.delete"),
        Note::info("Use `/model NAME` to change it."),
    ]);
    let rows = screen(&app, 60, 20);
    let text = rows.join("\n");
    let command = rows
        .iter()
        .position(|r| r.starts_with("› /settings"))
        .unwrap();
    assert_eq!(rows[command - 1], "", "a blank row above\n{text}");
    let model = rows.iter().find(|r| r.contains("model")).unwrap();
    let kind = rows.iter().find(|r| r.contains("personality")).unwrap();
    assert_eq!(
        model.rfind(' ').map(|i| i + 1),
        kind.find("Kind."),
        "values line up\n{text}"
    );
    assert!(text.contains("✓ own.personality.imp_message"), "{text}");
    assert!(text.contains("· mcp.files.delete"), "{text}");
    assert!(text.contains("Use /model NAME to change it."), "{text}");
    let last = rows.iter().rposition(|r| r.contains("change it")).unwrap();
    assert_eq!(rows[last + 1], "", "a blank row below\n{text}");
}

#[test]
fn a_long_think_shows_that_the_imp_is_working() {
    let mut app = app("pip", "m");
    type_text(&mut app, "hard question");
    app.on_key(key(KeyCode::Enter));
    app.on_agent(&AgentEvent::StepStart);
    assert!(app.is_animating());
    let text = screen(&app, 60, 12).join("\n");
    assert!(text.contains("⠋ Thinking… · Esc to stop"), "{text}");
    app.on_agent(&AgentEvent::Stream(StreamEvent::Text("Here".into())));
    let text = screen(&app, 60, 12).join("\n");
    assert!(!text.contains("Thinking…"), "{text}");
    assert!(text.contains("● Here▌"), "{text}");
    app.on_done(Ok(()));
    assert!(!app.is_animating());
    assert_eq!(super::view::spinner_frame(0), "⠋");
    assert_ne!(
        super::view::spinner_frame(100),
        super::view::spinner_frame(0)
    );
}

#[test]
fn an_answer_that_came_later_wakes_the_imp_with_a_new_message_and_shows_as_an_event() {
    let mut app = App::new("pip", "m", "sys");
    type_text(&mut app, "ask bo");
    let Action::Send(_) = app.on_key(key(KeyCode::Enter)) else {
        panic!("sent");
    };
    // The turn ends with the receipt as the tool's result.
    for e in [
        AgentEvent::StepStart,
        AgentEvent::Stream(StreamEvent::ToolCallDelta {
            index: 0,
            id: Some("c1".into()),
            name: Some("imp_message".into()),
            arguments: "{\"to\":\"bo\",\"text\":\"capital?\"}".into(),
        }),
        AgentEvent::StepEnd,
        AgentEvent::ToolResult {
            call_id: "c1".into(),
            name: "imp_message".into(),
            content: "Sent to bo (task t-1a2b3c).".into(),
        },
    ] {
        app.on_agent(&e);
    }
    // Busy: an answer can't start a turn.
    assert!(!app.wake("[Event, not from the user] bo answered"));
    answer(&mut app, "Asked. I will tell you when bo answers.");
    let before: Vec<_> = app.chat.messages().to_vec();
    let event = imp_engine::troupe::answer_event("bo", "t-1a2b3c", "13:46 UTC", "Canberra", false);
    assert!(app.wake(&event));
    assert!(app.is_waiting());
    // It is a new message at the end. Nothing before it changed.
    let after = app.chat.messages();
    assert_eq!(after.len(), before.len() + 1);
    assert_eq!(after[..before.len()], before[..]);
    assert_eq!(after.last().unwrap().content, event);
    let tool = after
        .iter()
        .find(|m| m.role == imp_engine::Role::Tool)
        .unwrap();
    assert_eq!(tool.content, "Sent to bo (task t-1a2b3c).");
    // A second answer waits until this turn is over.
    assert!(!app.wake(&event));
    let shown = screen(&app, 80, 20).join("\n");
    assert!(
        shown.contains("⇠ [Event, not from the user] bo answered your message"),
        "{shown}"
    );
    assert!(!shown.contains("(Act on it now"), "{shown}");
}

#[test]
fn custom_commands_are_offered_after_slash_and_run_as_messages() {
    let mut app = app("pip", "m");
    app.set_custom_commands(vec![
        imp_engine::config::Command {
            name: "review".into(),
            template: "Review $ARGUMENTS for bugs and missing tests.".into(),
            ..Default::default()
        },
        imp_engine::config::Command {
            name: "exit".into(),
            template: "Shadowed by the built-in.".into(),
            ..Default::default()
        },
    ]);
    // Typed by its first letters, it shows with the built-ins' list and its usage.
    type_text(&mut app, "/re");
    let menu = app.menu();
    let custom: Vec<&menu::Entry> = menu.entries.iter().filter(|e| e.custom).collect();
    assert_eq!(custom.len(), 1);
    assert_eq!(custom[0].label, "/review ARGUMENTS");
    assert_eq!(custom[0].insert, "/review ");
    assert_eq!(
        custom[0].about,
        "Review $ARGUMENTS for bugs and missing tests."
    );
    // A built-in name is never offered twice.
    app.on_key(with(KeyCode::Char('u'), KeyModifiers::CONTROL));
    type_text(&mut app, "/e");
    assert!(app.menu().entries.iter().all(|e| !e.custom));
    // Enter on it completes the arguments; then the line goes to the chat loop as a command, which fills in
    // the text (shell and files behind the Imp's permissions) and sends it.
    app.on_key(with(KeyCode::Char('u'), KeyModifiers::CONTROL));
    type_text(&mut app, "/rev");
    app.on_key(key(KeyCode::Enter));
    assert_eq!(app.input(), "/review ");
    type_text(&mut app, "src/auth.rs");
    match app.on_key(key(KeyCode::Enter)) {
        Action::Command(line) => assert_eq!(line, "/review src/auth.rs"),
        _ => panic!("a custom command should go to the chat loop as a command"),
    }
}

/// A chat in which the Imp called each of `calls` (name, arguments, result), one after the other.
fn called(calls: &[(&str, &str, &str)]) -> App {
    let mut app = app("pip", "m");
    type_text(&mut app, "go");
    app.on_key(key(KeyCode::Enter));
    for (i, (name, arguments, result)) in calls.iter().enumerate() {
        let call = ToolCall {
            id: format!("c{i}"),
            name: (*name).into(),
            arguments: (*arguments).into(),
        };
        app.on_agent(&AgentEvent::StepStart);
        app.on_agent(&AgentEvent::Stream(StreamEvent::ToolCallDelta {
            index: 0,
            id: Some(call.id.clone()),
            name: Some(call.name.clone()),
            arguments: call.arguments.clone(),
        }));
        app.on_agent(&AgentEvent::StepEnd);
        app.on_agent(&AgentEvent::ToolStart(call.clone()));
        app.on_agent(&AgentEvent::ToolResult {
            call_id: call.id,
            name: (*name).into(),
            content: (*result).into(),
        });
    }
    app
}

fn ctrl_o() -> KeyEvent {
    with(KeyCode::Char('o'), KeyModifiers::CONTROL)
}

#[test]
fn ctrl_o_opens_a_tool_call_whole_and_esc_closes_it() {
    let path = "/Users/me/projects/my-app/docs/notes/a-very-long-folder-name/TODO.md";
    let arguments = format!(r##"{{"path":"{path}","content":"# TODO\nbuy milk"}}"##);
    let mut app = called(&[("files__write_file", &arguments, "Wrote 2 lines")]);
    // The one-line view stays the default: the path is cut and nothing is marked as added.
    let text = screen(&app, 40, 14).join("\n");
    assert!(
        !text.contains(path) && !text.contains("+ buy milk") && !app.is_detail_open(),
        "{text}"
    );
    app.on_key(ctrl_o());
    assert!(app.is_detail_open());
    let rows = screen(&app, 40, 14);
    let text = rows.join("\n");
    // The path is wrapped over rows, not cut: every piece of it is on screen.
    let joined: String = rows.iter().map(|r| r.trim()).collect();
    assert!(joined.contains(path), "{text}");
    assert!(text.contains("write_file"), "{text}");
    assert!(
        text.contains("+ # TODO") && text.contains("+ buy milk"),
        "{text}"
    );
    assert!(
        text.contains("Result") && text.contains("Wrote 2 lines"),
        "{text}"
    );
    assert!(text.contains("← → 1 of 1"), "{text}");
    // Keys do not reach the message behind.
    app.on_key(key(KeyCode::Char('x')));
    assert_eq!(app.input(), "");
    app.on_key(key(KeyCode::Esc));
    assert!(!app.is_detail_open());
    assert!(!screen(&app, 40, 14).join("\n").contains("+ buy milk"));
}

#[test]
fn an_edit_shows_minus_and_plus_lines() {
    let mut app = called(&[(
        "files__edit_file",
        r#"{"path":"a.txt","edits":[{"oldText":"keep\nold line","newText":"keep\nnew line"}]}"#,
        "ok",
    )]);
    app.on_key(ctrl_o());
    let text = screen(&app, 50, 16).join("\n");
    assert!(text.contains("- old line"), "{text}");
    assert!(text.contains("+ new line"), "{text}");
    assert!(text.contains("  keep"), "{text}");
}

#[test]
fn a_long_result_is_capped_with_a_note_and_enter_shows_all() {
    let result = (1..=100)
        .map(|i| format!("line {i}"))
        .collect::<Vec<_>>()
        .join("\n");
    let mut app = called(&[("files__read_file", r#"{"path":"big.txt"}"#, &result)]);
    app.on_key(ctrl_o());
    // Scrolled to the end, the cap shows its note and not the lines past it.
    app.on_key(key(KeyCode::End));
    let text = screen(&app, 60, 12).join("\n");
    assert!(text.contains("line 40"), "{text}");
    assert!(text.contains("… 60 more lines"), "{text}");
    assert!(!text.contains("line 41"), "{text}");
    app.on_key(key(KeyCode::Enter));
    app.on_key(key(KeyCode::End));
    let text = screen(&app, 60, 12).join("\n");
    assert!(text.contains("line 100"), "{text}");
    assert!(!text.contains("more lines"), "{text}");
    // Scrolling back up reaches the first lines.
    app.on_key(key(KeyCode::Home));
    assert!(screen(&app, 60, 12).join("\n").contains("line 1"));
}

#[test]
fn the_arrows_move_between_calls_and_there_is_nothing_to_open_without_one() {
    let mut app = called(&[
        ("files__read_file", r#"{"path":"first.txt"}"#, "one"),
        ("files__read_file", r#"{"path":"second.txt"}"#, "two"),
    ]);
    app.on_key(ctrl_o());
    let text = screen(&app, 60, 12).join("\n");
    assert!(
        text.contains("second.txt") && text.contains("← → 2 of 2"),
        "{text}"
    );
    app.on_key(key(KeyCode::Left));
    let text = screen(&app, 60, 12).join("\n");
    assert!(
        text.contains("first.txt") && text.contains("← → 1 of 2"),
        "{text}"
    );
    app.on_key(key(KeyCode::Left));
    assert!(screen(&app, 60, 12).join("\n").contains("← → 1 of 2"));
    app.on_key(ctrl_o());
    assert!(!app.is_detail_open());

    let mut bare = chatty();
    bare.on_key(ctrl_o());
    assert!(!bare.is_detail_open());
}

#[test]
fn the_details_fit_tiny_screens_and_leave_with_ctrl_c() {
    let mut app = called(&[("files__read_file", r#"{"path":"a"}"#, "x")]);
    app.on_key(ctrl_o());
    for (w, h) in [(1, 1), (3, 2), (10, 3), (80, 2)] {
        let _ = screen(&app, w, h);
    }
    assert_eq!(
        app.on_key(with(KeyCode::Char('c'), KeyModifiers::CONTROL)),
        Action::Quit
    );
}

#[test]
fn a_click_on_a_tool_call_opens_that_call_in_full() {
    let mut app = called(&[
        ("files__read_file", r#"{"path":"a.md"}"#, "first result"),
        ("files__read_file", r#"{"path":"b.md"}"#, "second result"),
    ]);
    let rows = screen(&app, 40, 14);
    let first = row_of(&rows, "a.md");
    mouse(&mut app, MouseEventKind::Down(MouseButton::Left), 4, first);
    mouse(&mut app, MouseEventKind::Up(MouseButton::Left), 4, first);
    assert!(app.is_detail_open());
    let text = screen(&app, 40, 14).join("\n");
    assert!(text.contains("← → 1 of 2"), "{text}");
    app.on_key(key(KeyCode::Esc));
    // A click on the Imp's own words opens nothing.
    let rows = screen(&app, 40, 14);
    let words = row_of(&rows, "go");
    mouse(&mut app, MouseEventKind::Down(MouseButton::Left), 2, words);
    mouse(&mut app, MouseEventKind::Up(MouseButton::Left), 2, words);
    assert!(!app.is_detail_open());
}

fn reason(app: &mut App, text: &str) {
    app.on_agent(&AgentEvent::Stream(StreamEvent::Reasoning(text.into())));
}

fn asked(question: &str) -> App {
    let mut app = app("pip", "m");
    type_text(&mut app, question);
    app.on_key(key(KeyCode::Enter));
    app.on_agent(&AgentEvent::StepStart);
    app
}

#[test]
fn thinking_streams_live_in_a_few_rows_and_collapses_when_the_answer_starts() {
    let mut app = asked("17*23?");
    reason(&mut app, "First I multiply seventeen by twenty. ");
    reason(&mut app, "Then by three.");
    let text = screen(&app, 40, 16).join("\n");
    assert!(text.contains("Thinking…"), "{text}");
    assert!(text.contains("First I multiply seventeen"), "{text}");
    assert!(text.contains("Then by three."), "{text}");
    assert!(!text.contains("Thought for"), "{text}");

    // Long reasoning shows its latest rows only, so the screen does not fill up.
    let long: String = (1..=30).map(|i| format!("step{i} ")).collect();
    reason(&mut app, &long);
    let rows = screen(&app, 30, 24);
    let text = rows.join("\n");
    assert!(text.contains("step30"), "{text}");
    assert!(!text.contains("step1 "), "{text}");
    let shown = rows.iter().filter(|r| r.contains("step")).count();
    assert!(shown <= 4, "{shown} rows of reasoning\n{text}");

    app.on_agent(&AgentEvent::Stream(StreamEvent::Text("391".into())));
    let text = screen(&app, 40, 16).join("\n");
    assert!(text.contains("✻ Thought for "), "{text}");
    assert!(
        !text.contains("step30") && !text.contains("Thinking…"),
        "{text}"
    );
    assert!(text.contains("● 391"), "{text}");
}

#[test]
fn a_thought_opens_in_full_like_a_tool_call_and_stays_when_scrolling_back() {
    let mut app = asked("hi");
    reason(
        &mut app,
        "Line one of the thought.\nLine two of the thought.",
    );
    app.on_agent(&AgentEvent::Stream(StreamEvent::Text("Hello".into())));
    app.on_agent(&AgentEvent::StepEnd);
    app.on_done(Ok(()));
    let text = screen(&app, 50, 12).join("\n");
    assert!(!text.contains("Line one"), "{text}");
    // Ctrl+O opens it, and Esc closes it.
    app.on_key(ctrl_o());
    assert!(app.is_detail_open());
    let text = screen(&app, 50, 12).join("\n");
    assert!(text.contains("Thought for "), "{text}");
    assert!(
        text.contains("Line one of the thought.") && text.contains("Line two of the thought."),
        "{text}"
    );
    assert!(text.contains("← → 1 of 1"), "{text}");
    app.on_key(key(KeyCode::Esc));
    assert!(!app.is_detail_open());

    // A click on its row opens it too.
    let rows = screen(&app, 50, 12);
    let y = rows
        .iter()
        .position(|r| r.contains("✻ Thought for"))
        .unwrap() as u16;
    let click = |kind| MouseEvent {
        kind,
        column: 4,
        row: y,
        modifiers: KeyModifiers::NONE,
    };
    app.on_mouse(click(MouseEventKind::Down(MouseButton::Left)));
    app.on_mouse(click(MouseEventKind::Up(MouseButton::Left)));
    assert!(app.is_detail_open());
    app.on_key(ctrl_o());
    assert!(!app.is_detail_open());

    // The transcript keeps it, collapsed, in the chat's order.
    let all = app
        .transcript(50)
        .iter()
        .map(|l| l.to_string())
        .collect::<Vec<_>>();
    let thought = all
        .iter()
        .position(|l| l.contains("✻ Thought for"))
        .unwrap();
    let said = all.iter().position(|l| l.contains("● Hello")).unwrap();
    assert!(thought < said, "{all:?}");
    assert!(!all.iter().any(|l| l.contains("Line one")), "{all:?}");
}

#[test]
fn each_phase_of_thinking_in_a_turn_gets_its_own_line_between_the_tool_calls() {
    let mut app = asked("look");
    reason(&mut app, "I should read the file.");
    let call = ToolCall {
        id: "c1".into(),
        name: "files__read_file".into(),
        arguments: r#"{"path":"a.txt"}"#.into(),
    };
    app.on_agent(&AgentEvent::Stream(StreamEvent::ToolCallDelta {
        index: 0,
        id: Some(call.id.clone()),
        name: Some(call.name.clone()),
        arguments: call.arguments.clone(),
    }));
    app.on_agent(&AgentEvent::StepEnd);
    app.on_agent(&AgentEvent::ToolStart(call.clone()));
    app.on_agent(&AgentEvent::ToolResult {
        call_id: call.id,
        name: call.name,
        content: "contents".into(),
    });
    app.on_agent(&AgentEvent::StepStart);
    reason(&mut app, "Now I can answer.");
    app.on_agent(&AgentEvent::Stream(StreamEvent::Text("Done".into())));
    app.on_agent(&AgentEvent::StepEnd);
    app.on_done(Ok(()));
    let all = app
        .transcript(50)
        .iter()
        .map(|l| l.to_string())
        .collect::<Vec<_>>();
    let at = |what: &str| all.iter().position(|l| l.contains(what));
    let thoughts: Vec<usize> = all
        .iter()
        .enumerate()
        .filter(|(_, l)| l.contains("✻ Thought for"))
        .map(|(i, _)| i)
        .collect();
    assert_eq!(thoughts.len(), 2, "{all:?}");
    let (call, done) = (at("⏺ read_file").unwrap(), at("● Done").unwrap());
    assert!(
        thoughts[0] < call && call < thoughts[1] && thoughts[1] < done,
        "{all:?}"
    );
    // Ctrl+O opens the latest item, and the arrows walk back through all three in order.
    app.on_key(ctrl_o());
    assert!(
        screen(&app, 50, 10)
            .join("\n")
            .contains("Now I can answer.")
    );
    assert!(screen(&app, 50, 10).join("\n").contains("← → 3 of 3"));
    app.on_key(key(KeyCode::Left));
    assert!(screen(&app, 50, 10).join("\n").contains("a.txt"));
    app.on_key(key(KeyCode::Left));
    assert!(
        screen(&app, 50, 10)
            .join("\n")
            .contains("I should read the file.")
    );
}

#[test]
fn a_stopped_turn_keeps_what_it_thought_and_a_cleared_chat_forgets_it() {
    let mut app = asked("hmm");
    reason(&mut app, "Pondering deeply.");
    app.on_stopped();
    let text = screen(&app, 40, 10).join("\n");
    assert!(
        text.contains("✻ Thought for ") && !text.contains("Pondering"),
        "{text}"
    );
    app.clear();
    let text = screen(&app, 40, 10).join("\n");
    assert!(!text.contains("Thought for"), "{text}");
}

#[test]
fn reasoning_never_goes_into_what_the_model_is_sent() {
    let mut app = asked("q");
    reason(&mut app, "SECRET-THOUGHT");
    app.on_agent(&AgentEvent::Stream(StreamEvent::Text("a".into())));
    app.on_agent(&AgentEvent::StepEnd);
    app.on_done(Ok(()));
    let sent = format!("{:?}", app.chat.request_messages());
    assert!(!sent.contains("SECRET-THOUGHT"), "{sent}");
}
