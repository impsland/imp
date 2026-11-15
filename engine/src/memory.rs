//! What an Imp remembers of one chat and what it sends the model: whole exchanges, clipped tool
//! results, a recap in place of what came before, and the long-chat notice. The apps only keep the
//! files.

/// Exchanges sent by default (an exchange: a user turn with every tool call and reply it led to).
pub const DEFAULT_EXCHANGES: usize = 20;
/// Exchanges kept at most. As many as the longest "Remembers" choice.
pub const STORED_EXCHANGES: usize = 1_000;
/// The "Remembers" choices (exchanges sent with each message), besides no limit.
pub const CHOICES: [usize; 8] = [5, 10, 20, 50, 100, 200, 500, 1_000];
/// A tool result longer than this (in characters) is clipped when it is remembered.
pub const TOOL_RESULT_LIMIT: usize = 8_000;
/// The most transcript (in characters) sent to be recapped.
pub const TRANSCRIPT_LIMIT: usize = 240_000;
/// A tool call or result longer than this is clipped in the transcript.
pub const TRANSCRIPT_TOOL_LIMIT: usize = 1_500;
/// Turns a chat keeps: older ones are dropped.
pub const TURN_LIMIT: usize = 2_000;
/// Introduces the recap in the opening message.
pub const RECAP_PREFACE: &str =
    "Recap of our chat so far (it replaces the earlier messages, which aren't included):\n\n";
/// The model's side of the opening exchange.
pub const RECAP_ACKNOWLEDGEMENT: &str = "Understood. I'll carry on from this recap.";

const TITLE_LIMIT: usize = 48;

/// A call the model made.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct MemoryCall {
    pub id: String,
    pub name: String,
    pub arguments: String,
}

/// One remembered message. `role` is `system`, `user`, `assistant` or `tool`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct MemoryMessage {
    pub role: String,
    pub content: Option<String>,
    pub tool_calls: Vec<MemoryCall>,
    pub tool_call_id: Option<String>,
    /// A user-role message that is not a turn of the user's (pictures a tool returned).
    pub attachment: bool,
}

impl MemoryMessage {
    pub fn new(role: &str, content: &str) -> Self {
        Self {
            role: role.to_string(),
            content: Some(content.to_string()),
            tool_calls: Vec::new(),
            tool_call_id: None,
            attachment: false,
        }
    }

    fn opens_exchange(&self) -> bool {
        self.role == "user" && !self.attachment
    }
}

/// The remembered messages after the system prompt, and the recap of what came before them.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct ChatMemory {
    pub messages: Vec<MemoryMessage>,
    pub recap: Option<String>,
}

/// Splits messages into exchanges, each starting with a user message (anything before the first
/// one rides with it), so tool calls never lose their results.
pub fn exchanges(messages: &[MemoryMessage]) -> Vec<Vec<MemoryMessage>> {
    let mut out: Vec<Vec<MemoryMessage>> = Vec::new();
    let mut saw_user = false;
    for m in messages {
        let opens = m.opens_exchange();
        match out.last_mut() {
            Some(last) if !(opens && saw_user) => last.push(m.clone()),
            _ => out.push(vec![m.clone()]),
        }
        saw_user = saw_user || opens;
    }
    out
}

/// Only what was said: user turns and replies, no tool calls or results.
fn without_tools(messages: Vec<MemoryMessage>) -> Vec<MemoryMessage> {
    messages
        .into_iter()
        .filter(|m| {
            m.role != "tool"
                && !m.attachment
                && !(m.role == "assistant" && !m.tool_calls.is_empty())
        })
        .collect()
}

fn clip(s: &str, limit: usize) -> String {
    if s.chars().count() > limit {
        format!("{}…", s.chars().take(limit).collect::<String>())
    } else {
        s.to_string()
    }
}

/// The opening exchange that stands for everything before the recap.
pub fn recap_opening(recap: &str) -> Vec<MemoryMessage> {
    vec![
        MemoryMessage::new("user", &format!("{RECAP_PREFACE}{recap}")),
        MemoryMessage::new("assistant", RECAP_ACKNOWLEDGEMENT),
    ]
}

impl ChatMemory {
    pub fn is_empty(&self) -> bool {
        self.messages.is_empty() && self.recap.is_none()
    }

    pub fn exchange_count(&self) -> usize {
        exchanges(&self.messages).len()
    }

    /// What goes to the model between the system prompt and the new turn: the recap (if any) as
    /// the opening exchange, then the last `count` exchanges, without tool calls unless `tools`.
    pub fn context(&self, count: usize, tools: bool) -> Vec<MemoryMessage> {
        let all = exchanges(&self.messages);
        let recent: Vec<MemoryMessage> = all
            .into_iter()
            .rev()
            .take(count)
            .collect::<Vec<_>>()
            .into_iter()
            .rev()
            .flatten()
            .collect();
        let mut out = self.recap.as_deref().map(recap_opening).unwrap_or_default();
        out.extend(if tools { recent } else { without_tools(recent) });
        out
    }

    /// Remembers one finished exchange. Pictures' messages are dropped, long tool results clipped.
    pub fn remember(&mut self, exchange: &[MemoryMessage]) {
        for m in exchange.iter().filter(|m| !m.attachment) {
            let mut m = m.clone();
            if m.role == "tool"
                && let Some(c) = &m.content
            {
                let n = c.chars().count();
                if n > TOOL_RESULT_LIMIT {
                    m.content = Some(format!(
                        "{}\n…(clipped: {} more characters)",
                        c.chars().take(TOOL_RESULT_LIMIT).collect::<String>(),
                        n - TOOL_RESULT_LIMIT
                    ));
                }
            }
            self.messages.push(m);
        }
        let all = exchanges(&self.messages);
        if all.len() > STORED_EXCHANGES {
            self.messages = all[all.len() - STORED_EXCHANGES..]
                .iter()
                .flatten()
                .cloned()
                .collect();
        }
    }

    /// The chat recapped: `summary` was written from the first `covered` exchanges (all, by
    /// default) and stands for them but the last. That last one stays, and so does anything said
    /// while the recap was written. A blank summary changes nothing. True when it took.
    pub fn recapped(&mut self, summary: &str, covered: Option<usize>) -> bool {
        let text = summary.trim();
        if text.is_empty() {
            return false;
        }
        self.recap = Some(text.to_string());
        let all = exchanges(&self.messages);
        let skip = covered
            .unwrap_or(all.len())
            .min(all.len())
            .saturating_sub(1);
        self.messages = all.into_iter().skip(skip).flatten().collect();
        true
    }

    /// A rough size of what is sent, in tokens (about four characters each).
    pub fn estimated_tokens(&self, count: usize, tools: bool) -> usize {
        let chars: usize = self
            .context(count, tools)
            .iter()
            .map(|m| {
                m.content.as_deref().map_or(0, |c| c.chars().count())
                    + m.tool_calls
                        .iter()
                        .map(|c| c.name.chars().count() + c.arguments.chars().count())
                        .sum::<usize>()
            })
            .sum();
        chars / 4
    }

    /// The remembered chat as plain text, at most `limit` characters: the earlier recap always,
    /// then as many of the newest messages as fit.
    pub fn transcript(&self, tool_limit: usize, limit: usize) -> String {
        let mut lines: Vec<String> = Vec::new();
        for m in self.messages.iter().filter(|m| !m.attachment) {
            let text = m.content.as_deref().unwrap_or("").trim();
            match m.role.as_str() {
                "user" => lines.push(format!("User: {text}")),
                "assistant" => {
                    if !text.is_empty() {
                        lines.push(format!("Assistant: {text}"));
                    }
                    for c in &m.tool_calls {
                        lines.push(format!(
                            "Assistant called {}({})",
                            c.name,
                            clip(&c.arguments, tool_limit)
                        ));
                    }
                }
                "tool" => lines.push(format!("Tool result: {}", clip(text, tool_limit))),
                _ => {}
            }
        }
        let head = self.recap.as_ref().map(|r| format!("[Earlier recap]\n{r}"));
        // Room for the earlier recap and the "left out" note, each with its separator.
        let mut budget =
            limit as i64 - head.as_ref().map_or(0, |h| h.chars().count() as i64 + 2) - 64;
        let mut kept: Vec<&String> = Vec::new();
        for line in lines.iter().rev() {
            budget -= line.chars().count() as i64 + 2;
            if budget < 0 {
                break;
            }
            kept.push(line);
        }
        let left = lines.len() - kept.len();
        let mut parts: Vec<String> = Vec::new();
        parts.extend(head);
        if left > 0 {
            parts.push(format!("[{left} earlier messages left out to fit]"));
        }
        parts.extend(kept.into_iter().rev().cloned());
        parts.join("\n\n")
    }

    /// The request that asks for a recap: the whole remembered chat as a transcript, so it works
    /// with any model, tools or not.
    pub fn recap_request(&self, name: &str) -> Vec<MemoryMessage> {
        let system = format!(
            "You write the recap of a chat between a user and {name}, an AI assistant, so the chat can \
             carry on without its full history. Keep what matters for continuing: the user's goals, \
             requests and preferences; decisions and facts established; files, paths, URLs and names of \
             anything made or used (exactly as written); what is still open; and what happened last. \
             If the chat starts with an earlier recap, fold everything in it that still matters into \
             yours: yours replaces it. Leave out small talk. Write in the language the user writes in, \
             as short bullet points, under 300 words. Reply with the recap only."
        );
        vec![
            MemoryMessage::new("system", &system),
            MemoryMessage::new(
                "user",
                &format!(
                    "The chat to recap:\n\n{}",
                    self.transcript(TRANSCRIPT_TOOL_LIMIT, TRANSCRIPT_LIMIT)
                ),
            ),
        ]
    }
}

/// The long-chat notice is due: the threshold is on (above 0), it was not raised for this chat
/// before, the chat remembers something, and what would be sent reaches the threshold.
pub fn notice_due(
    threshold: usize,
    already: bool,
    memory: &ChatMemory,
    count: usize,
    tools: bool,
) -> bool {
    threshold > 0
        && !already
        && !memory.is_empty()
        && memory.estimated_tokens(count, tools) >= threshold
}

/// A name for a chat from the first thing asked: its first line, cut short. `sender` is the Imp
/// that asked, when another Imp did.
pub fn chat_title(request: &str, has_picture: bool, sender: Option<&str>) -> String {
    let mut words = if request.is_empty() {
        if has_picture { "A picture" } else { "Chat" }.to_string()
    } else {
        request.to_string()
    };
    if let Some(sender) = sender {
        words = format!("{sender}: {words}");
    }
    let line = words
        .split(['\n', '\r'])
        .find(|l| !l.is_empty())
        .unwrap_or(&words);
    let trimmed = line.trim_matches(|c| c == ' ' || c == '\t');
    if trimmed.chars().count() > TITLE_LIMIT {
        format!(
            "{}…",
            trimmed.chars().take(TITLE_LIMIT - 1).collect::<String>()
        )
    } else {
        trimmed.to_string()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn u(s: &str) -> MemoryMessage {
        MemoryMessage::new("user", s)
    }
    fn a(s: &str) -> MemoryMessage {
        MemoryMessage::new("assistant", s)
    }
    fn tool_exchange(ask: &str) -> Vec<MemoryMessage> {
        let call = MemoryCall {
            id: "call_1".into(),
            name: "Speech__generate_speech".into(),
            arguments: r#"{"output":"affirmation.mp3"}"#.into(),
        };
        let mut calling = MemoryMessage::new("assistant", "");
        calling.content = None;
        calling.tool_calls = vec![call];
        let mut result = MemoryMessage::new("tool", "Saved speech: /tmp/affirmation.mp3");
        result.tool_call_id = Some("call_1".into());
        vec![
            u(ask),
            calling,
            result,
            a("Done: ![voice](affirmation.mp3)"),
        ]
    }
    fn roles(ms: &[MemoryMessage]) -> Vec<&str> {
        ms.iter().map(|m| m.role.as_str()).collect()
    }
    fn texts(ms: &[MemoryMessage]) -> Vec<&str> {
        ms.iter()
            .map(|m| m.content.as_deref().unwrap_or(""))
            .collect()
    }

    #[test]
    fn tool_calls_stay_unless_left_out() {
        let mut m = ChatMemory::default();
        m.remember(&tool_exchange("Make it nicer"));
        assert_eq!(
            roles(&m.context(20, true)),
            ["user", "assistant", "tool", "assistant"]
        );
        let said = m.context(20, false);
        assert_eq!(roles(&said), ["user", "assistant"]);
        assert_eq!(
            said[1].content.as_deref(),
            Some("Done: ![voice](affirmation.mp3)")
        );
    }

    #[test]
    fn whole_exchanges_are_sent() {
        let mut m = ChatMemory::default();
        for i in 0..5 {
            m.remember(&tool_exchange(&format!("q{i}")));
        }
        assert_eq!(m.exchange_count(), 5);
        let sent = m.context(2, true);
        assert_eq!(sent.len(), 8);
        assert_eq!(sent[0].content.as_deref(), Some("q3"));
        assert!(!sent[1].tool_calls.is_empty());
        assert!(m.context(0, true).is_empty());
    }

    #[test]
    fn attachments_are_not_remembered_and_never_open_an_exchange() {
        let mut pictures = u("Screenshot from x.");
        pictures.attachment = true;
        let mut m = ChatMemory::default();
        m.remember(&[u("look"), pictures.clone(), a("nice")]);
        assert_eq!(texts(&m.messages), ["look", "nice"]);
        assert_eq!(exchanges(&[u("a"), pictures, a("1")]).len(), 1);
    }

    #[test]
    fn long_tool_results_are_clipped_and_old_exchanges_go() {
        let mut m = ChatMemory::default();
        let long = "x".repeat(TOOL_RESULT_LIMIT + 500);
        let mut result = MemoryMessage::new("tool", &long);
        result.tool_call_id = Some("c".into());
        m.remember(&[u("read"), result, a("ok")]);
        let kept = m.messages[1].content.clone().unwrap();
        assert!(kept.chars().count() < long.chars().count());
        assert!(kept.ends_with("(clipped: 500 more characters)"));
        for i in 0..STORED_EXCHANGES + 3 {
            m.remember(&[u(&format!("q{i}")), a("a")]);
        }
        assert_eq!(m.exchange_count(), STORED_EXCHANGES);
        assert_eq!(m.messages[0].content.as_deref(), Some("q3"));
    }

    #[test]
    fn a_recap_stands_for_all_but_the_last_exchange() {
        let mut m = ChatMemory::default();
        m.remember(&[u("My name is Ann"), a("Hi Ann")]);
        m.remember(&tool_exchange("Make it sound nicer"));
        assert!(m.recapped("  - The user is Ann.  ", None));
        assert_eq!(m.recap.as_deref(), Some("- The user is Ann."));
        assert_eq!(m.exchange_count(), 1);
        let sent = m.context(20, true);
        assert_eq!(sent[0], u(&format!("{RECAP_PREFACE}- The user is Ann.")));
        assert_eq!(sent[1], a(RECAP_ACKNOWLEDGEMENT));
        assert_eq!(sent[2].content.as_deref(), Some("Make it sound nicer"));
        assert!(m.estimated_tokens(20, true) > 0);
    }

    #[test]
    fn recapping_again_keeps_roles_alternating_with_one_recap() {
        let mut m = ChatMemory::default();
        m.remember(&[u("I'm Ann"), a("Hi Ann")]);
        m.remember(&[u("I like jazz"), a("Noted")]);
        m.recapped("- Ann", None);
        m.remember(&[u("Play something"), a("Playing Miles")]);
        assert!(
            m.recap_request("Fizz")[1]
                .content
                .as_deref()
                .unwrap()
                .starts_with("The chat to recap:\n\n[Earlier recap]\n- Ann")
        );
        m.recapped("- Ann, likes jazz", None);
        assert_eq!(texts(&m.messages), ["Play something", "Playing Miles"]);
        let sent = m.context(20, false);
        assert_eq!(roles(&sent), ["user", "assistant", "user", "assistant"]);
        assert_eq!(
            sent.iter()
                .filter(|s| s.content.as_deref().unwrap().contains(RECAP_PREFACE))
                .count(),
            1
        );
    }

    #[test]
    fn messages_before_the_first_user_message_ride_with_it() {
        let mut orphan = MemoryMessage::new("tool", "ok");
        orphan.tool_call_id = Some("c".into());
        let ex = exchanges(&[orphan, a("done"), u("a"), a("1"), u("b"), a("2")]);
        let seen: Vec<Vec<&str>> = ex.iter().map(|e| texts(e)).collect();
        assert_eq!(seen, [vec!["ok", "done", "a", "1"], vec!["b", "2"]]);
        assert_eq!(exchanges(&[a("hi")]).len(), 1);
    }

    #[test]
    fn what_is_said_during_a_recap_is_kept() {
        let mut m = ChatMemory::default();
        m.remember(&[u("a"), a("1")]);
        m.remember(&[u("b"), a("2")]);
        let covered = m.exchange_count();
        m.remember(&[u("c"), a("3")]);
        m.recapped("- a and b", Some(covered));
        assert_eq!(texts(&m.messages), ["b", "2", "c", "3"]);
    }

    #[test]
    fn a_blank_recap_forgets_nothing() {
        let mut m = ChatMemory::default();
        m.remember(&[u("a"), a("1")]);
        m.remember(&[u("b"), a("2")]);
        assert!(!m.recapped("  \n ", None));
        assert!(m.recap.is_none());
        assert_eq!(m.exchange_count(), 2);
    }

    #[test]
    fn a_huge_chat_is_cut_to_fit_the_recap_request() {
        let mut m = ChatMemory {
            recap: Some("- old".into()),
            ..Default::default()
        };
        for i in 0..300 {
            m.remember(&[u(&format!("q{i} {}", "x".repeat(100))), a(&format!("a{i}"))]);
        }
        let text = m.transcript(TRANSCRIPT_TOOL_LIMIT, 5_000);
        assert!(text.chars().count() <= 5_000);
        assert!(text.starts_with("[Earlier recap]\n- old"));
        assert!(text.contains("earlier messages left out to fit"));
        assert!(text.ends_with("Assistant: a299"));
        assert!(
            !m.transcript(TRANSCRIPT_TOOL_LIMIT, TRANSCRIPT_LIMIT)
                .contains("left out")
        );
    }

    #[test]
    fn the_recap_request_carries_the_whole_chat() {
        let mut m = ChatMemory {
            recap: Some("- Earlier: picked a voice".into()),
            ..Default::default()
        };
        m.remember(&tool_exchange("Make it sound nicer"));
        let request = m.recap_request("Fizz");
        assert_eq!(roles(&request), ["system", "user"]);
        assert!(request[0].content.as_deref().unwrap().contains("Fizz"));
        let text = request[1].content.clone().unwrap();
        assert!(text.contains("[Earlier recap]\n- Earlier: picked a voice"));
        assert!(text.contains("User: Make it sound nicer"));
        assert!(
            text.contains(
                r#"Assistant called Speech__generate_speech({"output":"affirmation.mp3"})"#
            )
        );
        assert!(text.contains("Tool result: Saved speech: /tmp/affirmation.mp3"));
        assert!(text.contains("Assistant: Done: ![voice](affirmation.mp3)"));
    }

    #[test]
    fn every_choice_is_sent_and_the_longest_is_stored() {
        assert!(
            CHOICES.contains(&STORED_EXCHANGES) && CHOICES.iter().max() == Some(&STORED_EXCHANGES)
        );
        assert!(CHOICES.contains(&DEFAULT_EXCHANGES));
    }

    #[test]
    fn the_notice_is_due_once_the_chat_is_long_enough() {
        let mut m = ChatMemory::default();
        assert!(!notice_due(10, false, &m, 20, true));
        m.remember(&[u(&"x".repeat(400)), a("ok")]);
        assert!(notice_due(10, false, &m, 20, true));
        assert!(!notice_due(0, false, &m, 20, true));
        assert!(!notice_due(10, true, &m, 20, true));
        assert!(!notice_due(10_000, false, &m, 20, true));
    }

    #[test]
    fn titles_are_the_first_line_cut_short() {
        assert_eq!(chat_title("", false, None), "Chat");
        assert_eq!(chat_title("", true, None), "A picture");
        assert_eq!(chat_title("  Hello\nworld ", false, None), "Hello");
        assert_eq!(chat_title("Hi", false, Some("Pip")), "Pip: Hi");
        let long = chat_title(&"y".repeat(60), false, None);
        assert_eq!(long.chars().count(), 48);
        assert!(long.ends_with('…'));
    }
}
